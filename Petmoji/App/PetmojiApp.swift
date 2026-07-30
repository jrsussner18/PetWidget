import SwiftUI
import UserNotifications

@main
struct PetmojiApp: App {
    @StateObject private var appState = AppState()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onOpenURL { url in
                    guard url.scheme?.lowercased() == "petmoji" else { return }
                    if url.host?.lowercased() == "chat" {
                        let petId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?
                            .first(where: { $0.name == "petId" })?
                            .value
                            .flatMap(UUID.init(uuidString:))
                        appState.pendingWidgetDeepLink = .openChat(petId: petId)
                    }
                }
        }
    }
}

// MARK: - App Delegate (APNs registration)

class AppDelegate: NSObject, UIApplicationDelegate, @MainActor UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PushNotificationService.configure(launchOptions: launchOptions)
        SubscriptionService.configure()
        AnalyticsService.configure()
        BeenGoneBackgroundScheduler.registerHandlers()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task { @MainActor in
            // Re-register for APNs each foreground so an authorized user always has a current
            // device token stored server-side (tokens can rotate); otherwise pushes never fire.
            await MessageScheduler.shared.registerForPushIfAuthorized()
            await PetMessageDelivery.refreshWidgetFromServer()
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            try? await SupabaseService.shared.registerDeviceToken(token)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error)")
    }

    // Handle silent push → fetch message and deliver with avatar
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let result = await PushNotificationHandler.handle(userInfo: userInfo)
            completionHandler(result)
        }
    }

    // A push arriving while the app is in the foreground only triggers `willPresent`
    // (not `didReceiveRemoteNotification`), so deliver/refresh the widget here too.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            _ = await PushNotificationHandler.handle(userInfo: notification.request.content.userInfo)
        }
        completionHandler([.banner, .sound, .list])
    }

    // Tapping a notification must also refresh the widget — background wake is not guaranteed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            _ = await PushNotificationHandler.handle(userInfo: response.notification.request.content.userInfo)
            completionHandler()
        }
    }
}

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var debugDraft = OnboardingDraft()
#if DEBUG
    @State private var showDebugLocationTracking = false
#endif

    private var shouldSkipOnboardingToReveal: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-skipOnboardingToReveal")
#else
        false
#endif
    }

    private var shouldUseMockSprites: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-mockSprites")
#else
        false
#endif
    }

    private var shouldSkipOnboardingToWidgetSetup: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-skipOnboardingToWidgetSetup")
#else
        false
#endif
    }

    private var shouldSkipOnboardingToLocationTracking: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-skipOnboardingToLocationTracking")
#else
        false
#endif
    }

    private var isShowingDebugLocationTracking: Bool {
#if DEBUG
        showDebugLocationTracking || shouldSkipOnboardingToLocationTracking
#else
        false
#endif
    }

    private var shouldSkipSignUp: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-skipSignUp")
#else
        false
#endif
    }

    var body: some View {
        Group {
            rootRoutingContent
        }
        .environment(\.petmojiPalette, PetmojiPalette.palette(for: appState.visualStyle))
        .preferredColorScheme(appState.visualStyle == .widgetGlass ? .dark : .light)
        .task {
            let skipNormalBootstrap = shouldSkipOnboardingToReveal
                || shouldSkipOnboardingToWidgetSetup
                || shouldSkipOnboardingToLocationTracking
#if DEBUG
            let wantsTestNotifications = !debugTestPetMessageEvents.isEmpty
#else
            let wantsTestNotifications = false
#endif

            if !skipNormalBootstrap || wantsTestNotifications {
#if DEBUG
                if shouldForceSignOut {
                    await appState.signOut()
                }
#endif
                await appState.bootstrap()
#if DEBUG
                await runDebugTestNotificationsIfNeeded()
#endif
            } else {
                appState.markBootstrapComplete()
            }
        }
    }

    @ViewBuilder
    private var rootRoutingContent: some View {
#if DEBUG
        if isShowingDebugLocationTracking {
            DebugLocationTrackingFlowView(
                pet: appState.currentPet ?? makeDebugRogerPet(useMockSprites: shouldUseMockSprites),
                onSetPet: appState.setPet(_:),
                onComplete: { appState.setHasCompletedOnboarding(true) },
                onDismiss: shouldSkipOnboardingToLocationTracking ? nil : {
                    showDebugLocationTracking = false
                }
            )
        } else if shouldSkipOnboardingToWidgetSetup && appState.currentPet == nil {
            DebugWidgetSetupFlowView(
                pet: makeDebugRogerPet(useMockSprites: shouldUseMockSprites),
                onSetPet: appState.setPet(_:),
                onComplete: { appState.setHasCompletedOnboarding(true) }
            )
        } else if shouldSkipOnboardingToReveal {
            DebugRevealFlowView(
                draft: debugDraft,
                onSetPet: appState.setPet(_:),
                useMockSprites: shouldUseMockSprites
            )
        } else {
            standardRootContent
        }
#else
        standardRootContent
#endif
    }

    @ViewBuilder
    private var standardRootContent: some View {
        if appState.isBootstrapping || appState.isLoading {
            BrandLandingView(mode: .loading)
        } else if !appState.isAuthenticated && !shouldSkipSignUp {
            if !appState.hasSeenWelcome {
                BrandLandingView(mode: .welcome) {
                    appState.setHasSeenWelcome(true)
                }
            } else {
                AuthCoordinator()
            }
        } else if appState.isAuthenticated, appState.hasCompletedOnboarding, SubscriptionConfig.isPaywallEnabled, !appState.isPro {
            PaywallView(onUnlocked: {})
        } else if appState.isAuthenticated, !appState.pets.isEmpty, appState.hasCompletedOnboarding,
                  !SubscriptionConfig.isPaywallEnabled || appState.isPro {
            NavigationStack {
                PetHomeView()
            }
        } else if appState.isAuthenticated {
            FirstPetOnboardingGateView()
        } else {
            AuthCoordinator()
        }
    }

#if DEBUG
    private var debugTestPetMessageEvents: [String] {
        DebugLaunchArgs.testPetMessageEvents
    }

    @MainActor
    private func runDebugTestNotificationsIfNeeded() async {
        guard !debugTestPetMessageEvents.isEmpty else { return }

        guard appState.isAuthenticated else {
            print("[Debug] Test notification skipped — sign in first.")
            return
        }

        guard !appState.pets.isEmpty else {
            print("[Debug] Test notification skipped — no pets loaded.")
            return
        }

        for (index, event) in debugTestPetMessageEvents.enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            do {
                let content = try await PetMessageDelivery.sendTestMessage(appState: appState, event: event)
                print("[Debug] Test notification (\(event)): \"\(content)\"")
            } catch {
                print("[Debug] Test notification failed (\(event)): \(debugErrorDescription(error))")
            }
        }
    }

    private var shouldForceSignOut: Bool {
        ProcessInfo.processInfo.arguments.contains("-forceSignOut")
    }

    private func debugErrorDescription(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let context) = error {
            return "Decode error: \(context.debugDescription)"
        }
        if case DecodingError.keyNotFound(let key, let context) = error {
            return "Missing key \"\(key.stringValue)\": \(context.debugDescription)"
        }
        if case DecodingError.typeMismatch(let type, let context) = error {
            return "Type mismatch for \(type): \(context.debugDescription)"
        }
        if case DecodingError.valueNotFound(let type, let context) = error {
            return "Missing value for \(type): \(context.debugDescription)"
        }
        return error.localizedDescription
    }

    private func makeDebugRogerPet(useMockSprites: Bool) -> Pet {
        Pet(
            id: UUID(),
            userId: UUID(),
            name: "Roger",
            species: .dog,
            gender: .boy,
            expressions: useMockSprites ? debugTesterExpressions() : ExpressionMap(),
            personalityTraits: [.dramatic, .sneaky, .sweet],
            energyLevel: 7,
            triggers: [.vacuumCleaner],
            customTrigger: nil,
            baseMood: .mildlySuspicious,
            homeLat: nil,
            homeLng: nil,
            timezone: TimeZone.current.identifier,
            createdAt: Date()
        )
    }

    private func debugTesterExpressions() -> ExpressionMap {
        let bundled = ExpressionMap(
            happy: debugBundleSpriteURL(named: "tester_happy"),
            sleepy: debugBundleSpriteURL(named: "tester_sleepy"),
            mad: debugBundleSpriteURL(named: "tester_mad"),
            excited: debugBundleSpriteURL(named: "tester_excited"),
            missesYou: debugBundleSpriteURL(named: "tester_misses_you"),
            judging: debugBundleSpriteURL(named: "tester_judging")
        )
        let hasAllBundled = [
            bundled.happy, bundled.sleepy, bundled.mad,
            bundled.excited, bundled.missesYou, bundled.judging
        ].allSatisfy { $0 != nil }
        guard hasAllBundled else {
            return ExpressionMap(
                happy: "https://placehold.co/400x400/CDE6C8/2F5D46?text=happy",
                sleepy: "https://placehold.co/400x400/DCE9D7/2F5D46?text=sleepy",
                mad: "https://placehold.co/400x400/BBD8B3/2F5D46?text=mad",
                excited: "https://placehold.co/400x400/CDE6C8/2F5D46?text=excited",
                missesYou: "https://placehold.co/400x400/DCE9D7/2F5D46?text=misses+you",
                judging: "https://placehold.co/400x400/BBD8B3/2F5D46?text=judging"
            )
        }
        return bundled
    }

    private func debugBundleSpriteURL(named resourceName: String) -> String? {
        if let pngURL = Bundle.main.url(forResource: resourceName, withExtension: "png") {
            return pngURL.absoluteString
        }
        if let jpgURL = Bundle.main.url(forResource: resourceName, withExtension: "jpg") {
            return jpgURL.absoluteString
        }
        if let jpegURL = Bundle.main.url(forResource: resourceName, withExtension: "jpeg") {
            return jpegURL.absoluteString
        }
        if let webpURL = Bundle.main.url(forResource: resourceName, withExtension: "webp") {
            return webpURL.absoluteString
        }
        return nil
    }
#endif
}

private struct DebugLocationTrackingFlowView: View {
    let pet: Pet
    let onSetPet: (Pet) -> Void
    let onComplete: () -> Void
    var onDismiss: (() -> Void)?

    var body: some View {
        NavigationStack {
            HomeLocationSetupView(pet: pet) {
                onSetPet(pet)
                onComplete()
            }
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if let onDismiss {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { onDismiss() }
                            .font(.bodyM)
                    }
                }
            }
        }
    }
}

private struct DebugRevealFlowView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var draft: OnboardingDraft
    let onSetPet: (Pet) -> Void
    let useMockSprites: Bool

    @State private var path: [Step] = []

    private enum Step: Hashable {
        case widgetSetup
        case locationTracking
    }

    var body: some View {
        NavigationStack(path: $path) {
            ExpressionRevealView(
                draft: draft,
                onComplete: { pet in
                    onSetPet(pet)
                    path.append(.widgetSetup)
                },
                skipGenerationForDebug: true,
                useMockSpritesForDebug: useMockSprites
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .pmOnboardingToolbar(total: 5, current: 2)
            .navigationBarBackButtonHidden(true)
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .widgetSetup:
                    WidgetSetupView(
                        onNext: { path.append(.locationTracking) }
                    )
                    .navigationBarBackButtonHidden(true)
                case .locationTracking:
                    HomeLocationSetupView(
                        pet: draft.completedPet
                    ) {
                        if let pet = draft.completedPet {
                            onSetPet(pet)
                        }
                        appState.setHasCompletedOnboarding(true)
                    }
                    .navigationBarBackButtonHidden(true)
                }
            }
        }
    }
}

private struct DebugWidgetSetupFlowView: View {
    let pet: Pet
    let onSetPet: (Pet) -> Void
    let onComplete: () -> Void

    @State private var path: [Step] = []

    private enum Step: Hashable {
        case locationTracking
    }

    var body: some View {
        NavigationStack(path: $path) {
            WidgetSetupView(onNext: { path.append(.locationTracking) })
                .navigationBarBackButtonHidden(true)
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .locationTracking:
                        HomeLocationSetupView(pet: pet) {
                            onSetPet(pet)
                            onComplete()
                        }
                        .navigationBarBackButtonHidden(true)
                    }
                }
        }
    }
}

enum PendingWidgetDeepLink: Equatable {
    case none
    case openChat(petId: UUID?)
}

@MainActor
final class AppState: ObservableObject {
    static let maxPets = 2

    @Published var currentPet: Pet?
    @Published private(set) var pets: [Pet] = []
    @Published var widgetPetId: UUID?
    @Published var isLoading = false
    @Published private(set) var isBootstrapping = true
    @Published private(set) var isAuthenticated = false
    @Published var pendingWidgetDeepLink = PendingWidgetDeepLink.none

    // MARK: - User account cache (profiles + local prefs)

    @Published var settingsPersona: SettingsPersona = .pet
    @Published var hasCompletedSignUp: Bool = false
    @Published var hasCompletedOnboarding: Bool = false
    @Published var hasSeenWelcome: Bool = false
    @Published private(set) var isPro: Bool = false
    @Published var userDisplayName: String = ""
    @Published var userEmail: String = ""
    @Published var userPhone: String = ""

    @Published var visualStyle: AppVisualStyle = .widgetGlass

    private let supabase = SupabaseService.shared
    private var expressionSyncTask: Task<Void, Never>?

    /// While set, Stage B may still be writing expressions for this pet — used for Settings thumbnails.
    @Published private(set) var expressionSyncPetId: UUID?

    init() {
        loadUserSettingsFromUserDefaults()
        loadAppearanceFromUserDefaults()
    }

    private func loadAppearanceFromUserDefaults() {
        let d = UserDefaults.standard
        if d.object(forKey: MockUserSettings.Keys.darkMode) != nil {
            visualStyle = d.bool(forKey: MockUserSettings.Keys.darkMode) ? .widgetGlass : .classic
            return
        }
        if let raw = d.string(forKey: MockUserSettings.legacyVisualStyleKey),
           let style = AppVisualStyle(rawValue: raw) {
            visualStyle = style
            d.set(style == .widgetGlass, forKey: MockUserSettings.Keys.darkMode)
            d.removeObject(forKey: MockUserSettings.legacyVisualStyleKey)
            return
        }
        visualStyle = .widgetGlass
    }

    func setVisualStyle(_ value: AppVisualStyle) {
        visualStyle = value
        UserDefaults.standard.set(value == .widgetGlass, forKey: MockUserSettings.Keys.darkMode)
    }

    var isDarkModeEnabled: Bool {
        visualStyle == .widgetGlass
    }

    func setDarkModeEnabled(_ enabled: Bool) {
        setVisualStyle(enabled ? .widgetGlass : .classic)
    }

    private func loadUserSettingsFromUserDefaults() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: MockUserSettings.Keys.persona) {
            settingsPersona = SettingsPersona(storedRawValue: raw)
        } else {
            settingsPersona = .pet
        }
        hasCompletedSignUp = d.bool(forKey: MockUserSettings.Keys.signupCompleted)
        hasCompletedOnboarding = d.bool(forKey: MockUserSettings.Keys.onboardingCompleted)
        hasSeenWelcome = d.bool(forKey: MockUserSettings.Keys.hasSeenWelcome)
        userDisplayName = d.string(forKey: MockUserSettings.Keys.displayName) ?? ""
        userEmail = d.string(forKey: MockUserSettings.Keys.email) ?? ""
        userPhone = d.string(forKey: MockUserSettings.Keys.phone) ?? ""
        if let raw = d.string(forKey: MockUserSettings.Keys.widgetPetId) {
            widgetPetId = UUID(uuidString: raw)
        }
    }

    func setUserDisplayName(_ value: String) {
        userDisplayName = value
        UserDefaults.standard.set(value, forKey: MockUserSettings.Keys.displayName)
    }

    func setUserEmail(_ value: String) {
        userEmail = value
        UserDefaults.standard.set(value, forKey: MockUserSettings.Keys.email)
    }

    func setUserPhone(_ value: String) {
        userPhone = value
        UserDefaults.standard.set(value, forKey: MockUserSettings.Keys.phone)
    }

    func setSettingsPersona(_ value: SettingsPersona) {
        settingsPersona = value
        UserDefaults.standard.set(value.rawValue, forKey: MockUserSettings.Keys.persona)
    }

    func refreshProfileIfNeeded() async {
        if let profile = try? await supabase.fetchProfile() {
            applyProfileCache(profile)
        }
    }

    func setHasCompletedSignUp(_ value: Bool) {
        hasCompletedSignUp = value
        UserDefaults.standard.set(value, forKey: MockUserSettings.Keys.signupCompleted)
    }

    func setHasCompletedOnboarding(_ value: Bool) {
        hasCompletedOnboarding = value
        UserDefaults.standard.set(value, forKey: MockUserSettings.Keys.onboardingCompleted)
    }

    func setHasSeenWelcome(_ value: Bool) {
        hasSeenWelcome = value
        UserDefaults.standard.set(value, forKey: MockUserSettings.Keys.hasSeenWelcome)
    }

    func markBootstrapComplete() {
        isBootstrapping = false
    }

    func bootstrap() async {
        defer { isBootstrapping = false }
        guard await supabase.validatePersistedSession() != nil else {
            clearAllPersistedUserData()
            applyUnauthenticatedState()
            return
        }
        isAuthenticated = true
        await restoreAuthenticatedSession()
    }

    private func clearAllPersistedUserData() {
        MockUserSettings.clearAllPersistedState()
        ChatHistoryStore.clearAllHistories()
        OnboardingDraftStore.clear()
        WidgetSnapshotSync.clear()
        LocationService.shared.clearPersistedLocationData()
        MessageScheduler.shared.cancelBeenGoneNotifications()
    }

    /// Clears in-memory app data when there is no Supabase session (stale UserDefaults must not unlock the app).
    func applyUnauthenticatedState() {
        isAuthenticated = false
        stopSyncingExpressions()
        currentPet = nil
        pets = []
        widgetPetId = nil
        setHasCompletedSignUp(false)
        setHasCompletedOnboarding(false)
        setHasSeenWelcome(false)
        isPro = false
        setUserDisplayName("")
        setUserEmail("")
        setUserPhone("")
    }

    /// After sign-in or session restore: fetch pets first (routes to home when present), then profile cache.
    func restoreAuthenticatedSession(showLoading: Bool = true) async {
        isAuthenticated = true
        await loadPets(showLoading: showLoading)
        await hydrateFromProfile()

        // Keychain session can outlive UserDefaults (e.g. TestFlight reinstall). Without a
        // profile or sign-up flag, don't treat orphan pets as a logged-in user.
        let hasProfile = (try? await supabase.fetchProfile()) != nil
        if !hasCompletedSignUp && !hasProfile {
            if pets.isEmpty {
                setHasCompletedOnboarding(false)
            } else {
                await signOut()
                return
            }
        }

        if let userId = try? await supabase.currentUserId() {
            PushNotificationService.login(userId: userId)
            await SubscriptionService.logIn(userId: userId)
            AnalyticsService.identify(
                userId: userId,
                email: userEmail.isEmpty ? nil : userEmail,
                name: userDisplayName.isEmpty ? nil : userDisplayName
            )
        }
        await refreshSubscriptionStatus()
    }

    func applyProStatus(_ active: Bool) {
        isPro = active
    }

    func refreshSubscriptionStatus() async {
        guard SubscriptionConfig.isPaywallEnabled else {
            applyProStatus(true)
            return
        }
        do {
            let info = try await SubscriptionService.refreshCustomerInfo()
            applyProStatus(SubscriptionService.isPro(from: info))
            AnalyticsService.trackSubscriptionPeriod(from: info)
        } catch {
            print("[AppState] refreshSubscriptionStatus failed: \(error.localizedDescription)")
        }
    }

    func hydrateFromProfile() async {
        if let profile = try? await supabase.fetchProfile() {
            applyProfileCache(profile)
            setHasCompletedSignUp(true)
            return
        }
        if let session = try? await supabase.client.auth.session,
           let email = session.user.email, !email.isEmpty {
            setUserEmail(email)
            setHasCompletedSignUp(true)
        }
    }

    private func applyProfileCache(_ profile: UserProfile) {
        setUserDisplayName(profile.fullName)
        setUserEmail(profile.email)
        if let phone = profile.phone {
            setUserPhone(phone)
        }
    }

    func completeSignUp(from draft: SignUpDraft) async {
        isAuthenticated = true
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let email = draft.email.trimmingCharacters(in: .whitespacesAndNewlines)
        setUserDisplayName(name)
        setUserEmail(email)
        setHasCompletedSignUp(true)
        if let userId = try? await supabase.currentUserId() {
            PushNotificationService.login(userId: userId)
            await SubscriptionService.logIn(userId: userId)
            AnalyticsService.identify(userId: userId, email: email, name: name)
        }
        AnalyticsService.capture(AnalyticsEvent.signUpCompleted)
        await refreshSubscriptionStatus()
    }

    func loadPets(showLoading: Bool = true) async {
        if showLoading { isLoading = true }
        defer { if showLoading { isLoading = false } }
        do {
            let previousCurrentId = currentPet?.id
            let fetched = try await supabase.fetchAllPets(limit: Self.maxPets)
            pets = fetched
            if let previousCurrentId,
               let kept = fetched.first(where: { $0.id == previousCurrentId }) {
                currentPet = kept
            } else {
                currentPet = fetched.first
            }
            resolveWidgetPetId()
            if !fetched.isEmpty,
               OnboardingDraftStore.load()?.context != .firstPet,
               hasCompletedOnboarding || hasCompletedSignUp {
                setHasCompletedOnboarding(true)
            }
            if let displayable = displayablePets.first(where: { $0.id == currentPet?.id }) {
                currentPet = displayable
            } else {
                currentPet = displayablePets.first ?? currentPet
            }
            syncHomeGeofenceFromCurrentPet()
            await syncWidgetSnapshot()
            await PetMessageDelivery.refreshWidgetFromServer()
        } catch {
            pets = []
            currentPet = nil
            setWidgetPetId(nil)
            if SupabaseService.isAuthError(error) {
                await signOut()
            }
        }
    }

    private func resolveWidgetPetId() {
        if let widgetPetId,
           displayablePets.contains(where: { $0.id == widgetPetId }) {
            return
        }
        if let firstPet = displayablePets.first {
            setWidgetPetId(firstPet.id)
        } else if displayablePets.isEmpty, !pets.isEmpty {
            // Keep widget pet if only hidden incomplete pets remain.
            return
        } else {
            setWidgetPetId(nil)
        }
    }

    private func setWidgetPetId(_ id: UUID?) {
        widgetPetId = id
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: MockUserSettings.Keys.widgetPetId)
        } else {
            UserDefaults.standard.removeObject(forKey: MockUserSettings.Keys.widgetPetId)
        }
    }

    var widgetPet: Pet? {
        guard let widgetPetId else { return pets.first }
        return pets.first { $0.id == widgetPetId } ?? pets.first
    }

    var canAddPet: Bool { displayablePets.count < Self.maxPets }

    var displayablePets: [Pet] {
        let pendingId = OnboardingDraftStore.pendingPetId
        return pets.filter { pet in
            guard pet.name == "unnamed", let pendingId, pet.id == pendingId else {
                return true
            }
            return false
        }
    }

    var availablePets: [Pet] { displayablePets }

    func setWidgetPet(_ pet: Pet) {
        setWidgetPetId(pet.id)
        Task { await syncWidgetSnapshot() }
    }

    func syncWidgetSnapshot() async {
        guard let pet = widgetPet else { return }
        if let message = try? await supabase.fetchLatestMessage(for: pet.id) {
            WidgetSnapshotSync.writeFromPet(pet, message: message)
        }
    }

    func registerNewPet(_ pet: Pet) {
        var next = pets.filter { $0.id != pet.id }
        next.append(pet)
        next.sort { $0.createdAt < $1.createdAt }
        pets = Array(next.prefix(Self.maxPets))
        mergePet(pet)
        startSyncingExpressions(petId: pet.id)
    }

    private func mergePet(_ pet: Pet) {
        if var current = currentPet, current.id == pet.id {
            current = pet
            currentPet = current
        }
        if let index = pets.firstIndex(where: { $0.id == pet.id }) {
            pets[index] = pet
        }
    }

    func updateCurrentPetHome(lat: Double, lng: Double, address: String?) {
        guard let petId = currentPet?.id else { return }
        updatePetHome(petId: petId, lat: lat, lng: lng, address: address)
    }

    func updatePetHome(petId: UUID, lat: Double, lng: Double, address: String?) {
        guard var pet = pets.first(where: { $0.id == petId }) else { return }
        pet.homeLat = lat
        pet.homeLng = lng
        pet.homeAddress = address
        mergePet(pet)
        if currentPet?.id == petId {
            syncHomeGeofenceFromCurrentPet()
        }
    }

    func syncHomeGeofenceFromCurrentPet() {
        guard let pet = currentPet,
              let lat = pet.homeLat,
              let lng = pet.homeLng else { return }
        LocationService.shared.syncHomeGeofence(
            lat: lat,
            lng: lng,
            petId: pet.id,
            petName: pet.name
        )
    }

    func setPet(_ pet: Pet) {
        currentPet = pet
        if let index = pets.firstIndex(where: { $0.id == pet.id }) {
            pets[index] = pet
        } else if pets.count < Self.maxPets {
            pets.append(pet)
            pets.sort { $0.createdAt < $1.createdAt }
        }
    }

    func removePetLocally(petId: UUID) {
        pets.removeAll { $0.id == petId }
        if currentPet?.id == petId {
            currentPet = pets.first
        }
        resolveWidgetPetId()
    }

    func deletePet(_ pet: Pet) async {
        if expressionSyncPetId == pet.id {
            stopSyncingExpressions()
        }
        try? await supabase.deletePet(petId: pet.id)
        ChatHistoryStore.clearHistory(for: pet.id)
        removePetLocally(petId: pet.id)
        AnalyticsService.capture(AnalyticsEvent.petDeleted, properties: ["pet_id": pet.id.uuidString])
        await syncWidgetSnapshot()
    }

    func selectPet(_ pet: Pet) {
        currentPet = pet
    }

    /// Clears in-progress onboarding draft and any incomplete server pet row.
    func abandonPendingOnboardingDraft() async {
        if let petId = OnboardingDraftStore.pendingPetId {
            stopSyncingExpressions()
            try? await supabase.deletePet(petId: petId)
            removePetLocally(petId: petId)
        }
        OnboardingDraftStore.clear()
    }

    /// Clears session, pet, and cached profile so the app returns to sign-in.
    func signOut() async {
        stopSyncingExpressions()
        MessageScheduler.shared.cancelBeenGoneNotifications()
        PushNotificationService.logout()
        await SubscriptionService.logOut()
        AnalyticsService.capture(AnalyticsEvent.signOut)
        AnalyticsService.reset()
        try? await SupabaseService.shared.client.auth.signOut(scope: .global)
        clearAllPersistedUserData()
        applyUnauthenticatedState()
    }

    /// Permanently deletes the account on the server and clears all local state.
    func deleteAccount() async throws {
        let petIds = pets.map(\.id)
        stopSyncingExpressions()
        MessageScheduler.shared.cancelBeenGoneNotifications()
        PushNotificationService.logout()
        await SubscriptionService.logOut()
        AnalyticsService.reset()
        try await supabase.deleteAccount()
        for petId in petIds {
            ChatHistoryStore.clearHistory(for: petId)
        }
        try? await SupabaseService.shared.client.auth.signOut(scope: .global)
        clearAllPersistedUserData()
        applyUnauthenticatedState()
    }

    /// After kicking off `generate-sprites`, the edge function returns once
    /// the `happy` base sprite is ready and continues to fill in the other 5
    /// expressions in the background (writing each to `pets.expressions`).
    /// This polls the row and merges new expressions into `currentPet` as they
    /// arrive, so the UI updates without a manual refresh.
    func startSyncingExpressions(petId: UUID) {
        expressionSyncTask?.cancel()
        expressionSyncPetId = petId
        expressionSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.expressionSyncPetId = nil }
            do {
                for try await partial in self.supabase.observePetExpressions(petId: petId) {
                    if Task.isCancelled { return }
                    if var pet = self.pets.first(where: { $0.id == petId }) {
                        pet.expressions = partial
                        self.mergePet(pet)
                    }
                }
            } catch {
                print("[AppState] expression sync ended with error: \(error)")
            }
        }
    }

    func stopSyncingExpressions() {
        expressionSyncTask?.cancel()
        expressionSyncTask = nil
        expressionSyncPetId = nil
    }
}
