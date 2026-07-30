import Foundation
import PostHog
import RevenueCat

// MARK: - Config

enum AnalyticsConfig {
    /// Public PostHog project API key. Prefer build setting / env over hardcoding.
    static var apiKey: String {
        if let env = ProcessInfo.processInfo.environment["POSTHOG_API_KEY"], !env.isEmpty {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String,
           !plist.isEmpty,
           !plist.hasPrefix("$(") {
            return plist
        }
        return ""
    }

    static var host: String {
        if let env = ProcessInfo.processInfo.environment["POSTHOG_HOST"], !env.isEmpty {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_HOST") as? String,
           !plist.isEmpty,
           !plist.hasPrefix("$(") {
            return plist
        }
        return "https://us.i.posthog.com"
    }
}

// MARK: - Events

enum AnalyticsEvent {
    static let signUpCompleted = "sign_up_completed"
    static let signInCompleted = "sign_in_completed"
    static let signOut = "sign_out"
    static let onboardingCompleted = "onboarding_completed"
    static let petCreated = "pet_created"
    static let petDeleted = "pet_deleted"
    static let spritesGenerated = "sprites_generated"
    static let chatOpened = "chat_opened"
    static let chatMessageSent = "chat_message_sent"
    static let chatReplyReceived = "chat_reply_received"
    static let paywallViewed = "paywall_viewed"
    static let subscriptionPurchased = "subscription_purchased"
    static let subscriptionRestored = "subscription_restored"
    static let trialStarted = "trial_started"
    static let trialConverted = "trial_converted"
    static let locationTrackingEnabled = "location_tracking_enabled"
}

// MARK: - Service

@MainActor
enum AnalyticsService {
    private static var didConfigure = false
    private static let trialPeriodKey = "analytics_pro_period_was_trial"

    static func configure() {
        guard !didConfigure else { return }
        let key = AnalyticsConfig.apiKey
        guard !key.isEmpty else {
            print("[AnalyticsService] POSTHOG_API_KEY missing — analytics disabled")
            return
        }
        let config = PostHogConfig(projectToken: key, host: AnalyticsConfig.host)
        config.sessionReplay = false
        PostHogSDK.shared.setup(config)
        didConfigure = true
    }

    static func identify(userId: UUID, email: String? = nil, name: String? = nil) {
        guard didConfigure else { return }
        var properties: [String: Any] = [:]
        if let email, !email.isEmpty { properties["email"] = email }
        if let name, !name.isEmpty { properties["name"] = name }
        if properties.isEmpty {
            PostHogSDK.shared.identify(userId.uuidString)
        } else {
            PostHogSDK.shared.identify(userId.uuidString, userProperties: properties)
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: trialPeriodKey)
        guard didConfigure else { return }
        PostHogSDK.shared.reset()
    }

    static func capture(_ event: String, properties: [String: Any] = [:]) {
        guard didConfigure else { return }
        if properties.isEmpty {
            PostHogSDK.shared.capture(event)
        } else {
            PostHogSDK.shared.capture(event, properties: properties)
        }
    }

    /// Tracks trial → paid transitions from RevenueCat customer info.
    static func trackSubscriptionPeriod(from info: CustomerInfo, plan: String? = nil) {
        guard let entitlement = info.entitlements[SubscriptionConfig.entitlementID],
              entitlement.isActive else { return }

        let isTrial = entitlement.periodType == .trial
        let wasTrial = UserDefaults.standard.bool(forKey: trialPeriodKey)
        var props: [String: Any] = [:]
        if let plan { props["plan"] = plan }
        props["product_id"] = entitlement.productIdentifier

        if isTrial && !wasTrial {
            capture(AnalyticsEvent.trialStarted, properties: props)
            UserDefaults.standard.set(true, forKey: trialPeriodKey)
        } else if !isTrial && wasTrial {
            capture(AnalyticsEvent.trialConverted, properties: props)
            UserDefaults.standard.set(false, forKey: trialPeriodKey)
        } else if isTrial {
            UserDefaults.standard.set(true, forKey: trialPeriodKey)
        }
    }
}
