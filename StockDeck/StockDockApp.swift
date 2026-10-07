import SwiftUI

@main
struct StockDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var storageService = StorageService.shared
    @ObservedObject private var stockService = StockService.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(storageService)
                .environmentObject(stockService)
                .environmentObject(appDelegate.updaterViewModel)
                .frame(minWidth: 480, idealWidth: 520, maxWidth: 650, minHeight: 480, idealHeight: 620, maxHeight: 850)
                .background(DS.ground)
                .tint(DS.brand)
                .preferredColorScheme(storageService.appearanceMode.colorScheme)
                .environment(\.locale, Locale(identifier: storageService.appLanguage))
        }
    }
}
