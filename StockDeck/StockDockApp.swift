#if os(macOS)
import SwiftUI

@main
struct StockDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
#endif
