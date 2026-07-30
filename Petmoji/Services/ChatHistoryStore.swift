import Foundation

extension Notification.Name {
    static let petMessageDelivered = Notification.Name("petMessageDelivered")
}

struct ChatHistoryStore {
    private static let keyPrefix = "chat_history_"

    static func loadHistory(for petId: UUID) -> [ChatMessage] {
        let key = historyKey(for: petId)

        guard let data = UserDefaults.standard.data(forKey: key) else {
            return []
        }

        do {
            return try JSONDecoder().decode([ChatMessage].self, from: data)
        } catch {
            UserDefaults.standard.removeObject(forKey: key)
            return []
        }
    }

    static func saveHistory(_ messages: [ChatMessage], for petId: UUID) {
        let key = historyKey(for: petId)

        guard !messages.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }

        do {
            let data = try JSONEncoder().encode(messages)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            assertionFailure("Failed to save chat history for pet \(petId): \(error)")
        }
    }

    static func clearHistory(for petId: UUID) {
        UserDefaults.standard.removeObject(forKey: historyKey(for: petId))
    }

    static func clearAllHistories() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func chatMessage(from message: PetMessage) -> ChatMessage {
        ChatMessage(
            id: message.id,
            content: message.content,
            isFromPet: true,
            expression: message.expression,
            timestamp: message.sentAt ?? message.scheduledFor
        )
    }

    /// Appends a server-generated pet message so it survives app launch and appears in chat.
    static func appendPetMessage(_ message: PetMessage) {
        var history = loadHistory(for: message.petId)
        let chat = chatMessage(from: message)
        guard !history.contains(where: { $0.id == chat.id }) else { return }
        history.append(chat)
        history.sort { $0.timestamp < $1.timestamp }
        saveHistory(history, for: message.petId)
    }

    /// Pulls recent rows from Supabase into local chat history (scheduled, location, etc.).
    static func mergeServerMessages(for petId: UUID, limit: Int = 30) async {
        guard let recent = try? await SupabaseService.shared.fetchRecentMessages(for: petId, limit: limit) else {
            return
        }
        var history = loadHistory(for: petId)
        let existingIDs = Set(history.map(\.id))

        for message in recent.reversed() {
            let chat = chatMessage(from: message)
            guard !existingIDs.contains(chat.id) else { continue }
            history.append(chat)
        }

        history.sort { $0.timestamp < $1.timestamp }
        saveHistory(history, for: petId)
    }

    private static func historyKey(for petId: UUID) -> String {
        keyPrefix + petId.uuidString
    }
}
