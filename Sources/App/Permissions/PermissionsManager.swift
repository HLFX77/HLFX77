import Foundation
import LANScreenShared
import Network
import UIKit
import UserNotifications

/// Manages iOS Local Network permission discovery and interactive UNUserNotificationCenter prompts.
@MainActor
final class PermissionsManager: NSObject, ObservableObject {
    enum NotificationIDs {
        static let connectionCategory = "LAN_SCREEN_CONNECTION_REQUEST"
        static let acceptAction = "LAN_SCREEN_ACCEPT_ACTION"
        static let declineAction = "LAN_SCREEN_DECLINE_ACTION"
    }

    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var localNetworkCheckTriggered: Bool = false

    var onNotificationAction: ((_ sessionId: String, _ accepted: Bool) -> Void)?

    private var probeBrowser: NWBrowser?

    override init() {
        super.init()
        configureNotificationCategories()
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationAuthorizationStatus = settings.authorizationStatus
            }
        }
    }

    func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationAuthorizationStatus = settings.authorizationStatus
            }
            guard settings.authorizationStatus == .notDetermined else { return }

            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async {
                    self?.notificationAuthorizationStatus = granted ? .authorized : .denied
                }
            }
        }
    }

    /// Triggers the iOS Local Network privacy permission dialog early if not yet prompted.
    func triggerLocalNetworkPermissionCheck() {
        guard !localNetworkCheckTriggered else { return }
        localNetworkCheckTriggered = true

        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: AppConstants.bonjourServiceType, domain: "local."), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.probeBrowser?.cancel()
                    self?.probeBrowser = nil
                }
            }
        }
        browser.start(queue: DispatchQueue.global(qos: .utility))
        self.probeBrowser = browser
    }

    func postIncomingConnectionNotification(request: IncomingConnectionRequest) {
        let content = UNMutableNotificationContent()
        content.title = "Demande de connexion LAN SCREEN"
        content.subtitle = "\(request.viewerName) (\(request.viewerIP))"
        content.body = "Souhaitez-vous partager votre écran ? Code : \(request.verificationCode)"
        content.sound = .default
        content.categoryIdentifier = NotificationIDs.connectionCategory
        content.userInfo = ["sessionId": request.sessionId]

        let notificationRequest = UNNotificationRequest(
            identifier: "connection-\(request.sessionId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(notificationRequest)
    }

    func clearConnectionNotification(sessionId: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["connection-\(sessionId)"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["connection-\(sessionId)"])
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func configureNotificationCategories() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let acceptAction = UNNotificationAction(
            identifier: NotificationIDs.acceptAction,
            title: "ACCEPTER",
            options: [.foreground]
        )
        let declineAction = UNNotificationAction(
            identifier: NotificationIDs.declineAction,
            title: "REFUSER",
            options: [.destructive]
        )

        let category = UNNotificationCategory(
            identifier: NotificationIDs.connectionCategory,
            actions: [acceptAction, declineAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }
}

extension PermissionsManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["sessionId"] as? String

        Task { @MainActor in
            if let sessionId {
                switch response.actionIdentifier {
                case NotificationIDs.acceptAction:
                    self.onNotificationAction?(sessionId, true)
                case NotificationIDs.declineAction, UNNotificationDismissActionIdentifier:
                    self.onNotificationAction?(sessionId, false)
                default:
                    break
                }
            }
            completionHandler()
        }
    }
}
