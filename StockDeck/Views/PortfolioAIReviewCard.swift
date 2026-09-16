import AppKit
import SwiftUI

/// Embedded AI Review & Advisor card placed at the bottom of PortfolioOverview.
/// Integrates an onboarding investor profile collection form, 1-click quick prompts,
/// and an interactive conversation pane grounded on real portfolio data and user profile.
struct PortfolioAIReviewCard: View {
    let scope: PortfolioScope
    let viewModel: PortfolioViewModel?

    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService

    @AppStorage("portfolio_ai_review_expanded") private var isExpanded: Bool = false
    @State private var draft: String = ""
    @State private var isSending: Bool = false
    @State private var attachedImageData: Data? = nil
    @State private var errorMessage: String? = nil
    @State private var showEditProfileSheet: Bool = false
    @State private var showResetChatConfirm: Bool = false

    @FocusState private var isComposerFocused: Bool

    private var reviewScope: AIReviewScope {
        switch scope {
        case .all: return .allPortfolios
        case .portfolio(let id): return .portfolio(id)
        }
    }

    /// Finds or returns the section ID dedicated to this scope
    private var currentSection: AIChatSection? {
        let sid = reviewScope.idString
        if let existing = storageService.aiChatSections.first(where: { $0.scopeID == sid }) {
            return existing
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            if isExpanded {
                Divider().overlay(DS.hairline)

                if !storageService.hasAIConfiguration {
                    missingConfigView
                } else if storageService.investorProfile == nil {
                    investorProfileOnboardingView
                } else {
                    activeConsultationView
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DS.brand.opacity(0.18), lineWidth: 1.2)
        )
        .sheet(isPresented: $showEditProfileSheet) {
            InvestorProfileEditorSheet(
                initialProfile: storageService.investorProfile ?? InvestorProfile(),
                onSave: { updated in
                    storageService.investorProfile = updated
                    showEditProfileSheet = false
                },
                onCancel: {
                    showEditProfileSheet = false
                }
            )
        }
        .alert("Xóa cuộc trò chuyện này?", isPresented: $showResetChatConfirm) {
            Button("Hủy", role: .cancel) { }
            Button("Xóa", role: .destructive) {
                clearCurrentScopeChat()
            }
        } message: {
            Text("Lịch sử tư vấn của danh mục này sẽ được làm mới lại.")
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.brand)
                Text("AI PORTFOLIO REVIEW & ADVISOR")
                    .font(.inter(11, weight: .bold, relativeTo: .caption))
                    .tracking(1.1)
                    .foregroundStyle(DS.brand)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(DS.brand.opacity(0.12)))

            Text("· \(reviewScope.label)")
                .font(DS.caption)
                .foregroundStyle(DS.inkTertiary)

            Spacer()

            if storageService.investorProfile != nil {
                Button {
                    showEditProfileSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 11))
                        Text("Hồ sơ")
                            .font(.inter(11, weight: .medium, relativeTo: .caption))
                    }
                    .foregroundStyle(DS.inkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.cardAlt))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Chỉnh sửa Hồ sơ & Mục tiêu nhà đầu tư")

                if let current = currentSection, !current.messages.isEmpty {
                    Button {
                        showResetChatConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.inkTertiary)
                            .padding(6)
                            .background(Circle().fill(DS.cardAlt))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Xóa lịch sử tư vấn này")
                }
            }

            if !isExpanded, let current = currentSection, !current.messages.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 9))
                    Text("\(current.messages.count) tin nhắn")
                        .font(.inter(10.5, weight: .medium, relativeTo: .caption))
                }
                .foregroundStyle(DS.brand)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(DS.brand.opacity(0.12)))
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(DS.cardAlt))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(isExpanded ? "Thu gọn" : "Mở rộng")
        }
        .padding(14)
    }

    // MARK: - Missing API Key

    private var missingConfigView: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 24))
                .foregroundStyle(DS.inkTertiary)
            Text("Cần cấu hình API Key để sử dụng AI Review")
                .font(DS.title)
                .foregroundStyle(DS.ink)
            Text("Vui lòng vào Settings → AI Review để nhập API key (OpenAI, DeepSeek, Groq, OpenRouter...).")
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Onboarding View (Init Form)

    private var investorProfileOnboardingView: some View {
        InvestorProfileInlineSetupView { newProfile in
            storageService.investorProfile = newProfile
        }
    }

    // MARK: - Active Consultation View

    private var activeConsultationView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Profile Summary Pill
            if let profile = storageService.investorProfile {
                HStack(spacing: 8) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.brand)

                    Text(profile.summaryDescription)
                        .font(.inter(11.5, weight: .medium, relativeTo: .caption))
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)

                    if !profile.primaryGoal.isEmpty {
                        Text("•")
                            .foregroundStyle(DS.inkTertiary)
                        Text(profile.primaryGoal)
                            .font(.inter(11.5, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        showEditProfileSheet = true
                    } label: {
                        Text("Sửa")
                            .font(.inter(11, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(DS.brand)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.cardAlt))
            }

            // Quick Prompts Chips
            quickPromptsSection

            // Messages Stream
            if let current = currentSection, !current.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(current.messages) { msg in
                                chatMessageBubble(msg)
                                    .id(msg.id)
                            }
                            if isSending {
                                HStack(spacing: 8) {
                                    DSSpinner(size: 13)
                                    Text("AI đang phân tích danh mục và hồ sơ của bạn…")
                                        .font(DS.caption)
                                        .foregroundStyle(DS.inkSecondary)
                                }
                                .padding(.vertical, 6)
                                .id("typing")
                            }
                            Color.clear.frame(height: 1).id("chatBottom")
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                    .frame(maxHeight: 340)
                    .onAppear {
                        if let last = current.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: current.messages.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("chatBottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: isSending) { _, sending in
                        if sending {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("typing", anchor: .bottom)
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("chatBottom", anchor: .bottom)
                            }
                        }
                    }
                }
            } else if !isSending {
                VStack(spacing: 8) {
                    Text("💡 Nhấn vào một trong các câu hỏi gợi ý bên trên hoặc nhập câu hỏi bên dưới để AI phân tích danh mục của bạn.")
                        .font(DS.caption)
                        .foregroundStyle(DS.inkTertiary)
                        .padding(.vertical, 8)
                }
            } else {
                HStack(spacing: 8) {
                    DSSpinner(size: 13)
                    Text("AI đang phân tích danh mục và hồ sơ của bạn…")
                        .font(DS.caption)
                        .foregroundStyle(DS.inkSecondary)
                }
                .padding(.vertical, 6)
            }

            // Error message if any
            if let error = errorMessage {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.down)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lỗi phản hồi từ AI")
                            .font(.inter(11, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(DS.down)
                        Text(error)
                            .font(DS.micro)
                            .foregroundStyle(DS.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Đóng") {
                        errorMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.down.opacity(0.1)))
            }

            // Composer
            composerBar

            // Disclaimer
            HStack(spacing: 5) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.inkTertiary)
                Text("AI phân tích dựa trên dữ liệu giá đóng cửa phiên chính & hồ sơ của bạn. Không phải lời khuyên tài chính được cấp phép.")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
            }
            .padding(.top, 2)
        }
        .padding(14)
    }

    // MARK: - Quick Prompts

    private var quickPromptsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickPromptChip(
                    icon: "target",
                    title: "Đánh giá theo mục tiêu",
                    prompt: "Hãy đánh giá toàn diện danh mục hiện tại của tôi xem có phù hợp với mục tiêu và thời hạn trong hồ sơ đầu tư của tôi hay không."
                )
                quickPromptChip(
                    icon: "scale.3d",
                    title: "Kiểm tra phân bổ rủi ro",
                    prompt: "Kiểm tra mức độ phân bổ rủi ro, tỷ trọng các mã và tài sản trong danh mục này so với khẩu vị rủi ro trong hồ sơ của tôi."
                )
                quickPromptChip(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Gợi ý tái cân bằng (Rebalancing)",
                    prompt: "Dựa trên hồ sơ của tôi và thị trường hiện tại, bạn có gợi ý tái cân bằng danh mục hay tối ưu tỷ trọng tài sản nào không?"
                )
                quickPromptChip(
                    icon: "exclamationmark.shield",
                    title: "Điểm rủi ro lớn nhất",
                    prompt: "Chỉ ra 3 điểm rủi ro lớn nhất hoặc điểm yếu cần lưu ý trong danh mục đầu tư hiện tại của tôi."
                )
                quickPromptChip(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "So sánh với S&P 500",
                    prompt: "So sánh hiệu suất và mức độ rủi ro danh mục của tôi so với chỉ số chuẩn S&P 500 và đưa ra nhận xét."
                )
            }
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func quickPromptChip(icon: String, title: String, prompt: String) -> some View {
        Button {
            sendUserMessage(text: prompt)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.brand)
                Text(title)
                    .font(.inter(11, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(DS.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(DS.cardAlt)
                    .overlay(Capsule().strokeBorder(DS.hairline, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .pointingHandCursor()
    }

    private static let messageTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm · dd/MM"
        return f
    }()

    @ViewBuilder
    private func chatMessageBubble(_ message: AIChatMessage) -> some View {
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
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.brand))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(Self.messageTimeFormatter.string(from: message.createdAt))
                        .font(.inter(9.5, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                        .padding(.trailing, 4)
                }
            }
        case .assistant, .report:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        AIMarkdownRenderer(content: message.content)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.cardAlt))
                            .fixedSize(horizontal: false, vertical: true)

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
                        copyToClipboard(message.content)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DS.inkTertiary)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Sao chép câu trả lời")

                    Spacer()
                }
            }
        }
    }

    // MARK: - Composer Bar

    private var composerBar: some View {
        VStack(spacing: 8) {
            // Attached Image Thumbnail Preview
            let thumbnailImg: NSImage? = attachedImageData.flatMap { NSImage(data: $0) }
            if let thumbnailImg {
                HStack(spacing: 10) {
                    Image(nsImage: thumbnailImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.hairline, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Đã đính kèm ảnh")
                            .font(.inter(11, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(DS.ink)
                        Text("Nhấn Enter để gửi ảnh cùng câu hỏi cho AI")
                            .font(DS.micro)
                            .foregroundStyle(DS.inkTertiary)
                    }

                    Spacer()

                    Button {
                        attachedImageData = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(DS.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Xóa ảnh đính kèm")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.cardAlt.opacity(0.85)))
            }

            HStack(alignment: .bottom, spacing: 10) {
                // Attach Image Button
                Button {
                    chooseOrPasteImage()
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(attachedImageData != nil ? DS.brand : DS.inkSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(DS.cardAlt))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Đính kèm hoặc dán ảnh từ clipboard (Cmd+V)")

                TextField("Hỏi AI về danh mục, phân bổ rủi ro… (Enter để gửi, Shift+Enter xuống dòng)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.body)
                    .lineLimit(3...8)
                    .frame(minHeight: 52)
                    .focused($isComposerFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if !press.modifiers.contains(.shift) && !press.modifiers.contains(.option) {
                            if canSubmit {
                                submitDraft()
                            }
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.init("v"), phases: .down) { press in
                        if press.modifiers == .command {
                            if pasteImageFromClipboard() {
                                return .handled
                            }
                        }
                        return .ignored
                    }
                    .onSubmit {
                        submitDraft()
                    }

                Button {
                    submitDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle().fill(canSubmit ? DS.brand : DS.inkTertiary.opacity(0.35))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .pointingHandCursor()
                .help("Gửi câu hỏi (Enter)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.cardAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isComposerFocused ? DS.brand : .clear, lineWidth: 1.5)
            )
        }
    }

    private var canSubmit: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImageData != nil) && !isSending
    }

    private func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || attachedImageData != nil), !isSending else { return }
        let img = attachedImageData
        draft = ""
        attachedImageData = nil
        sendUserMessage(text: text, imageData: img)
    }

    @discardableResult
    private func pasteImageFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb) {
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                self.attachedImageData = jpeg
                return true
            }
        }
        return false
    }

    private func chooseOrPasteImage() {
        if pasteImageFromClipboard() {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.prompt = "Đính kèm"
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            if let img = NSImage(data: data),
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                self.attachedImageData = jpeg
            } else {
                self.attachedImageData = data
            }
        }
    }

    private func sendUserMessage(text: String, imageData: Data? = nil) {
        guard !storageService.aiApiKey.isEmpty else {
            errorMessage = "Vui lòng nhập API key trong Settings → AI Review trước."
            return
        }

        let sid = reviewScope.idString
        var section: AIChatSection
        if let idx = storageService.aiChatSections.firstIndex(where: { $0.scopeID == sid }) {
            section = storageService.aiChatSections[idx]
        } else {
            section = AIChatSection(title: "AI Review - \(reviewScope.label)", scopeID: sid)
            storageService.aiChatSections.insert(section, at: 0)
        }

        let imgBase64 = imageData?.base64EncodedString()

        // Append user message
        section.messages.append(AIChatMessage(role: .user, content: text, imageBase64: imgBase64))
        section.updatedAt = Date()
        if let idx = storageService.aiChatSections.firstIndex(where: { $0.id == section.id }) {
            storageService.aiChatSections[idx] = section
        }

        errorMessage = nil
        isSending = true

        Task {
            let context = AIPortfolioContext.build(
                storageService: storageService,
                stockService: stockService,
                scope: reviewScope,
                viewModel: viewModel
            )
            let apiMsgs = section.apiMessages(window: 12)

            let request = AIReviewService.Request(
                baseURL: storageService.aiBaseURL,
                apiKey: storageService.aiApiKey,
                model: storageService.aiModel,
                systemContext: context.contextText,
                messages: apiMsgs,
                thinking: storageService.aiProvider == "deepseek" ? storageService.aiDeepseekThinking : nil
            )

            do {
                let rawReply = try await AIReviewService.shared.send(request: request)
                let cleanedReply = stripSaveMarker(from: rawReply)

                if let idx = storageService.aiChatSections.firstIndex(where: { $0.id == section.id }) {
                    var updated = storageService.aiChatSections[idx]
                    updated.messages.append(AIChatMessage(role: .assistant, content: cleanedReply))
                    updated.updatedAt = Date()
                    storageService.aiChatSections[idx] = updated
                }

                persistWorkspaceSaveIfNeeded(rawReply)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    private func clearCurrentScopeChat() {
        let sid = reviewScope.idString
        storageService.aiChatSections.removeAll { $0.scopeID == sid }
    }

    private func stripSaveMarker(from reply: String) -> String {
        let pattern = "\\[SAVE_TO_WORKSPACE\\]\\s*[\\s\\S]*?\\s*\\[/SAVE_TO_WORKSPACE\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return reply }
        let range = NSRange(reply.startIndex..., in: reply)
        let stripped = regex.stringByReplacingMatches(in: reply, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistWorkspaceSaveIfNeeded(_ reply: String) {
        let pattern = "\\[SAVE_TO_WORKSPACE\\]\\s*([\\s\\S]*?)\\s*\\[/SAVE_TO_WORKSPACE\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: reply, range: NSRange(reply.startIndex..., in: reply)),
              match.numberOfRanges >= 2,
              let contentRange = Range(match.range(at: 1), in: reply) else { return }
        let note = String(reply[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        storageService.appendAIWorkspaceNote(note)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Inline Setup View (Onboarding Form)

struct InvestorProfileInlineSetupView: View {
    let onSave: (InvestorProfile) -> Void

    @State private var ageText: String = "27"
    @State private var maritalStatus: String = "Độc thân"
    @State private var riskTolerance: RiskTolerance = .aggressive
    @State private var investmentStyle: InvestmentStyle = .dcaBuyAndHold
    @State private var investmentHorizon: InvestmentHorizon = .longTerm
    @State private var primaryGoal: String = "10 năm sau mua nhà và 40 năm sau nghỉ hưu, sẵn sàng chấp nhận rủi ro"
    @State private var monthlySavingsText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 20))
                    .foregroundStyle(DS.brand)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Thiết lập Hồ sơ & Mục tiêu Nhà đầu tư")
                        .font(DS.title)
                        .foregroundStyle(DS.ink)
                    Text("Cung cấp thông tin cá nhân và khẩu vị rủi ro để AI phân tích và đưa ra lời khuyên phù hợp nhất với danh mục của bạn.")
                        .font(DS.caption)
                        .foregroundStyle(DS.inkSecondary)
                }
            }

            Divider().overlay(DS.hairline)

            // Basic Info Row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tuổi của bạn")
                        .font(.inter(11, weight: .semibold, relativeTo: .caption))
                        .foregroundStyle(DS.inkSecondary)
                    TextField("27", text: $ageText)
                        .textFieldStyle(.plain)
                        .font(DS.body)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DS.cardAlt))
                        .frame(width: 80)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Tình trạng gia đình")
                        .font(.inter(11, weight: .semibold, relativeTo: .caption))
                        .foregroundStyle(DS.inkSecondary)
                    HStack(spacing: 6) {
                        ForEach(["Độc thân", "Đã kết hôn", "Có con"], id: \.self) { status in
                            Button {
                                maritalStatus = status
                            } label: {
                                Text(status)
                                    .font(.inter(11, weight: maritalStatus == status ? .semibold : .regular, relativeTo: .caption))
                                    .foregroundStyle(maritalStatus == status ? .white : DS.ink)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(maritalStatus == status ? DS.brand : DS.cardAlt)
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }
                }
            }

            // Risk Tolerance Row
            VStack(alignment: .leading, spacing: 6) {
                Text("Khẩu vị rủi ro")
                    .font(.inter(11, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(DS.inkSecondary)

                HStack(spacing: 8) {
                    ForEach(RiskTolerance.allCases) { risk in
                        Button {
                            riskTolerance = risk
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(risk.shortLabel)
                                    .font(.inter(11.5, weight: riskTolerance == risk ? .bold : .medium, relativeTo: .caption))
                                    .foregroundStyle(riskTolerance == risk ? .white : DS.ink)
                                Text(risk.description)
                                    .font(.inter(9.5, relativeTo: .caption2))
                                    .foregroundStyle(riskTolerance == risk ? .white.opacity(0.85) : DS.inkTertiary)
                                    .lineLimit(2)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(riskTolerance == risk ? DS.brand : DS.cardAlt)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
            }

            // Investment Style & Horizon
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trường phái đầu tư")
                        .font(.inter(11, weight: .semibold, relativeTo: .caption))
                        .foregroundStyle(DS.inkSecondary)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(InvestmentStyle.allCases) { style in
                            Button {
                                investmentStyle = style
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: investmentStyle == style ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 10))
                                        .foregroundStyle(investmentStyle == style ? DS.brand : DS.inkTertiary)
                                    Text(style.label)
                                        .font(.inter(11, weight: investmentStyle == style ? .semibold : .regular, relativeTo: .caption))
                                        .foregroundStyle(DS.ink)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Kỳ hạn đầu tư")
                        .font(.inter(11, weight: .semibold, relativeTo: .caption))
                        .foregroundStyle(DS.inkSecondary)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(InvestmentHorizon.allCases) { horizon in
                            Button {
                                investmentHorizon = horizon
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: investmentHorizon == horizon ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 10))
                                        .foregroundStyle(investmentHorizon == horizon ? DS.brand : DS.inkTertiary)
                                    Text(horizon.label)
                                        .font(.inter(11, weight: investmentHorizon == horizon ? .semibold : .regular, relativeTo: .caption))
                                        .foregroundStyle(DS.ink)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }
                }
            }

            // Primary Goal Field
            VStack(alignment: .leading, spacing: 4) {
                Text("Mục tiêu cụ thể của bạn")
                    .font(.inter(11, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(DS.inkSecondary)
                TextField("Ví dụ: 10 năm sau mua nhà và 40 năm sau nghỉ hưu, sẵn sàng chấp nhận rủi ro", text: $primaryGoal, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.body)
                    .lineLimit(2...3)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DS.cardAlt))
            }

            // Save Action
            HStack {
                Button {
                    let defaultProfile = InvestorProfile(
                        age: 28,
                        maritalStatus: "Độc thân",
                        riskTolerance: .aggressive,
                        investmentStyle: .dcaBuyAndHold,
                        investmentHorizon: .longTerm,
                        primaryGoal: "Tự do tài chính và tăng trưởng tài sản dài hạn",
                        monthlyContribution: nil,
                        customNotes: "",
                        updatedAt: Date()
                    )
                    onSave(defaultProfile)
                } label: {
                    Text("Dùng mặc định")
                        .font(.inter(11.5, weight: .medium, relativeTo: .caption))
                        .foregroundStyle(DS.inkSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(DS.cardAlt))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Spacer()

                Button {
                    let age = Int(ageText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 27
                    let profile = InvestorProfile(
                        age: age,
                        maritalStatus: maritalStatus,
                        riskTolerance: riskTolerance,
                        investmentStyle: investmentStyle,
                        investmentHorizon: investmentHorizon,
                        primaryGoal: primaryGoal,
                        monthlyContribution: Double(monthlySavingsText.trimmingCharacters(in: .whitespacesAndNewlines)),
                        customNotes: "",
                        updatedAt: Date()
                    )
                    onSave(profile)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Lưu hồ sơ & Bắt đầu tư vấn")
                    }
                    .font(.inter(12, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(DS.brand))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(16)
    }
}

// MARK: - Editor Sheet (Used from Settings & Edit Button)

struct InvestorProfileEditorSheet: View {
    let initialProfile: InvestorProfile
    let onSave: (InvestorProfile) -> Void
    let onCancel: () -> Void

    @State private var ageText: String
    @State private var maritalStatus: String
    @State private var riskTolerance: RiskTolerance
    @State private var investmentStyle: InvestmentStyle
    @State private var investmentHorizon: InvestmentHorizon
    @State private var primaryGoal: String
    @State private var monthlySavingsText: String
    @State private var customNotes: String

    init(initialProfile: InvestorProfile, onSave: @escaping (InvestorProfile) -> Void, onCancel: @escaping () -> Void) {
        self.initialProfile = initialProfile
        self.onSave = onSave
        self.onCancel = onCancel
        _ageText = State(initialValue: "\(initialProfile.age)")
        _maritalStatus = State(initialValue: initialProfile.maritalStatus)
        _riskTolerance = State(initialValue: initialProfile.riskTolerance)
        _investmentStyle = State(initialValue: initialProfile.investmentStyle)
        _investmentHorizon = State(initialValue: initialProfile.investmentHorizon)
        _primaryGoal = State(initialValue: initialProfile.primaryGoal)
        _monthlySavingsText = State(initialValue: initialProfile.monthlyContribution.map { String(format: "%.0f", $0) } ?? "")
        _customNotes = State(initialValue: initialProfile.customNotes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Hồ sơ & Mục tiêu Nhà đầu tư")
                    .font(.inter(15, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(DS.ink)
                Spacer()
                Button("Đóng") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.inkTertiary)
                    .pointingHandCursor()
            }

            Divider().overlay(DS.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tuổi").font(DS.caption).foregroundStyle(DS.inkSecondary)
                            TextField("27", text: $ageText)
                                .textFieldStyle(.plain)
                                .font(DS.body)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(DS.cardAlt))
                                .frame(width: 70)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tình trạng gia đình").font(DS.caption).foregroundStyle(DS.inkSecondary)
                            TextField("Độc thân / Đã kết hôn…", text: $maritalStatus)
                                .textFieldStyle(.plain)
                                .font(DS.body)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(DS.cardAlt))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Khẩu vị rủi ro").font(DS.caption).foregroundStyle(DS.inkSecondary)
                        HStack(spacing: 8) {
                            ForEach(RiskTolerance.allCases) { risk in
                                Button {
                                    riskTolerance = risk
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(risk.shortLabel)
                                            .font(.inter(11, weight: riskTolerance == risk ? .bold : .medium, relativeTo: .caption))
                                            .foregroundStyle(riskTolerance == risk ? .white : DS.ink)
                                        Text(risk.description)
                                            .font(.inter(9.5, relativeTo: .caption2))
                                            .foregroundStyle(riskTolerance == risk ? .white.opacity(0.85) : DS.inkTertiary)
                                            .lineLimit(2)
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(riskTolerance == risk ? DS.brand : DS.cardAlt))
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                            }
                        }
                    }

                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Trường phái đầu tư").font(DS.caption).foregroundStyle(DS.inkSecondary)
                            Picker("", selection: $investmentStyle) {
                                ForEach(InvestmentStyle.allCases) { s in
                                    Text(s.label).tag(s)
                                }
                            }
                            .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Kỳ hạn đầu tư").font(DS.caption).foregroundStyle(DS.inkSecondary)
                            Picker("", selection: $investmentHorizon) {
                                ForEach(InvestmentHorizon.allCases) { h in
                                    Text(h.label).tag(h)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mục tiêu tài chính chính").font(DS.caption).foregroundStyle(DS.inkSecondary)
                        TextField("Mục tiêu mua nhà, nghỉ hưu...", text: $primaryGoal, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(DS.body)
                            .lineLimit(2...3)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(DS.cardAlt))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ghi chú / Ràng buộc thêm (Tùy chọn)").font(DS.caption).foregroundStyle(DS.inkSecondary)
                        TextField("V/d: Không dùng đòn bẩy margin, ưu tiên cổ phiếu công nghệ...", text: $customNotes, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(DS.body)
                            .lineLimit(1...2)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(DS.cardAlt))
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button("Hủy") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.inkSecondary)
                    .pointingHandCursor()

                Button("Lưu thay đổi") {
                    let age = Int(ageText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? initialProfile.age
                    let updated = InvestorProfile(
                        age: age,
                        maritalStatus: maritalStatus,
                        riskTolerance: riskTolerance,
                        investmentStyle: investmentStyle,
                        investmentHorizon: investmentHorizon,
                        primaryGoal: primaryGoal,
                        monthlyContribution: Double(monthlySavingsText.trimmingCharacters(in: .whitespacesAndNewlines)),
                        customNotes: customNotes,
                        updatedAt: Date()
                    )
                    onSave(updated)
                }
                .font(.inter(12, weight: .semibold, relativeTo: .body))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(DS.brand))
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 460)
    }
}

// MARK: - AIMarkdownRenderer

/// Full-featured Markdown and Table renderer for AI responses.
struct AIMarkdownRenderer: View {
    let content: String

    private enum MarkdownBlock {
        case header(level: Int, text: String)
        case paragraph(text: String)
        case bullet(text: String)
        case numbered(index: Int, text: String)
        case table(headers: [String], rows: [[String]])
        case divider
    }

    @MainActor private static var blocksCache: [Int: [MarkdownBlock]] = [:]
    @MainActor private static var attrCache: [String: AttributedString] = [:]

    @MainActor
    private static func cachedBlocks(for raw: String) -> [MarkdownBlock] {
        let key = raw.hashValue
        if let cached = blocksCache[key] {
            return cached
        }
        let parsed = parseBlocks(raw)
        if blocksCache.count > 100 {
            blocksCache.removeAll(keepingCapacity: true)
        }
        blocksCache[key] = parsed
        return parsed
    }

    @MainActor
    private static func cachedAttr(_ text: String) -> AttributedString {
        if let cached = attrCache[text] {
            return cached
        }
        let attr: AttributedString
        if let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            attr = parsed
        } else {
            attr = AttributedString(text)
        }
        if attrCache.count > 1000 {
            attrCache.removeAll(keepingCapacity: true)
        }
        attrCache[text] = attr
        return attr
    }

    var body: some View {
        let blocks = Self.cachedBlocks(for: content)
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
            Text(Self.cachedAttr(text))
                .font(.inter(level == 1 ? 14 : (level == 2 ? 13 : 12), weight: .semibold, relativeTo: .body))
                .foregroundStyle(DS.ink)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let text):
            Text(Self.cachedAttr(text))
                .font(DS.body)
                .foregroundStyle(DS.ink)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.inter(12, weight: .bold, relativeTo: .body))
                    .foregroundStyle(DS.brand)
                    .frame(width: 12, alignment: .center)
                Text(Self.cachedAttr(text))
                    .font(DS.body)
                    .foregroundStyle(DS.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .numbered(let index, let text):
            HStack(alignment: .top, spacing: 6) {
                Text("\(index).")
                    .font(.inter(11.5, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(Self.cachedAttr(text))
                    .font(DS.body)
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
                            Text(Self.cachedAttr(headers[c]))
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
                            Text(Self.cachedAttr(cellText))
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
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.vertical, 2)
    }

    private static func parseBlocks(_ raw: String) -> [MarkdownBlock] {
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
