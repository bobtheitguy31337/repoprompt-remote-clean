import Foundation
import UIKit
import UserNotifications

final class RemoteNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let deviceTokenNotification = Notification.Name("RepoPromptRemote.deviceToken")
    static let receivedNotification = Notification.Name("RepoPromptRemote.receivedNotification")
    static let registrationErrorNotification = Notification.Name("RepoPromptRemote.registrationError")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: Self.deviceTokenNotification, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(
            name: Self.registrationErrorNotification,
            object: error.localizedDescription
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        NotificationCenter.default.post(
            name: Self.receivedNotification,
            object: notification.request.content.userInfo
        )
        return [.banner, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        NotificationCenter.default.post(
            name: Self.receivedNotification,
            object: response.notification.request.content.userInfo
        )
    }

    static func requestAuthorizationAndRegister() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { return false }
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return true
        } catch {
            return false
        }
    }
}
