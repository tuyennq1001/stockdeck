#if os(iOS)
import SwiftUI

@main
struct StockDeckiOSApp: App {
    @UIApplicationDelegateAdaptor(iOSAppDelegate.self) var appDelegate
    @StateObject private var stockService = StockService.shared
    @StateObject private var storageService = StorageService.shared
    @StateObject private var updaterViewModel = UpdaterViewModel()

    var body: some Scene {
        WindowGroup {
            iOSMainTabView()
                .environmentObject(stockService)
                .environmentObject(storageService)
                .environmentObject(updaterViewModel)
                .tint(DS.brand)
                .preferredColorScheme(storageService.appearanceMode.colorScheme)
                .environment(\.locale, Locale(identifier: storageService.appLanguage))
        }
    }
}
#endif
