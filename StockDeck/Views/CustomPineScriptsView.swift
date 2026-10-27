import SwiftUI
import UniformTypeIdentifiers
import AppKit

@MainActor
struct CustomPineScriptsView: View {
    @ObservedObject var library: PineScriptLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var source = ""
    @State private var error: String?
    @State private var importingFile = false
    @State private var savedMessage: String?
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Quản lý scripts").font(.title2.bold())
                Spacer()
                Button("Import .pine") { importing = true }.disabled(importingFile)
                Button("Mới") { selectedID = nil; name = "Script mới"; source = "//@version=6\nindicator(\"My indicator\", overlay=true)\nplot(close)"; error = nil; savedMessage = nil }
                Button("Đóng") { dismiss() }
            }.padding()
            Divider()
            HStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(library.scripts) { script in
                        HStack {
                            Button { selectedID = script.id } label: {
                                Label { Text(verbatim: script.name) } icon: { Image(systemName: selectedID == script.id ? "checkmark.circle.fill" : "doc.text") }
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Spacer()
                            Button(role: .destructive) { library.delete(script.id); if selectedID == script.id { selectedID = nil; name = ""; source = "" } } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                        }.tag(script.id)
                    }
                }.frame(width: 220)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Tên indicator", text: $name).textFieldStyle(.roundedBorder)
                    TextEditor(text: $source).font(.system(.body, design: .monospaced)).border(.quaternary)
                    HStack {
                        Button("Lưu") { save() }
                            .disabled(importingFile || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if importingFile { ProgressView().controlSize(.small) }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                    if let savedMessage { Text(savedMessage).foregroundStyle(.secondary).font(.caption) }
                    Text("Script đã lưu sẽ xuất hiện trong menu Scripts của Superchart. Chọn tên script trong menu để thêm vào chart.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(14)
            }
        }
        .frame(width: 900, height: 620)
        .onAppear { if selectedID == nil { selectedID = library.scripts.first?.id } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { response in
            do {
                guard let url = try response.get().first else { return }
                guard ["pine", "txt"].contains(url.pathExtension.lowercased()) else {
                    error = "Chỉ import file .pine hoặc .txt."; return
                }
                importingFile = true
                Task {
                    do {
                        let text = try await Task.detached {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 128_000 else {
                                throw CustomPineScriptRunner.RunnerError.message("Source tối đa 128 KB.")
                            }
                            return try String(contentsOf: url, encoding: .utf8)
                        }.value
                        selectedID = nil; name = url.deletingPathExtension().lastPathComponent; source = text
                        save()
                    } catch { self.error = error.localizedDescription }
                    importingFile = false
                }
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: selectedID) { _, value in
            guard let value, let script = library.scripts.first(where: { $0.id == value }) else { return }
            name = script.name; source = script.source; error = nil
        }
    }

    private func save() {
        guard source.utf8.count <= 128_000 else { error = "Source tối đa 128 KB."; return }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Source không được để trống."; return }
        let script = SavedPineScript(id: selectedID ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), source: source)
        library.save(script); selectedID = script.id; error = nil
        savedMessage = "Đã lưu vào thư viện."
    }
}

@MainActor
struct PineScriptStyleSettingsView: View {
    let title: String
    let initialPlots: [String: CustomPinePlot]
    let onApply: ([String: CustomPinePlot]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var plots: [String: CustomPinePlot] = [:]

    @State private var presentation: PineScriptStylePresentation?
    @State private var showAuxiliary = false
    @State private var expandedPalettes = Set<String>()

    private var preferredHeight: CGFloat {
        min(400, max(240, 120 + CGFloat(min(initialPlots.count, 4)) * 70))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.headline).lineLimit(2)
                    Text("Kiểu hiển thị").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let presentation {
                        ForEach(presentation.primary) { row in plotRow(row) }
                        if !presentation.auxiliary.isEmpty {
                            DisclosureGroup(isExpanded: $showAuxiliary) {
                                LazyVStack(spacing: 8) {
                                    ForEach(presentation.auxiliary) { row in plotRow(row) }
                                }.padding(.top, 10)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Đường mức phụ (\(presentation.auxiliary.count))").fontWeight(.medium)
                                    Text("Script không đặt tên; nhãn lấy theo giá trị đường mức.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.top, 6)
                        }
                        if presentation.primary.isEmpty && presentation.auxiliary.isEmpty {
                            Text("Script không có plot để tùy chỉnh.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ProgressView("Đang chuẩn bị cài đặt…").frame(maxWidth: .infinity, minHeight: 100)
                    }
                }.padding(12)
            }
            Divider()
            HStack {
                Button("Mặc định") { reset() }.disabled(presentation == nil)
                Spacer()
                Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { onApply(plots); dismiss() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(presentation == nil)
            }.padding(12)
        }
        .frame(width: 480, height: preferredHeight)
        .controlSize(.small)
        .background(.background)
        .task {
            guard presentation == nil else { return }
            let input = initialPlots
            let worker = Task.detached(priority: .userInitiated) { PineScriptStylePresentation(plots: input) }
            let prepared = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            plots = prepared.plots
            presentation = prepared
        }
    }

    @ViewBuilder private func plotRow(_ row: PineScriptStylePresentation.Row) -> some View {
        let isVisible = Binding(get: { plots[row.id]?.displayVisible != false }, set: { value in plots[row.id]?.displayVisible = value })
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(isOn: isVisible) { Text(verbatim: row.title).fontWeight(.medium) }.toggleStyle(.checkbox)
                Spacer()
                if row.style != "shape" { styleControls(row) }
            }
            if row.style == "shape" {
                HStack(spacing: 12) { styleControls(row); Spacer(minLength: 0) }.padding(.leading, 20)
            }
            if row.colors.count > 1 {
                DisclosureGroup(isExpanded: Binding(get: { expandedPalettes.contains(row.id) }, set: {
                    if $0 { expandedPalettes.insert(row.id) } else { expandedPalettes.remove(row.id) }
                })) {
                    LazyVStack(alignment: .leading, spacing: 8) { colorRows(row) }.padding(.top, 10)
                } label: {
                    Text("Màu theo giá trị (\(row.colors.count))").foregroundStyle(.secondary)
                }.padding(.leading, 24)
            } else { colorRows(row) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func colorRows(_ row: PineScriptStylePresentation.Row) -> some View {
        ForEach(row.colors, id: \.self) { original in
            HStack(spacing: 12) {
                Text("Màu")
                        .foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                colorPicker(for: row, original: original)
                let color = PineStyleColor(plots[row.id]?.displayColorOverrides?[original] ?? original)
                if let color {
                    Text("Độ trong suốt \(100 - color.opacityPercent)%")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(verbatim: original).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 24)
            .disabled(plots[row.id]?.displayVisible == false)
        }
    }

    @ViewBuilder private func styleControls(_ row: PineScriptStylePresentation.Row) -> some View {
        if row.style == "line" || row.style == "hline" {
            Picker("Độ dày", selection: Binding(get: { plots[row.id]?.displayLineWidth ?? row.lineWidth }, set: { plots[row.id]?.displayLineWidth = $0 })) {
                ForEach(1...4, id: \.self) { Text("\($0) px").tag($0) }
            }.frame(width: 134)
        } else if row.style == "shape" {
            Picker("Hình", selection: Binding(get: { plots[row.id]?.displayMarkerShape ?? row.marker }, set: { plots[row.id]?.displayMarkerShape = $0 })) {
                Text("▲").tag("triangleup"); Text("▼").tag("triangledown"); Text("●").tag("circle"); Text("■").tag("square")
            }.frame(width: 90)
            Picker("Vị trí", selection: Binding(get: { plots[row.id]?.displayPosition ?? row.position }, set: { plots[row.id]?.displayPosition = $0 })) {
                Text("Dưới nến").tag("belowbar"); Text("Trên nến").tag("abovebar")
            }.frame(width: 140)
        }
    }

    private func colorPicker(for row: PineScriptStylePresentation.Row, original: String) -> some View {
        ColorPicker("Màu \(row.title)", selection: Binding(get: {
            Color(nsColor: PineStyleColor(plots[row.id]?.displayColorOverrides?[original] ?? original)?.nativeColor ?? .clear)
        }, set: { color in
            guard let encoded = PineStyleColor(NSColor(color))?.cssString else { return }
            var overrides = plots[row.id]?.displayColorOverrides ?? [:]
            overrides[original] = encoded
            plots[row.id]?.displayColorOverrides = overrides
        }), supportsOpacity: true).labelsHidden().frame(width: 48)
            .help("Chọn màu và độ trong suốt")
            .disabled(PineStyleColor(original) == nil)
    }
    private func reset() {
        plots = (presentation?.plots ?? [:]).mapValues { plot in
            var value = plot
            value.displayVisible = nil; value.displayColorOverrides = nil
            value.displayMarkerShape = nil; value.displayPosition = nil; value.displayLineWidth = nil
            return value
        }
    }
}
