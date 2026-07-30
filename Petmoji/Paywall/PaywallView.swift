import RevenueCat
import SwiftUI

// MARK: - Plan

enum PaywallPlan: String, CaseIterable, Identifiable {
    case lifetime
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly: return "Monthly"
        case .lifetime: return "Lifetime"
        }
    }

    var fallbackPriceLabel: String {
        switch self {
        case .monthly: return "$4.99/mo"
        case .lifetime: return "$29.99"
        }
    }

    var compareAtPrice: String? {
        switch self {
        case .monthly: return nil
        case .lifetime: return "$39.99"
        }
    }

    var subtitle: String? {
        switch self {
        case .monthly: return "Includes 3-day free trial"
        case .lifetime: return nil
        }
    }

    var badge: String? {
        switch self {
        case .monthly: return nil
        case .lifetime: return "Best Value"
        }
    }
}

private struct PaywallBenefit: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

// MARK: - Paywall

struct PaywallView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.petmojiPalette) private var palette
    @Environment(\.openURL) private var openURL

    /// Called after a successful purchase or restore that unlocks Pro.
    var onUnlocked: () -> Void
    /// When false, stay on the paywall even if the user already has Pro (DEBUG previews).
    var allowsAutoUnlock: Bool = true

    @State private var selectedPlan: PaywallPlan = .lifetime
    @State private var offerings: Offerings?
    @State private var isLoadingOfferings = true
    @State private var isPurchasing = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let benefits: [PaywallBenefit] = [
        PaywallBenefit(
            icon: "square.grid.2x2.fill",
            title: "Home screen widget",
            detail: "Keep your petmoji on your lock & home screens"
        ),
        PaywallBenefit(
            icon: "message.fill",
            title: "Unlimited pet messages",
            detail: "Hear from your pet whenever you need a nudge"
        ),
        PaywallBenefit(
            icon: "bell.badge.fill",
            title: "Smart check-ins",
            detail: "Location-aware nudges when you leave home"
        ),
        PaywallBenefit(
            icon: "sparkles",
            title: "All moods & expressions",
            detail: "Unlock every face your pet can make"
        ),
    ]

    private var termsURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PETMOJI_TERMS_URL") as? String,
              !raw.isEmpty,
              !raw.hasPrefix("$("),
              let url = URL(string: raw) else { return nil }
        return url
    }

    private var privacyURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PETMOJI_PRIVACY_URL") as? String,
              !raw.isEmpty,
              !raw.hasPrefix("$("),
              let url = URL(string: raw) else { return nil }
        return url
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.top, 12)

                    VStack(spacing: 8) {
                        Text("unlock petmoji")
                            .font(.displayL)
                            .foregroundStyle(palette.accentDark)
                            .multilineTextAlignment(.center)

                        Text("keep your pet close — messages, widgets, and more")
                            .font(.bodyM)
                            .bold()
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(benefits) { benefit in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: benefit.icon)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(palette.accent)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        Circle()
                                            .fill(palette.accent.opacity(0.18))
                                    )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(benefit.title)
                                        .font(.bodyL)
                                        .foregroundStyle(palette.textPrimary)
                                    Text(benefit.detail)
                                        .font(.bodyS)
                                        .foregroundStyle(palette.textSecondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
                .padding(.horizontal, 24)
            }

            planCard
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pmSageScreenBackground()
        .background(PaywallDisableInteractivePop())
        .overlay {
            if isPurchasing || isLoadingOfferings {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.white)
                }
            }
        }
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .task {
            await loadOfferings()
            if allowsAutoUnlock, appState.isPro {
                onUnlocked()
            }
        }
        .onAppear {
            AnalyticsService.capture(AnalyticsEvent.paywallViewed)
        }
    }

    private var planCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 18) {
                ForEach(PaywallPlan.allCases) { plan in
                    planRow(plan)
                }
            }

            PMSageCTAButton(
                title: "continue →",
                action: { Task { await purchaseSelected() } },
                isEnabled: !isPurchasing && !isLoadingOfferings
            )

            HStack(spacing: 20) {
                footerLink("Restore Purchases") {
                    Task { await restore() }
                }
                footerLink("Terms") {
                    if let termsURL { openURL(termsURL) }
                }
                footerLink("Privacy") {
                    if let privacyURL { openURL(privacyURL) }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    private func planRow(_ plan: PaywallPlan) -> some View {
        let isSelected = selectedPlan == plan
        let priceLabel = livePriceLabel(for: plan)

        return Button {
            selectedPlan = plan
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? palette.accent : palette.sageCardStroke,
                            lineWidth: isSelected ? 0 : 1.5
                        )
                        .background(
                            Circle()
                                .fill(isSelected ? palette.accent : Color.clear)
                        )
                        .frame(width: 24, height: 24)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(.bodyL)
                        .foregroundStyle(palette.textPrimary)
                    if let subtitle = plan.subtitle {
                        Text(subtitle)
                            .font(.bodyS)
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if let compareAtPrice = plan.compareAtPrice {
                        Text(compareAtPrice)
                            .font(.bodyM)
                            .foregroundStyle(palette.textSecondary)
                            .strikethrough(true, color: palette.textSecondary)
                    }
                    Text(priceLabel)
                        .font(.bodyL)
                        .foregroundStyle(palette.textPrimary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected ? palette.accent : palette.sageCardStroke,
                        lineWidth: isSelected ? 2.5 : 1.5
                    )
            )
            .overlay(alignment: .topTrailing) {
                if let badge = plan.badge {
                    Text(badge)
                        .font(.nunito(.bold, 11))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(palette.accent))
                        .offset(x: -10, y: -10)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing)
    }

    private func footerLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.bodyS)
            .foregroundStyle(palette.textSecondary)
            .buttonStyle(.plain)
            .disabled(isPurchasing)
    }

    private func livePriceLabel(for plan: PaywallPlan) -> String {
        guard let offerings,
              let package = SubscriptionService.package(for: plan, offerings: offerings) else {
            return plan.fallbackPriceLabel
        }
        let price = package.storeProduct.localizedPriceString
        switch plan {
        case .monthly:
            return "\(price)/mo"
        case .lifetime:
            return price
        }
    }

    private func loadOfferings() async {
        isLoadingOfferings = true
        defer { isLoadingOfferings = false }
        do {
            offerings = try await SubscriptionService.fetchOfferings()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func purchaseSelected() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let currentOfferings: Offerings
            if let offerings {
                currentOfferings = offerings
            } else {
                currentOfferings = try await SubscriptionService.fetchOfferings()
                offerings = currentOfferings
            }
            guard let package = SubscriptionService.package(for: selectedPlan, offerings: currentOfferings) else {
                throw SubscriptionError.missingPackage
            }
            let info = try await SubscriptionService.purchase(package: package)
            appState.applyProStatus(SubscriptionService.isPro(from: info))
            if appState.isPro {
                AnalyticsService.capture(
                    AnalyticsEvent.subscriptionPurchased,
                    properties: [
                        "plan": selectedPlan.rawValue,
                        "product_id": package.storeProduct.productIdentifier,
                    ]
                )
                AnalyticsService.trackSubscriptionPeriod(from: info, plan: selectedPlan.rawValue)
                onUnlocked()
            } else {
                errorMessage = "Purchase finished, but Pro isn’t active yet. Try Restore Purchases."
                showError = true
            }
        } catch {
            if SubscriptionService.isUserCancelled(error) { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func restore() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let info = try await SubscriptionService.restorePurchases()
            appState.applyProStatus(SubscriptionService.isPro(from: info))
            if appState.isPro {
                AnalyticsService.capture(AnalyticsEvent.subscriptionRestored)
                AnalyticsService.trackSubscriptionPeriod(from: info)
                onUnlocked()
            } else {
                errorMessage = "No active subscription found for this Apple ID."
                showError = true
            }
        } catch {
            if SubscriptionService.isUserCancelled(error) { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Block swipe-back

private struct PaywallDisableInteractivePop: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Controller()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}
