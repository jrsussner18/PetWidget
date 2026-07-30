import Foundation

// MARK: - Settings section (user vs pet)

enum SettingsPersona: String, CaseIterable, Identifiable {
    case pet = "pet"
    case user = "user"

    var id: String { rawValue }

    var segmentTitle: String {
        switch self {
        case .user: return "User"
        case .pet: return "Pet"
        }
    }

    /// Maps legacy `mock_user` persona from older builds.
    init(storedRawValue: String) {
        if storedRawValue == "mock_user" {
            self = .user
        } else if let value = SettingsPersona(rawValue: storedRawValue) {
            self = value
        } else {
            self = .pet
        }
    }
}

// MARK: - UserDefaults keys + helpers

enum MockUserSettings {
    enum Keys {
        static let persona = "settings_persona"
        static let displayName = "mock_user_display_name"
        static let email = "mock_user_email"
        static let phone = "mock_user_phone"
        static let signupCompleted = "signup_completed"
        static let onboardingCompleted = "onboarding_completed"
        static let hasSeenWelcome = "has_seen_welcome"
        static let widgetPetId = "widget_pet_id"
        /// Leave-home geofence monitoring (default off until onboarding opt-in).
        static let locationTrackingEnabled = "location_tracking_enabled"
        /// When true, uses dark “widget glass” styling; when false, classic sage + light chrome.
        static let darkMode = "mock_user_dark_mode"
    }

    /// Legacy key from the old appearance picker; read once for migration.
    static let legacyVisualStyleKey = "app_visual_style"

    static func logVerbose(_ message: @autoclosure () -> String) {
        // Verbose logging disabled (no settings toggle).
    }

    /// Wipes on-device prefs after sign-out, account deletion, or invalid session restore.
    static func clearAllPersistedState() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Keys.persona)
        d.removeObject(forKey: Keys.displayName)
        d.removeObject(forKey: Keys.email)
        d.removeObject(forKey: Keys.phone)
        d.removeObject(forKey: Keys.signupCompleted)
        d.removeObject(forKey: Keys.onboardingCompleted)
        d.removeObject(forKey: Keys.hasSeenWelcome)
        d.removeObject(forKey: Keys.widgetPetId)
        d.removeObject(forKey: Keys.locationTrackingEnabled)
        d.removeObject(forKey: Keys.darkMode)
        d.removeObject(forKey: legacyVisualStyleKey)
        d.removeObject(forKey: "notifications_enabled")
        d.removeObject(forKey: "petHomeExpandedPetIDs")
        d.removeObject(forKey: "last_delivered_message_id")
    }
}
