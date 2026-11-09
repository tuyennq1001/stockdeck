import SwiftUI

/// Issue #11: user-facing appearance control. The app defaults to the
/// Obsidian Slate Financial Terminal theme (Dark); users can switch back to
/// the classic Private Banking theme (Light) or follow System. Persisted as
/// its `rawValue` in StorageService.
enum AppearanceMode: String, CaseIterable {
    case dark
    case light
    case system

    /// Shipped default: Obsidian Slate Financial Terminal.
    static let `default`: AppearanceMode = .dark

    /// SwiftUI scheme to apply via `.preferredColorScheme`. `nil` = follow the OS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Settings label.
    var label: String {
        switch self {
        case .dark: return "Obsidian Slate (Terminal)"
        case .light: return "Private Banking (Classic)"
        case .system: return "System"
        }
    }
}
