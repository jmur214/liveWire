import SwiftUI
import UIKit

@main
struct LiveWireApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(settings: Settings())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance == .dark ? .dark : nil)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HomeView()
            .tint(Theme.police)
            .onAppear { model.start() }
            .onChange(of: model.settings.serverURL) { model.reconnect() }
            .onChange(of: model.settings.apiToken) { model.reconnect() }
            .onChange(of: model.settings.cityId) { model.reconnect() }
    }
}

/// UIKit delegate: only needed for the APNs device token (PushRegistrar picks it up).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var onPushToken: ((String) -> Void)?
    static var onPushTokenError: ((Error) -> Void)?

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppDelegate.onPushToken?(hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppDelegate.onPushTokenError?(error)
    }
}
