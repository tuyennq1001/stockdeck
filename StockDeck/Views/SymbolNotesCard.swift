import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Image store

enum NoteImageStore {
    private static let directoryName = "note-images"

    static func directory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("StockDeck").appendingPathComponent(directoryName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func saveImage(_ data: Data, ext: String) -> String {
        let filename = "\(UUID().uuidString).\(ext)"
        let url = directory().appendingPathComponent(filename)
        try? data.write(to: url)
        return filename
    }

    static func imageURL(for filename: String) -> URL {
        directory().appendingPathComponent(filename)
    }
}

#if os(macOS)
// MARK: - Editor Model (holds NSTextView reference for toolbar)

final class EditorModel: ObservableObject {
    weak var textView: NSTextView?

    func insertFormatting(prefix: String, suffix: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length > 0 {
            guard let textRange = Range(range, in: tv.string) else { return }
            let selected = String(tv.string[textRange])
            let replacement = prefix + selected + suffix
            if tv.shouldChangeText(in: range, replacementString: replacement) {
                tv.textStorage?.replaceCharacters(in: range, with: replacement)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location + prefix.count, length: range.length))
            }
        } else {
            let insertion = prefix + "text" + suffix
            if tv.shouldChangeText(in: range, replacementString: insertion) {
                tv.textStorage?.replaceCharacters(in: range, with: insertion)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location + prefix.count, length: 4))
            }
        }
    }

    func insertImageMarkdown(filename: String) {
        guard let tv = textView else { return }
        let md = "\n![image](note-image://\(filename))\n"
        let r = tv.selectedRange()
        if tv.shouldChangeText(in: r, replacementString: md) {
            tv.textStorage?.replaceCharacters(in: r, with: md)
            tv.didChangeText()
        }
    }

    func handleImageDrop(_ data: Data) {
        let filename = NoteImageStore.saveImage(data, ext: "png")
        DispatchQueue.main.async { [weak self] in
            self?.insertImageMarkdown(filename: filename)
        }
    }
}

// MARK: - WYSIWYG Markdown Editor

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var model: EditorModel

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        context.coordinator.textView = textView
        model.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        if textView.string != text && !context.coordinator.isInternalChange {
            textView.string = text
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var model: EditorModel
        weak var textView: NSTextView?
        var isInternalChange = false

        init(text: Binding<String>, model: EditorModel) {
            _text = text; self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            isInternalChange = true
            text = tv.string
            isInternalChange = false
        }
    }
}
#else
final class EditorModel: ObservableObject {
    func insertFormatting(prefix: String, suffix: String) {}
    func insertImageMarkdown(filename: String) {}
    func handleImageDrop(_ data: Data) {}
}

struct MarkdownEditor: View {
    @Binding var text: String
    var model: EditorModel
    var body: some View {
        TextEditor(text: $text)
    }
}
#endif

// MARK: - Markdown Toolbar

struct MarkdownToolbar: View {
    @ObservedObject var model: EditorModel
    var onImage: () -> Void

    private let formats: [(icon: String, label: String, prefix: String, suffix: String)] = [
        ("bold", "Bold", "**", "**"),
        ("italic", "Italic", "*", "*"),
        ("strikethrough", "Strikethrough", "~~", "~~"),
        ("text.alignleft", "Heading", "\n# ", ""),
        ("list.bullet", "Bullet list", "\n- ", ""),
        ("list.number", "Numbered list", "\n1. ", ""),
        ("chevron.left.forwardslash.chevron.right", "Code", "`", "`"),
        ("link", "Link", "[", "](url)"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(formats, id: \.label) { fmt in
                    Button {
                        model.insertFormatting(prefix: fmt.prefix, suffix: fmt.suffix)
                    } label: {
                        Image(systemName: fmt.icon)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.inkSecondary)
                    .help(fmt.label).pointingHandCursor()
                }
                Divider().frame(height: 16).overlay(DS.hairline).padding(.horizontal, 2)
                Button(action: onImage) {
                    Image(systemName: "photo").font(.system(size: 11, weight: .medium)).frame(width: 28, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(DS.inkSecondary)
                .help("Insert image").pointingHandCursor()
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 28)
    }
}

// MARK: - Custom Markdown Renderer

struct MarkdownRenderer: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parsedNodes.enumerated()), id: \.offset) { _, node in renderNode(node) }
        }
    }

    private indirect enum Node {
        case heading(level: Int, content: [Inline]), paragraph([Inline]), bulletList([[Inline]]), numberedList([[Inline]]), blank
    }
    private enum Inline {
        case text(String), bold(String), italic(String), strikethrough(String), code(String), link(text: String, url: String)
    }

    private var parsedNodes: [Node] {
        let lines = text.components(separatedBy: "\n")
        var nodes: [Node] = []; var i = 0
        let h = try! NSRegularExpression(pattern: #"^(#{1,3})\s+(.*)"#, options: [])
        let b = try! NSRegularExpression(pattern: #"^[\-\*]\s+(.*)"#, options: [])
        let n = try! NSRegularExpression(pattern: #"^\d+\.\s+(.*)"#, options: [])
        while i < lines.count {
            let line = lines[i]; let lr = NSRange(line.startIndex..., in: line)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { nodes.append(.blank); i += 1; continue }
            if let m = h.firstMatch(in: line, options: [], range: lr) {
                let lv = Range(m.range(at: 1), in: line).map { String(line[$0]).count } ?? 1
                let ct = Range(m.range(at: 2), in: line).map { String(line[$0]) } ?? ""
                nodes.append(.heading(level: lv, content: parseInlines(ct))); i += 1; continue
            }
            if let m = b.firstMatch(in: line, options: [], range: lr) {
                var items: [[Inline]] = []
                while i < lines.count { let l = lines[i]; let r = NSRange(l.startIndex..., in: l)
                    if let bm = b.firstMatch(in: l, options: [], range: r), let c = Range(bm.range(at: 1), in: l) { items.append(parseInlines(String(l[c]))); i += 1 } else { break }
                }; nodes.append(.bulletList(items)); continue
            }
            if let m = n.firstMatch(in: line, options: [], range: lr) {
                var items: [[Inline]] = []
                while i < lines.count { let l = lines[i]; let r = NSRange(l.startIndex..., in: l)
                    if let nm = n.firstMatch(in: l, options: [], range: r), let c = Range(nm.range(at: 1), in: l) { items.append(parseInlines(String(l[c]))); i += 1 } else { break }
                }; nodes.append(.numberedList(items)); continue
            }
            nodes.append(.paragraph(parseInlines(line))); i += 1
        }
        return nodes
    }

    private func parseInlines(_ text: String) -> [Inline] {
        var result: [Inline] = []; var remaining = text
        let p = try! NSRegularExpression(pattern: #"(\*\*(.+?)\*\*|\*(.+?)\*|~~(.+?)~~|`(.+?)`|\[([^\]]+)\]\(([^\)]+)\))"#, options: [])
        while !remaining.isEmpty {
            let range = NSRange(remaining.startIndex..., in: remaining)
            if let m = p.firstMatch(in: remaining, options: [], range: range) {
                if let br = Range(NSRange(location: 0, length: m.range.location), in: remaining), !br.isEmpty { let bf = String(remaining[br]); if !bf.isEmpty { result.append(.text(bf)) } }
                if let r = Range(m.range(at: 2), in: remaining), m.range(at: 2).location != NSNotFound { result.append(.bold(String(remaining[r]))) }
                else if let r = Range(m.range(at: 3), in: remaining), m.range(at: 3).location != NSNotFound { result.append(.italic(String(remaining[r]))) }
                else if let r = Range(m.range(at: 4), in: remaining), m.range(at: 4).location != NSNotFound { result.append(.strikethrough(String(remaining[r]))) }
                else if let r = Range(m.range(at: 5), in: remaining), m.range(at: 5).location != NSNotFound { result.append(.code(String(remaining[r]))) }
                else if let tr = Range(m.range(at: 6), in: remaining), let ur = Range(m.range(at: 7), in: remaining), m.range(at: 6).location != NSNotFound { result.append(.link(text: String(remaining[tr]), url: String(remaining[ur]))) }
                remaining = String(remaining[remaining.index(remaining.startIndex, offsetBy: m.range.location + m.range.length)...])
            } else { if !remaining.isEmpty { result.append(.text(remaining)) }; remaining = "" }
        }
        return result.isEmpty ? [.text(text)] : result
    }

    @ViewBuilder
    private func renderNode(_ node: Node) -> some View {
        switch node {
        case .heading(let lv, let ct):
            let f: Font = lv == 1 ? DS.title : (lv == 2 ? .inter(15, weight: .bold, relativeTo: .title3) : .inter(13, weight: .bold, relativeTo: .body))
            renderInlines(ct, baseFont: f, baseColor: DS.ink).padding(.top, lv == 1 ? 8 : 4).padding(.bottom, 2)
        case .paragraph(let il): renderInlines(il, baseFont: DS.body, baseColor: DS.ink).padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
        case .bulletList(let items): VStack(alignment: .leading, spacing: 2) { ForEach(Array(items.enumerated()), id: \.offset) { _, item in HStack(alignment: .top, spacing: 6) { Text("•").font(DS.body).foregroundStyle(DS.inkSecondary).frame(width: 10, alignment: .leading); renderInlines(item, baseFont: DS.body, baseColor: DS.ink).frame(maxWidth: .infinity, alignment: .leading) } } }.padding(.vertical, 2)
        case .numberedList(let items): VStack(alignment: .leading, spacing: 2) { ForEach(Array(items.enumerated()), id: \.offset) { idx, item in HStack(alignment: .top, spacing: 6) { Text("\(idx + 1).").font(DS.body.monospacedDigit()).foregroundStyle(DS.inkSecondary).frame(width: 20, alignment: .leading); renderInlines(item, baseFont: DS.body, baseColor: DS.ink).frame(maxWidth: .infinity, alignment: .leading) } } }.padding(.vertical, 2)
        case .blank: Color.clear.frame(height: 6)
        }
    }

    @ViewBuilder
    private func renderInlines(_ inlines: [Inline], baseFont: Font, baseColor: Color) -> some View {
        Text(inlines.reduce(AttributedString()) { p, il in var r = p
            switch il {
            case .text(let s): r.append(attr(s, font: baseFont, color: baseColor))
            case .bold(let s): var a = attr(s, font: baseFont, color: baseColor); a.font = .system(size: fs(baseFont), weight: .bold); r.append(a)
            case .italic(let s): var a = attr(s, font: baseFont, color: baseColor); a.font = .system(size: fs(baseFont)).italic(); r.append(a)
            case .strikethrough(let s): var a = attr(s, font: baseFont, color: DS.inkTertiary); a.strikethroughStyle = .single; r.append(a)
            case .code(let s): var a = attr(s, font: .system(.caption, design: .monospaced), color: DS.brand); a.backgroundColor = DS.brand.opacity(0.10); r.append(a)
            case .link(let t, let u): var a = attr(t, font: baseFont, color: DS.brand); a.underlineStyle = .single; a.link = URL(string: u); r.append(a)
            }; return r
        })
    }
    private func attr(_ s: String, font: Font, color: Color) -> AttributedString { var a = AttributedString(s); a.font = font; a.foregroundColor = color; return a }
    private func fs(_ f: Font) -> CGFloat { switch f { case DS.title: return 17; default: return 13 } }
}

// MARK: - Expandable note display

struct MarkdownNoteView: View {
    let markdown: String
    @State private var expanded = false
    private let threshold = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(parsedBlocks(), id: \.id) { block in
                switch block {
                case .text(let md): MarkdownRenderer(text: expanded ? md : truncated(md)).frame(maxWidth: .infinity, alignment: .leading)
                case .image(let f, let alt):
                    #if os(macOS)
                    let img = NSImage(contentsOf: NoteImageStore.imageURL(for: f))
                    #else
                    let img = UIImage(contentsOfFile: NoteImageStore.imageURL(for: f).path)
                    #endif
                    if let img {
                        #if os(macOS)
                        Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 340)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.hairline, lineWidth: 0.5))
                        #else
                        Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 340)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.hairline, lineWidth: 0.5))
                        #endif
                        if !alt.isEmpty { Text(alt).font(DS.micro).foregroundStyle(DS.inkTertiary) }
                    }
                }
            }
            if totalLines > threshold && !expanded {
                Button("Show more") { withAnimation { expanded = true } }
                    .buttonStyle(.plain).font(.inter(11, weight: .medium, relativeTo: .caption)).foregroundStyle(DS.brand).pointingHandCursor().padding(.top, 2)
            } else if expanded && totalLines > threshold {
                Button("Show less") { withAnimation { expanded = false } }
                    .buttonStyle(.plain).font(.inter(11, weight: .medium, relativeTo: .caption)).foregroundStyle(DS.brand).pointingHandCursor().padding(.top, 2)
            }
        }
    }
    private func truncated(_ t: String) -> String { let ls = t.components(separatedBy: "\n"); return ls.count > threshold ? ls.prefix(threshold).joined(separator: "\n") : t }
    private var totalLines: Int { markdown.components(separatedBy: "\n").count }

    private enum Block: Identifiable { case text(String), image(filename: String, alt: String); var id: String { switch self { case .text(let s): return "t:\(s.hashValue)"; case .image(let f, _): return "i:\(f)" } } }
    private func parsedBlocks() -> [Block] {
        var blocks: [Block] = []; var remaining = markdown
        let p = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(note-image://([^\)]+)\)"#, options: [])
        while !remaining.isEmpty { let r = NSRange(remaining.startIndex..., in: remaining)
            if let m = p.firstMatch(in: remaining, options: [], range: r) {
                if let br = Range(NSRange(location: 0, length: m.range.location), in: remaining), !br.isEmpty { let t = String(remaining[br]); if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.text(t)) } }
                if let ar = Range(m.range(at: 1), in: remaining), let fr = Range(m.range(at: 2), in: remaining) { blocks.append(.image(filename: String(remaining[fr]), alt: String(remaining[ar]))) }
                remaining = String(remaining[remaining.index(remaining.startIndex, offsetBy: m.range.location + m.range.length)...])
            } else { if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.text(remaining)) }; remaining = "" }
        }
        return blocks.isEmpty ? [.text(markdown)] : blocks
    }
}

// MARK: - Note card

struct SymbolNotesCard: View {
    @ObservedObject var storageService: StorageService
    let symbol: String

    // New note
    @State private var isEditingNew = false
    @State private var editorTitle = ""
    @State private var editorText = ""
    @State private var previewNew = false
    @StateObject private var newModel = EditorModel()

    // Edit existing note
    @State private var editingNoteId: UUID? = nil
    @State private var editTitle = ""
    @State private var editText = ""
    @State private var previewEdit = false
    @StateObject private var editModel = EditorModel()

    @State private var deleteTarget: SymbolNote? = nil
    @State private var showImagePicker = false

    private var notes: [SymbolNote] { storageService.notes(for: symbol) }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        Card(title: "Notes") {
            VStack(spacing: 10) {
                if isEditingNew {
                    VStack(spacing: 8) {
                        TextField("Title (optional)", text: $editorTitle)
                            .textFieldStyle(.plain).font(DS.titleXL).tracking(-0.3).foregroundStyle(DS.ink)
                            .disabled(previewNew)

                        if !previewNew {
                            MarkdownToolbar(model: newModel, onImage: { showImagePicker = true })
                        }

                        if previewNew {
                            MarkdownNoteView(markdown: editorText)
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.cardAlt))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.hairline, lineWidth: 1))
                        } else {
                            MarkdownEditor(text: $editorText, model: newModel)
                                .frame(minHeight: 80)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.cardAlt))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.hairline, lineWidth: 1))
                                .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                                    for p in providers { if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) { p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in if let d = d { newModel.handleImageDrop(d) } } } }
                                    return true
                                }
                        }

                        HStack(spacing: 6) {
                            Button("Save") { saveNewNote() }
                                .buttonStyle(.plain).font(.inter(12, weight: .semibold, relativeTo: .body))
                                .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule().fill(editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DS.inkTertiary.opacity(0.3) : DS.brand))
                                .disabled(editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .pointingHandCursor()

                            Button(previewNew ? "Edit" : "Preview") { previewNew.toggle() }
                                .buttonStyle(.plain).font(.inter(12, weight: .medium, relativeTo: .body))
                                .foregroundStyle(DS.brand).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(DS.brand.opacity(0.12)))
                                .pointingHandCursor()

                            Button("Cancel") { isEditingNew = false; editorTitle = ""; editorText = ""; previewNew = false }
                                .buttonStyle(.plain).font(.inter(12, weight: .medium, relativeTo: .body))
                                .foregroundStyle(DS.inkSecondary).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(DS.cardAlt))
                                .pointingHandCursor()
                        }
                    }
                } else if editingNoteId == nil {
                    Button {
                        isEditingNew = true; editorTitle = ""; editorText = ""; previewNew = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle").font(.system(size: 12, weight: .medium))
                            Text("Write a note…").font(DS.body)
                        }.foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.cardAlt))
                    }.buttonStyle(.plain).pointingHandCursor()
                }

                if notes.isEmpty && !isEditingNew {
                    Text("No notes yet").font(DS.caption).foregroundStyle(DS.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(notes) { note in
                            NoteRowView(note: note, isEditing: editingNoteId == note.id,
                                        editTitle: $editTitle, editText: $editText,
                                        previewEdit: $previewEdit, editModel: editModel,
                                        onEdit: { startEditing(note) }, onDelete: { deleteTarget = note },
                                        onCancel: { editingNoteId = nil }, onImage: { showImagePicker = true })
                            if note.id != notes.last?.id { Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 4) }
                        }
                    }
                }
            }
        }
        .dsAlert(Binding<Bool>(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                 title: "Delete note", message: "This note will be permanently removed.",
                 confirmTitle: "Delete", cancelTitle: "Cancel", destructive: true) {
            if let t = deleteTarget { storageService.deleteNote(id: t.id, from: symbol); deleteTarget = nil }
        }
        .fileImporter(isPresented: $showImagePicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let data = try? Data(contentsOf: url) {
                let filename = NoteImageStore.saveImage(data, ext: url.pathExtension.isEmpty ? "png" : url.pathExtension)
                if editingNoteId != nil { editModel.insertImageMarkdown(filename: filename) } else { newModel.insertImageMarkdown(filename: filename) }
            }
        }
    }

    private func saveNewNote() {
        let trimmed = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        storageService.addNote(to: symbol, title: editorTitle.trimmingCharacters(in: .whitespacesAndNewlines), content: trimmed)
        editorTitle = ""; editorText = ""; isEditingNew = false; previewNew = false
    }

    private func startEditing(_ note: SymbolNote) {
        isEditingNew = false
        editingNoteId = note.id; editTitle = note.title; editText = note.content; previewEdit = false
    }
}

// MARK: - Note row

private struct NoteRowView: View {
    let note: SymbolNote; let isEditing: Bool
    @Binding var editTitle: String; @Binding var editText: String
    @Binding var previewEdit: Bool
    @ObservedObject var editModel: EditorModel
    let onEdit: () -> Void; let onDelete: () -> Void; let onCancel: () -> Void; let onImage: () -> Void

    @EnvironmentObject var storageService: StorageService

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                VStack(spacing: 8) {
                    TextField("Title (optional)", text: $editTitle)
                        .textFieldStyle(.plain).font(DS.titleXL).tracking(-0.3).foregroundStyle(DS.ink)
                        .disabled(previewEdit)

                    if !previewEdit {
                        MarkdownToolbar(model: editModel, onImage: onImage)
                    }

                    if previewEdit {
                        MarkdownNoteView(markdown: editText)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.cardAlt))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.hairline, lineWidth: 1))
                    } else {
                        MarkdownEditor(text: $editText, model: editModel)
                            .frame(minHeight: 80)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.cardAlt))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.hairline, lineWidth: 1))
                            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                                for p in providers { if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) { p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in if let d = d { editModel.handleImageDrop(d) } } } }
                                return true
                            }
                    }

                    HStack(spacing: 6) {
                        Button("Save") { saveEdit() }
                            .buttonStyle(.plain).font(.inter(11, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DS.inkTertiary.opacity(0.3) : DS.brand))
                            .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .pointingHandCursor()

                        Button(previewEdit ? "Edit" : "Preview") { previewEdit.toggle() }
                            .buttonStyle(.plain).font(.inter(11, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.brand).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(DS.brand.opacity(0.12)))
                            .pointingHandCursor()

                        Button("Cancel") { cancelEdit() }
                            .buttonStyle(.plain).font(.inter(11, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(DS.cardAlt))
                            .pointingHandCursor()
                    }
                }
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !note.title.isEmpty { Text(note.title).font(DS.titleXL).tracking(-0.3).foregroundStyle(DS.ink) }
                        MarkdownNoteView(markdown: note.content).pointingHandCursor()
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 2) {
                        Button(action: onEdit) { Image(systemName: "pencil").font(.system(size: 10, weight: .medium)).foregroundStyle(DS.inkTertiary) }
                            .buttonStyle(.plain).pointingHandCursor().help("Edit note")
                        Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 10, weight: .medium)).foregroundStyle(DS.inkTertiary) }
                            .buttonStyle(.plain).pointingHandCursor().help("Delete note")
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Created: \(Self.dateFormatter.string(from: note.createdAt))").font(DS.micro).foregroundStyle(DS.inkTertiary)
                if note.updatedAt != note.createdAt { Text("· Edited: \(Self.dateFormatter.string(from: note.updatedAt))").font(DS.micro).foregroundStyle(DS.inkTertiary) }
            }
        }.padding(.vertical, 8)
    }

    private func saveEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for (sym, notes) in storageService.symbolNotes {
            if notes.contains(where: { $0.id == note.id }) {
                storageService.updateNote(id: note.id, for: sym, title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines), content: trimmed)
                break
            }
        }
    }

    private func cancelEdit() {
        editTitle = note.title; editText = note.content; previewEdit = false
        onCancel()
    }
}