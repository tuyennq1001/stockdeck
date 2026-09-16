import SwiftUI
import AppKit

struct ShortcutRecorderView: View {
    @Binding var shortcut: MenuBarShortcut?
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                HStack(spacing: 6) {
                    if isRecording {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.brand)
                        Text("Type shortcut…")
                            .font(.inter(11.5, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.brand)
                    } else if let shortcut = shortcut {
                        Image(systemName: "keyboard")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.inkSecondary)
                        Text(shortcut.displayString)
                            .font(.inter(11.5, weight: .semibold, relativeTo: .caption).monospacedDigit())
                            .foregroundStyle(DS.ink)
                    } else {
                        Image(systemName: "keyboard")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.inkTertiary)
                        Text("Record shortcut…")
                            .font(.inter(11.5, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? DS.brand.opacity(0.12) : DS.cardAlt)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? DS.brand : DS.hairline, lineWidth: isRecording ? 1.5 : 1)
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if shortcut != nil && !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.inkTertiary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Clear shortcut")
            }

            if !isRecording {
                Menu {
                    Button("⌥ Space (Option + Space)") {
                        shortcut = .presetOptionSpace
                    }
                    Button("⌥ S (Option + S)") {
                        shortcut = .presetOptionS
                    }
                    Button("⌘ ⇧ S (Command + Shift + S)") {
                        shortcut = .presetCmdShiftS
                    }
                    Button("⌃ ⌥ S (Control + Option + S)") {
                        shortcut = .presetControlOptionS
                    }
                    if shortcut != nil {
                        Divider()
                        Button("Clear shortcut", role: .destructive) {
                            shortcut = nil
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.inkSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18, height: 18)
                .pointingHandCursor()
                .help("Presets")
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Escape cancels recording
            if event.keyCode == 53 {
                Task { @MainActor in
                    self.stopRecording()
                }
                return nil
            }
            // Delete / Backspace clears shortcut
            if event.keyCode == 51 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                Task { @MainActor in
                    self.shortcut = nil
                    self.stopRecording()
                }
                return nil
            }

            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isFunctionKey = (event.keyCode >= 96 && event.keyCode <= 101) ||
                                (event.keyCode >= 103 && event.keyCode <= 122)

            if !flags.isEmpty || isFunctionKey {
                let captured = MenuBarShortcut(keyCode: event.keyCode, modifierFlags: flags)
                Task { @MainActor in
                    self.shortcut = captured
                    self.stopRecording()
                }
                return nil
            }

            return event
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
    }
}
