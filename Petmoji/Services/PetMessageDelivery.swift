import Foundation
import Intents
import UserNotifications

// MARK: - Delivers generated pet messages to widget + notifications

enum PetMessageDelivery {
    /// Writes the latest message to the widget snapshot, chat history, and optionally posts a local notification.
    /// Skip local notification when OneSignal already displayed a visible alert (avoids duplicates).
    @MainActor
    static func deliver(pet: Pet, message: PetMessage, postLocalNotification: Bool = true) {
        UserDefaults.standard.set(message.id.uuidString, forKey: PushNotificationHandler.lastDeliveredMessageIdKey)
        ChatHistoryStore.appendPetMessage(message)
        WidgetSnapshotSync.writeFromPet(pet, message: message)
        if postLocalNotification {
            postNotification(pet: pet, message: message)
        }
        NotificationCenter.default.post(
            name: .petMessageDelivered,
            object: nil,
            userInfo: ["pet_id": pet.id.uuidString]
        )
    }

    /// Refreshes the widget from the latest server message for the widget pet (app group id).
    @MainActor
    static func refreshWidgetFromServer() async {
        let defaults = UserDefaults(suiteName: WidgetSnapshotSync.appGroupSuiteName)
        let raw = defaults?.string(forKey: WidgetSnapshotSync.Keys.petId)
            ?? defaults?.string(forKey: WidgetSnapshotSync.Keys.legacyPetId)
            ?? UserDefaults.standard.string(forKey: MockUserSettings.Keys.widgetPetId)
        guard let raw, let petId = UUID(uuidString: raw) else { return }

        await ChatHistoryStore.mergeServerMessages(for: petId)

        guard let pet = try? await SupabaseService.shared.fetchPet(by: petId),
              let message = try? await SupabaseService.shared.fetchLatestMessage(for: petId) else {
            WidgetReloader.reload()
            return
        }
        ChatHistoryStore.appendPetMessage(message)
        WidgetSnapshotSync.writeFromPet(pet, message: message)
    }

    private static func postNotification(pet: Pet, message: PetMessage) {
        Task {
            let content = await PetNotificationBuilder.makeContent(pet: pet, message: message)
            let request = UNNotificationRequest(
                identifier: "pet_message_\(message.id.uuidString)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - Communication notification (pet sprite avatar on the left)

private enum PetNotificationBuilder {
    static func makeContent(pet: Pet, message: PetMessage) async -> UNNotificationContent {
        var content = UNMutableNotificationContent()
        content.title = pet.name
        content.body = message.content
        content.sound = .default
        content.userInfo = [
            "pet_id": message.petId.uuidString,
            "trigger": message.triggerType.rawValue,
        ]

        guard let spriteData = await downloadSpriteData(pet: pet, expression: message.expression) else {
            return content
        }

        let avatar = INImage(imageData: spriteData)
        let sender = INPerson(
            personHandle: INPersonHandle(value: pet.id.uuidString, type: .unknown),
            nameComponents: nil,
            displayName: pet.name,
            image: avatar,
            contactIdentifier: nil,
            customIdentifier: pet.id.uuidString
        )

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: message.content,
            speakableGroupName: nil,
            conversationIdentifier: pet.id.uuidString,
            serviceName: "Petmoji",
            sender: sender,
            attachments: nil
        )
        intent.setImage(avatar, forParameterNamed: \.sender)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        await donate(interaction)

        if let communicationContent = try? content.updating(from: intent),
           var mutable = communicationContent.mutableCopy() as? UNMutableNotificationContent {
            mutable.userInfo = content.userInfo
            return mutable
        }

        return content
    }

    private static func donate(_ interaction: INInteraction) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            interaction.donate { _ in continuation.resume() }
        }
    }

    private static func downloadSpriteData(pet: Pet, expression: PetExpression) async -> Data? {
        guard let urlString = pet.expressions[expression] ?? pet.expressions[.happy],
              !urlString.isEmpty else { return nil }

        do {
            return try await SupabaseService.shared.downloadSprite(from: urlString)
        } catch {
            print("[PetNotificationBuilder] sprite download failed: \(error)")
            return nil
        }
    }
}

#if DEBUG
extension PetMessageDelivery {
    enum TestMessageError: LocalizedError {
        case noPet
        case unsupportedEvent(String)

        var errorDescription: String? {
            switch self {
            case .noPet:
                return "No pet loaded. Sign in and open the app with a pet first."
            case .unsupportedEvent(let event):
                return "Unknown test event \"\(event)\". Use: \(supportedLocationEvents.joined(separator: ", "))."
            }
        }
    }

    static let supportedLocationEvents = ["left_home", "returned", "been_gone_2h", "been_gone_6h"]

    @MainActor
    static func sendTestMessage(appState: AppState, event: String = "been_gone_2h") async throws -> String {
        guard supportedLocationEvents.contains(event) else {
            throw TestMessageError.unsupportedEvent(event)
        }
        guard let pet = appState.widgetPet ?? appState.currentPet ?? appState.pets.first else {
            throw TestMessageError.noPet
        }
        _ = await MessageScheduler.shared.requestNotificationPermission()
        let message = try await SupabaseService.shared.reportLocationEvent(petId: pet.id, event: event)
        guard let updatedPet = try await SupabaseService.shared.fetchPet(by: pet.id) else {
            throw TestMessageError.noPet
        }
        deliver(pet: updatedPet, message: message)
        return message.content
    }
}
#endif
