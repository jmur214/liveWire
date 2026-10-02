import SwiftUI
import UIKit
import UserNotifications

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

/// UIKit delegate: APNs device token (PushRegistrar picks it up) and notification taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var onPushToken: ((String) -> Void)?
    static var onPushTokenError: ((Error) -> Void)?
    static var onOpenIncident: ((Int) -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Show alert pushes as banners even while the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Tapping a push opens that incident's Detail.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let id = (info["incident_id"] as? Int) ?? (info["incident_id"] as? NSNumber)?.intValue
            ?? Int((info["incident_id"] as? String) ?? "") {
            AppDelegate.onOpenIncident?(id)
        }
        completionHandler()
    }

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
