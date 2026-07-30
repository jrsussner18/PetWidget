import UIKit

// MARK: - Handles remote push → fetch message → update chat/widget (+ local notif if silent)

enum PushNotificationHandler {
    static let lastDeliveredMessageIdKey = "last_delivered_message_id"

    @MainActor
    static func handle(userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let (petId, messageId) = PushNotificationService.parsePetMessagePayload(userInfo) else {
            await PetMessageDelivery.refreshWidgetFromServer()
            return .noData
        }

        if UserDefaults.standard.string(forKey: lastDeliveredMessageIdKey) == messageId.uuidString {
            await PetMessageDelivery.refreshWidgetFromServer()
            return .noData
        }

        guard let pet = try? await SupabaseService.shared.fetchPet(by: petId),
              let message = try? await SupabaseService.shared.fetchMessage(by: messageId) else {
            await PetMessageDelivery.refreshWidgetFromServer()
            return .failed
        }

        // Visible OneSignal pushes already show an alert — only post a local (avatar) notif for silent wakes.
        let postLocal = !remotePushHasVisibleAlert(userInfo)
        PetMessageDelivery.deliver(pet: pet, message: message, postLocalNotification: postLocal)
        // Belt-and-suspenders: ensure WidgetKit is asked even if signature dedupe skipped a reload.
        WidgetReloader.reload()
        return .newData
    }

    private static func remotePushHasVisibleAlert(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let aps = userInfo["aps"] as? [String: Any] else { return false }
        if aps["alert"] != nil { return true }
        // OneSignal sometimes surfaces title/body at the top level
        if userInfo["title"] != nil || userInfo["body"] != nil { return true }
        return false
    }
}
