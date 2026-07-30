import Foundation
import RevenueCat

enum SubscriptionConfig {
    static let entitlementID = "pro"
    static let monthlyProductID = "petmoji_pro_monthly"
    static let lifetimeProductID = "petmoji_pro_lifetime"
    static let monthlyPackageID = "$rc_monthly"
    static let lifetimePackageID = "$rc_lifetime"

    /// Kill switch: when `false`, skip onboarding/root paywall and treat the user as Pro.
    static let isPaywallEnabled = false

    /// Public RevenueCat Apple SDK key (`appl_…`). Prefer build setting / env over hardcoding.
    static var apiKey: String {
        if let env = ProcessInfo.processInfo.environment["REVENUECAT_API_KEY"], !env.isEmpty {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String,
           !plist.isEmpty,
           !plist.hasPrefix("$(") {
            return plist
        }
        return "appl_KNkxOvHKIUCwPiPynHTmmapKVzz"
    }
}

enum SubscriptionError: LocalizedError {
    case missingPackage
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .missingPackage:
            return "That plan isn’t available right now. Try again in a moment."
        case .notConfigured:
            return "Subscriptions aren’t configured yet."
        }
    }
}

@MainActor
enum SubscriptionService {
    private static var didConfigure = false

    static func configure() {
        guard !didConfigure else { return }
        let key = SubscriptionConfig.apiKey
        guard !key.isEmpty else {
            print("[SubscriptionService] REVENUECAT_API_KEY missing — purchases disabled")
            return
        }
        #if DEBUG
        Purchases.logLevel = .debug
        #endif
        Purchases.configure(withAPIKey: key)
        didConfigure = true
    }

    static func logIn(userId: UUID) async {
        configure()
        guard didConfigure else { return }
        do {
            _ = try await Purchases.shared.logIn(userId.uuidString)
        } catch {
            print("[SubscriptionService] logIn failed: \(error.localizedDescription)")
        }
    }

    static func logOut() async {
        guard didConfigure else { return }
        do {
            _ = try await Purchases.shared.logOut()
        } catch {
            print("[SubscriptionService] logOut failed: \(error.localizedDescription)")
        }
    }

    static func isPro(from info: CustomerInfo) -> Bool {
        info.entitlements[SubscriptionConfig.entitlementID]?.isActive == true
    }

    static func refreshCustomerInfo() async throws -> CustomerInfo {
        configure()
        guard didConfigure else { throw SubscriptionError.notConfigured }
        return try await Purchases.shared.customerInfo()
    }

    static func fetchOfferings() async throws -> Offerings {
        configure()
        guard didConfigure else { throw SubscriptionError.notConfigured }
        return try await Purchases.shared.offerings()
    }

    static func package(for plan: PaywallPlan, offerings: Offerings) -> Package? {
        let offering = offerings.current
        switch plan {
        case .lifetime:
            return offering?.package(identifier: SubscriptionConfig.lifetimePackageID)
                ?? offering?.lifetime
                ?? offering?.availablePackages.first(where: {
                    $0.storeProduct.productIdentifier == SubscriptionConfig.lifetimeProductID
                })
        case .monthly:
            return offering?.package(identifier: SubscriptionConfig.monthlyPackageID)
                ?? offering?.monthly
                ?? offering?.availablePackages.first(where: {
                    $0.storeProduct.productIdentifier == SubscriptionConfig.monthlyProductID
                })
        }
    }

    static func purchase(package: Package) async throws -> CustomerInfo {
        configure()
        guard didConfigure else { throw SubscriptionError.notConfigured }
        let result = try await Purchases.shared.purchase(package: package)
        return result.customerInfo
    }

    static func restorePurchases() async throws -> CustomerInfo {
        configure()
        guard didConfigure else { throw SubscriptionError.notConfigured }
        return try await Purchases.shared.restorePurchases()
    }

    static func isUserCancelled(_ error: Error) -> Bool {
        if let code = error as? ErrorCode {
            return code == .purchaseCancelledError
        }
        let nsError = error as NSError
        return nsError.code == ErrorCode.purchaseCancelledError.rawValue
    }
}
