import UserNotifications
import CloudKit

/// Runs on the device when a CloudKit push arrives — even if iTeam itself is closed.
/// CloudKit only ever carries ciphertext; this extension decrypts the short preview with the
/// conversation key from the shared keychain and turns "New message" into "Rahul: Draft is ready".
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var best: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        best = content
        defer { contentHandler(content); handler = nil }

        if let n = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo), n.subscriptionID?.hasPrefix("roomdm-") == true {
            var i = content.userInfo; i["link"] = "iteam://open/rooms"; content.userInfo = i
            if AppGroup.mutedKinds.contains("rooms") {
                content.title = ""; content.body = ""; content.sound = nil; content.badge = nil; content.interruptionLevel = .passive
            }
            return
        }
        guard let note = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo) as? CKQueryNotification,
              let fields = note.recordFields,
              let conv = fields["conv"] as? String else { return }

        content.threadIdentifier = conv
        var info = content.userInfo
        info["conv"] = conv
        content.userInfo = info

        let muted = AppGroup.mutedConversations.contains(conv)
        if muted {
            content.sound = nil
            content.interruptionLevel = .passive
        } else {
            AppGroup.badge += 1
            content.badge = NSNumber(value: AppGroup.badge)
        }

        guard let hintString = fields["hint"] as? String,
              let blob = Data(base64Encoded: hintString),
              let parts = E2E.splitVersioned(blob),
              let key = E2E.conversationKey(conv: conv, version: parts.0),
              let plain = try? E2E.open(parts.1, key: key),
              let hint = try? JSONDecoder().decode(NotificationHint.self, from: plain) else {
            content.title = "iTeam"
            content.body = "New message"
            return
        }

        if let group = hint.t {
            content.title = group
            content.subtitle = hint.n
        } else {
            content.title = hint.n
        }
        content.body = AppGroup.showPreviews ? hint.b : "New message"
        if let link = hint.l { var i = content.userInfo; i["link"] = link; content.userInfo = i }
        // Types switched off in Settings → Notifications arrive silently, with nothing to show.
        if let k = hint.k, AppGroup.mutedKinds.contains(k) {
            content.title = ""; content.subtitle = ""; content.body = ""
            content.sound = nil; content.badge = nil
            content.interruptionLevel = .passive
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let best { handler(best) }
    }
}
