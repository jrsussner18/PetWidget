import Foundation

// MARK: - App group keys (mirrors PetWidgetProvider)

enum WidgetSnapshotSync {
    static let appGroupSuiteName = "group.com.petmoji.app"

    enum Keys {
        static let petId = "widget_pet_id"
        /// Legacy key used by location / been-gone schedulers — keep in sync so refresh can find the pet.
        static let legacyPetId = "pet_id"
        static let petName = "pet_name"
        static let message = "widget_message"
        static let expression = "widget_expression"
        static let spriteURL = "widget_sprite_url"
        /// URL the on-disk sprite cache was downloaded for.
        static let spriteCacheURL = "widget_sprite_cache_url"
        /// Signature of the last-written snapshot, used to skip redundant widget reloads.
        static let snapshotSignature = "widget_snapshot_signature"
    }

    static var spriteCacheFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupSuiteName)?
            .appendingPathComponent("widget_latest_sprite.img", isDirectory: false)
    }

    @MainActor
    static func clear() {
        let defaults = UserDefaults(suiteName: appGroupSuiteName)
        defaults?.removeObject(forKey: Keys.petId)
        defaults?.removeObject(forKey: Keys.legacyPetId)
        defaults?.removeObject(forKey: Keys.petName)
        defaults?.removeObject(forKey: Keys.message)
        defaults?.removeObject(forKey: Keys.expression)
        defaults?.removeObject(forKey: Keys.spriteURL)
        defaults?.removeObject(forKey: Keys.spriteCacheURL)
        defaults?.removeObject(forKey: Keys.snapshotSignature)
        if let spriteCacheFileURL {
            try? FileManager.default.removeItem(at: spriteCacheFileURL)
        }
        WidgetReloader.reload()
    }

    @MainActor
    static func writeFromPet(_ pet: Pet, message: PetMessage) {
        let spriteURL = pet.expressions[message.expression] ?? pet.expressions[.happy]
        let defaults = UserDefaults(suiteName: appGroupSuiteName)

        // Include message id so two messages with identical text/expression still trigger a reload.
        let signature = [
            message.id.uuidString,
            pet.id.uuidString,
            pet.name,
            message.content,
            message.expression.rawValue,
            spriteURL ?? ""
        ].joined(separator: "|")
        let didChange = defaults?.string(forKey: Keys.snapshotSignature) != signature

        // Write shared app-group data first, then reload, so the widget process reads
        // the new snapshot when WidgetKit re-requests the timeline.
        defaults?.set(pet.id.uuidString, forKey: Keys.petId)
        defaults?.set(pet.id.uuidString, forKey: Keys.legacyPetId)
        defaults?.set(pet.name, forKey: Keys.petName)
        defaults?.set(message.content, forKey: Keys.message)
        defaults?.set(message.expression.rawValue, forKey: Keys.expression)
        defaults?.set(spriteURL, forKey: Keys.spriteURL)
        defaults?.set(signature, forKey: Keys.snapshotSignature)

        guard didChange else { return }

        // Prefetch sprite into the app group so the widget extension can render without
        // its own network call (widget network is flaky / often blocked).
        Task {
            await prefetchSprite(to: spriteURL)
            WidgetReloader.reload()
        }
        // Also request an immediate reload with text; sprite fills in on the second reload.
        WidgetReloader.reload()
    }

    /// Downloads the sprite into the shared container when the URL changed.
    nonisolated static func prefetchSprite(to urlString: String?) async {
        guard let urlString, let url = URL(string: urlString) else { return }
        let defaults = UserDefaults(suiteName: appGroupSuiteName)
        if defaults?.string(forKey: Keys.spriteCacheURL) == urlString,
           let fileURL = spriteCacheFileURL,
           FileManager.default.fileExists(atPath: fileURL.path) {
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              !data.isEmpty,
              let fileURL = spriteCacheFileURL else { return }
        try? data.write(to: fileURL, options: .atomic)
        defaults?.set(urlString, forKey: Keys.spriteCacheURL)
    }

    nonisolated static func cachedSpriteData(matching urlString: String?) -> Data? {
        guard let urlString else { return nil }
        let defaults = UserDefaults(suiteName: appGroupSuiteName)
        guard defaults?.string(forKey: Keys.spriteCacheURL) == urlString,
              let fileURL = spriteCacheFileURL,
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else { return nil }
        return data
    }
}
