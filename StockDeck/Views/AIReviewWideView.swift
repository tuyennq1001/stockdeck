import AppKit
import SwiftUI

/// Desktop AI Review tab: a conversation pane that lets the user chat with an
/// AI about their real portfolio, plus a history rail. Requires an API key
/// configured in Settings.
struct AIReviewWideView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @State private var viewModel: AIReviewViewModel?
    @FocusState private var composerFocused: Bool
    /// Jumps the user to the Settings pane to configure an API key.
    let onOpenSettings: () -> Void

    init(onOpenSettings: @escaping () -> Void = {}) {
        self.onOpenSettings = onOpenSettings
    }

    private var vm: AIReviewViewModel? {
        viewModel ?? AIReviewViewModel(stockService: stockService, storageService: storageService)
    }

    var body: some View {
        PageScaffold("AI Review", caption: "Chat about your portfolio — data is real, context built in.") {
            EmptyView()
        } content: {
            Group {
                if !storageService.hasAIConfiguration {
                    missingConfigState
                } else if let vm {
                    chatLayout(vm)
                }
            }
        }
        .navigationTitle("AI Review")
        .onAppear { ensureViewModel() }
        .onChange(of: storageService.hasAIConfiguration) { _, configured in
            if configured { ensureViewModel() }
        }
    }

    private func ensureViewModel() {
        guard viewModel == nil, storageService.hasAIConfiguration else { return }
        viewModel = AIReviewViewModel(stockService: stockService, storageService: storageService)
        // Only auto-create a thread when there are none — re-visiting the tab
        // must not duplicate "New conversation" rows.
        if storageService.aiChatSections.isEmpty {
            viewModel?.newChat()
        } else if let mostRecent = storageService.aiChatSections.first {
            viewModel?.select(mostRecent)
        }
    }

    // MARK: - Missing API key

    private var missingConfigState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "key.fill").font(.system(size: 30)).foregroundStyle(DS.inkTertiary)
            Text("AI Review needs an API key")
                .font(DS.title).foregroundStyle(DS.ink)
            Text("Add your provider key in Settings → AI Review to start chatting about your portfolio. Works with OpenAI, DeepSeek, Groq, OpenRouter and other OpenAI-compatible providers.")
                .font(DS.body).foregroundStyle(DS.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(action: onOpenSettings) {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                    Text("Open Settings")
                }
                .font(.inter(12, weight: .semibold, relativeTo: .body))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(DS.brand))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chat layout

    private func chatLayout(_ vm: AIReviewViewModel) -> some View {
        HStack(spacing: DS.gap) {
            historyRail(vm)
            conversationPane(vm)
        }
        .pageColumn()
        .padding(.top, 4)
    }

    // MARK: - History rail

    private func historyRail(_ vm: AIReviewViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                vm.newChat()
            } label: {
                Label("New conversation", systemImage: "square.and.pencil")
                    .font(.inter(12, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(DS.brand))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Divider().overlay(DS.hairline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(storageService.aiChatSections) { section in
                        historyRow(vm, section: section)
                    }
                }
            }
        }
        .frame(width: 220)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.hairline))
    }

    private func historyRow(_ vm: AIReviewViewModel, section: AIChatSection) -> some View {
        let selected = vm.selectedSectionID == section.id
        return Button {
            vm.select(section)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left").font(.system(size: 10)).foregroundStyle(selected ? DS.brand : DS.inkTertiary)
                Text(section.title)
                    .font(.inter(11.5, weight: selected ? .semibold : .regular, relativeTo: .caption))
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? DS.brand.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .contextMenu {
            Button { renameChat(section) } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { vm.delete(section) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @State private var renameTarget: AIChatSection?
    @State private var renameText = ""

    private func renameChat(_ section: AIChatSection) {
        renameTarget = section
        renameText = section.title
    }

    // MARK: - Conversation pane

    private func conversationPane(_ vm: AIReviewViewModel) -> some View {
        VStack(spacing: 0) {
            workspaceBar(vm)
            if let section = vm.selectedSection {
                messagesList(vm, section: section)
            } else {
                emptyThread
            }
            composer(vm)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.hairline))
        .sheet(item: $renameTarget) { target in
            renameSheet(target)
        }
        .onChange(of: vm.selectedSectionID) { _,_ in
            composerFocused = false
        }
    }

    /// Workspace toolbar: shows the durable `ai-context.md` file that grounds
    /// every reply. The AI always sees the combined portfolio context plus any
    /// notes the user keeps in this folder.
    private func workspaceBar(_ vm: AIReviewViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(DS.inkTertiary)
            Text("Workspace").font(.inter(11, weight: .medium, relativeTo: .caption)).foregroundStyle(DS.inkSecondary)
            if let notes = storageService.aiWorkspaceContextText(), !notes.isEmpty {
                Text("· notes ready").font(.inter(11, relativeTo: .caption)).foregroundStyle(DS.inkTertiary)
            }
            Spacer()
            if let path = storageService.ensureAIWorkspace() {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([path.appendingPathComponent("ai-context.md")])
                } label: {
                    Text("Open folder").font(.inter(11, weight: .medium, relativeTo: .caption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.inkSecondary)
                .pointingHandCursor()
                .help("Open the workspace folder (ai-context.md) — every reply is grounded on this file")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().overlay(DS.hairline) }
    }

    private var emptyThread: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(DS.brand)
            Text("Ask anything about your portfolio")
                .font(DS.title).foregroundStyle(DS.ink)
            Text("The AI sees your combined portfolio and the notes in your workspace folder (ai-context.md).")
                .font(DS.caption).foregroundStyle(DS.inkTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messagesList(_ vm: AIReviewViewModel, section: AIChatSection) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(section.messages) { message in
                        messageBubble(vm, message: message)
                            .id(message.id)
                    }
                    if vm.isSending {
                        HStack(spacing: 8) {
                            DSSpinner(size: 12)
                            Text("Thinking…").font(DS.caption).foregroundStyle(DS.inkTertiary)
                        }
                        .padding(.horizontal, 4)
                        .id("typing")
                    }
                }
                .padding(DS.pad)
            }
            .onChange(of: section.messages.count) { _,_ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(section.messages.last?.id, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = section.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private static let messageTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm · dd/MM"
        return f
    }()

    @ViewBuilder
    private func messageBubble(_ vm: AIReviewViewModel, message: AIChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    if let base64 = message.imageBase64,
                       let data = Data(base64Encoded: base64.replacingOccurrences(of: "data:image/jpeg;base64,", with: "")) {
                        if let nsImg = NSImage(data: data) {
                            Image(nsImage: nsImg)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240, maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.hairline, lineWidth: 1))
                        }
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(DS.body)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.brand))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(Self.messageTimeFormatter.string(from: message.createdAt))
                        .font(.inter(9.5, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                        .padding(.trailing, 4)
                }
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownText(message.content, baseFont: DS.body)
                        .foregroundStyle(DS.ink)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.cardAlt))
                        .fixedSize(horizontal: false, vertical: true)
                        .contextMenu {
                            Button { copy(message.content) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        }

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.inkTertiary)
                        Text("Phân tích lúc \(Self.messageTimeFormatter.string(from: message.createdAt))")
                            .font(.inter(9.5, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)
                    }
                    .padding(.leading, 4)
                }

                Button {
                    copy(message.content)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.inkTertiary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Copy full reply")
                Spacer()
            }
        case .report:
            // Legacy role from older builds that auto-generated a health card.
            // No longer produced; render the stored content as a normal message
            // so old conversations still display something meaningful.
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownText(message.content, baseFont: DS.body)
                        .foregroundStyle(DS.ink)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.cardAlt))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(Self.messageTimeFormatter.string(from: message.createdAt))
                        .font(.inter(9.5, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                        .padding(.leading, 4)
                }
                Spacer()
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Composer

    private func composer(_ vm: AIReviewViewModel) -> some View {
        VStack(spacing: 8) {
            if let error = vm.errorMessage {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.down)
                    Text(error)
                        .font(DS.micro)
                        .foregroundStyle(DS.down)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Đóng") {
                        vm.errorMessage = nil
                    }
                    .buttonStyle(.plain)
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.down.opacity(0.1)))
            }

            // Image attachment preview
            let thumbnailImg: NSImage? = vm.attachedImageData.flatMap { NSImage(data: $0) }
            if let thumbnailImg {
                HStack(spacing: 10) {
                    Image(nsImage: thumbnailImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.hairline, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Image attached")
                            .font(.inter(11, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(DS.ink)
                        Text("Will be analyzed along with your question")
                            .font(DS.micro)
                            .foregroundStyle(DS.inkTertiary)
                    }

                    Spacer()

                    Button {
                        vm.attachedImageData = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(DS.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.cardAlt.opacity(0.8)))
            }

            HStack(alignment: .bottom, spacing: 10) {
                // Attach image button
                Button {
                    chooseOrPasteImage(vm)
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(vm.attachedImageData != nil ? DS.brand : DS.inkSecondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(DS.cardAlt))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Attach or paste image from clipboard (Cmd+V)")

                TextField("Ask about your portfolio… (Shift+Enter for newline)", text: Binding(
                    get: { vm.draft },
                    set: { vm.draft = $0 }
                ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.body)
                    .lineLimit(2...6)
                    .frame(minHeight: 44)
                    .focused($composerFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if !press.modifiers.contains(.shift) && !press.modifiers.contains(.option) {
                            if canSubmit(vm) {
                                submit(vm)
                            }
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.init("v"), phases: .down) { press in
                        if press.modifiers == .command {
                            if pasteImageFromClipboard(vm) {
                                return .handled
                            }
                        }
                        return .ignored
                    }
                    .onSubmit { submit(vm) }

                Button {
                    let saved = vm.saveToWorkspace(vm.draft)
                    if saved {
                        vm.draft = ""
                        vm.errorMessage = nil
                    } else {
                        vm.errorMessage = "Set a workspace folder in Settings → AI Review to save notes."
                    }
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(canSaveWorkspace(vm) ? DS.inkSecondary : DS.inkTertiary.opacity(0.4))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(DS.cardAlt))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSaveWorkspace(vm))
                .pointingHandCursor()
                .help("Save as a durable workspace note (ai-context.md) — remembered across conversations")

                Button {
                    submit(vm)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSubmit(vm) ? DS.brand : DS.inkTertiary.opacity(0.35)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit(vm))
                .pointingHandCursor()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.cardAlt))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(composerFocused ? DS.brand : .clear, lineWidth: 1.5))
        }
        .padding(DS.pad)
        .overlay(alignment: .top) { Divider().overlay(DS.hairline) }
    }

    private func canSubmit(_ vm: AIReviewViewModel) -> Bool {
        (!vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.attachedImageData != nil) && !vm.isSending
    }

    private func canSaveWorkspace(_ vm: AIReviewViewModel) -> Bool {
        !vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit(_ vm: AIReviewViewModel) {
        guard canSubmit(vm) else { return }
        Task { await vm.sendCurrentMessage() }
    }

    @discardableResult
    private func pasteImageFromClipboard(_ vm: AIReviewViewModel) -> Bool {
        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb) {
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                vm.attachedImageData = jpeg
                return true
            }
        }
        return false
    }

    private func chooseOrPasteImage(_ vm: AIReviewViewModel) {
        if pasteImageFromClipboard(vm) { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.prompt = "Attach"
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            if let img = NSImage(data: data),
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                vm.attachedImageData = jpeg
            } else {
                vm.attachedImageData = data
            }
        }
    }

    // MARK: - Rename sheet

    private func renameSheet(_ section: AIChatSection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename conversation").font(.inter(15, weight: .bold, relativeTo: .headline))
            TextField("Title", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirmRename(section) }
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
                Button("Rename") { confirmRename(section) }
                    .buttonStyle(.borderedProminent).tint(DS.brand)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func confirmRename(_ section: AIChatSection) {
        if let vm {
            vm.rename(section, to: renameText)
        }
        renameTarget = nil
    }
}

/// Renders the AI's plain-text markdown-ish content (headers, bold, bullets and
/// numbered lists) as ONE `AttributedString` inside a single `Text`. A single
/// text run is what makes multi-line selection & copy work reliably on macOS.
/// `baseFont` becomes the default for unstyled runs; inline attributes (bold,
private struct MarkdownText: View {
    let content: String
    let baseFont: Font

    init(_ content: String, baseFont: Font = DS.body) {
        self.content = content
        self.baseFont = baseFont
    }

    private enum MarkdownBlock {
        case header(level: Int, text: String)
        case paragraph(text: String)
        case bullet(text: String)
        case numbered(index: Int, text: String)
        case table(headers: [String], rows: [[String]])
        case divider
    }

    var body: some View {
        let blocks = parseBlocks(content)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { idx in
                renderBlock(blocks[idx])
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .header(let level, let text):
            Text(inlineAttr(text))
                .font(.inter(level == 1 ? 14 : (level == 2 ? 13 : 12), weight: .semibold, relativeTo: .body))
                .foregroundStyle(DS.ink)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let text):
            Text(inlineAttr(text))
                .font(baseFont)
                .foregroundStyle(DS.ink)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.inter(12, weight: .bold, relativeTo: .body))
                    .foregroundStyle(DS.brand)
                    .frame(width: 12, alignment: .center)
                Text(inlineAttr(text))
                    .font(baseFont)
                    .foregroundStyle(DS.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .numbered(let index, let text):
            HStack(alignment: .top, spacing: 6) {
                Text("\(index).")
                    .font(.inter(11.5, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(inlineAttr(text))
                    .font(baseFont)
                    .foregroundStyle(DS.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .table(let headers, let rows):
            renderTable(headers: headers, rows: rows)

        case .divider:
            Divider()
                .overlay(DS.hairline)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func renderTable(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                if !headers.isEmpty {
                    GridRow {
                        ForEach(0..<headers.count, id: \.self) { c in
                            Text(inlineAttr(headers[c]))
                                .font(.inter(11, weight: .semibold, relativeTo: .caption))
                                .foregroundStyle(DS.ink)
                        }
                    }
                    Divider()
                        .gridCellColumns(max(headers.count, 1))
                }

                ForEach(0..<rows.count, id: \.self) { r in
                    let row = rows[r]
                    GridRow {
                        ForEach(0..<headers.count, id: \.self) { c in
                            let cellText = c < row.count ? row[c] : ""
                            Text(inlineAttr(cellText))
                                .font(.inter(11, weight: .regular, relativeTo: .caption))
                                .foregroundStyle(DS.inkSecondary)
                        }
                    }
                    if r < rows.count - 1 {
                        Divider()
                            .opacity(0.3)
                            .gridCellColumns(max(headers.count, 1))
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.cardAlt.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DS.hairline, lineWidth: 1)
            )
        }
        .padding(.vertical, 2)
    }

    private func inlineAttr(_ text: String) -> AttributedString {
        if let attr = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attr
        }
        return AttributedString(text)
    }

    private func parseBlocks(_ raw: String) -> [MarkdownBlock] {
        let lines = raw.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0

        func isSeparatorRow(_ line: String) -> Bool {
            guard line.contains("|") else { return false }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard cells.count >= 2 else { return false }
            return cells.allSatisfy { cell in
                cell.allSatisfy { " -:".contains($0) }
            }
        }

        func isTableRow(_ line: String) -> Bool {
            guard line.contains("|") && !isSeparatorRow(line) else { return false }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return cells.count >= 2
        }

        func isHorizontalRule(_ line: String) -> Bool {
            let stripped = line.filter { $0 != " " }
            guard stripped.count >= 3 else { return false }
            let set = Set(stripped)
            return set.count == 1 && set.first != nil && "*-_=~".contains(set.first!)
        }

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                i += 1
                continue
            }

            // Table check (header row + separator row)
            if isTableRow(line) && i + 1 < lines.count && isSeparatorRow(lines[i + 1]) {
                let headers = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                i += 2 // skip header and separator
                var rows: [[String]] = []
                while i < lines.count && isTableRow(lines[i]) {
                    let rowCells = lines[i].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    rows.append(rowCells)
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if isHorizontalRule(line) {
                blocks.append(.divider)
                i += 1
                continue
            }

            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.header(level: level, text: text))
                i += 1
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                blocks.append(.bullet(text: text))
                i += 1
                continue
            }

            if let dotIndex = line.firstIndex(of: "."),
               let num = Int(line[..<dotIndex]),
               line[dotIndex...].hasPrefix(". ") {
                let text = String(line[line.index(after: dotIndex)...]).trimmingCharacters(in: .whitespaces)
                blocks.append(.numbered(index: num, text: text))
                i += 1
                continue
            }

            // Regular paragraph line
            blocks.append(.paragraph(text: line))
            i += 1
        }

        return blocks
    }
}
