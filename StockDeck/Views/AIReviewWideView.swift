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

    @ViewBuilder
    private func messageBubble(_ vm: AIReviewViewModel, message: AIChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer()
                Text(message.content)
                    .font(DS.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(DS.brand))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                MarkdownText(message.content, baseFont: DS.body)
                    .foregroundStyle(DS.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.cardAlt))
                    .fixedSize(horizontal: false, vertical: true)
                    .contextMenu {
                        Button { copy(message.content) } label: { Label("Copy", systemImage: "doc.on.doc") }
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
                MarkdownText(message.content, baseFont: DS.body)
                    .foregroundStyle(DS.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.cardAlt))
                    .fixedSize(horizontal: false, vertical: true)
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
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(DS.down)
                    Text(error).font(DS.micro).foregroundStyle(DS.down)
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about your portfolio…", text: Binding(
                    get: { vm.draft },
                    set: { vm.draft = $0 }
                ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.body)
                    .lineLimit(1...4)
                    .focused($composerFocused)
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
        !vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.isSending
    }

    private func canSaveWorkspace(_ vm: AIReviewViewModel) -> Bool {
        !vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit(_ vm: AIReviewViewModel) {
        guard canSubmit(vm) else { return }
        Task { await vm.sendCurrentMessage() }
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
/// headers) override it. Do NOT apply `.font()` from the caller — it overrides
/// every attribute inside the AttributedString.
private struct MarkdownText: View {
    let content: String
    let baseFont: Font

    init(_ content: String, baseFont: Font = DS.body) {
        self.content = content
        self.baseFont = baseFont
    }

    var body: some View {
        Text(attributed())
            .textSelection(.enabled)
    }

    private func attributed() -> AttributedString {
        let lines = content.components(separatedBy: "\n")
        var out = AttributedString()
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            var attributed = AttributedString()

            if line.isEmpty {
                attributed = AttributedString()
            } else if isHorizontalRule(line) {
                // `---`, `***`, `___` → blank line keeps the visual break clean.
                attributed = AttributedString()
            } else if line.contains("|"), isTableSeparatorRow(line) {
                // Markdown table separator row (| --- | --- |) → skip entirely.
                attributed = AttributedString()
            } else if line.hasPrefix("#") {
                // Header: keep the level text, drop the "#" marker.
                let level = line.prefix { $0 == "#" }.count
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                var header = applyBold(AttributedString(text))
                header.font = .inter(level >= 3 ? 13 : 14, weight: .semibold, relativeTo: .body)
                attributed = header
            } else if line.contains("|"), isTableRow(line) {
                attributed = tableRow(line)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let item = applyBold(AttributedString(String(line.dropFirst(2))))
                var bullet = AttributedString("•  ")
                bullet.font = .inter(12.5, weight: .bold, relativeTo: .body)
                bullet.foregroundColor = DS.brand
                attributed = bullet + item
            } else if let dot = line.firstIndex(of: "."),
                      let num = Int(line[..<dot]), line[dot...].hasPrefix(". ") {
                let item = applyBold(AttributedString(String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)))
                attributed = AttributedString("\(num).  ") + item
            } else {
                attributed = applyBold(AttributedString(line))
            }

            out += attributed
            if index < lines.count - 1 {
                out += AttributedString("\n")
            }
        }

        // Give every unstyled run the base font so plain text doesn't fall back
        // to the system default. Explicit fonts (bold, headers, bullets) win.
        var styled = out
        for run in styled.runs where run.font == nil {
            styled[run.range].font = baseFont
        }
        return styled
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.filter { $0 != " " }
        guard stripped.count >= 3 else { return false }
        let set = Set(stripped)
        return set.count == 1 && set.first != nil && "*-_=~".contains(set.first!)
    }

    /// A markdown table has pipes and at least two cells; the separator row
    /// (`| --- | --- |`) is skipped entirely.
    private func isTableSeparatorRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = line.split(separator: "|").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { $0.filter { !" -:".contains($0) }.isEmpty }
    }

    private func isTableRow(_ line: String) -> Bool {
        guard !isTableSeparatorRow(line) else { return false }
        let cells = line.split(separator: "|").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return cells.count >= 2
    }

    private func tableRow(_ line: String) -> AttributedString {
        let cells = line.split(separator: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        var row = AttributedString()
        for (i, cell) in cells.enumerated() {
            let rendered = applyBold(AttributedString(cell))
            // First row = header → semibold, like a markdown table header.
            row += rendered
            if i < cells.count - 1 {
                row += AttributedString("   ")
            }
        }
        return row
    }

    /// Bold on `**…**` runs — renders only the captured content, dropping the
    /// literal asterisks. Everything else passes through unchanged. Extracts
    /// the characters via `.characters` (NOT `.description`, which appends the
    /// attribute containers as literal `{ … }` text), and advances past the
    /// whole `**…**` match so no stray asterisk survives.
    private func applyBold(_ attributed: AttributedString) -> AttributedString {
        let text = String(attributed.characters)
        var result = AttributedString()
        let pattern = "\\*\\*(.+?)\\*\\*"
        var cursor = text.startIndex
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributed }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: nsRange) {
            guard let full = Range(match.range, in: text),
                  match.numberOfRanges >= 2,
                  let inner = Range(match.range(at: 1), in: text) else { continue }
            if full.lowerBound > cursor {
                result += AttributedString(String(text[cursor..<full.lowerBound]))
            }
            var bold = AttributedString(String(text[inner]))
            bold.font = Font.inter(12.5, weight: .semibold, relativeTo: .body)
            result += bold
            cursor = full.upperBound
        }
        if cursor < text.endIndex {
            result += AttributedString(String(text[cursor...]))
        }
        return result.characters.isEmpty ? attributed : result
    }
}
