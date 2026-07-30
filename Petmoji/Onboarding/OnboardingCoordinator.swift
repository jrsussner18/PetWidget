import SwiftUI

// MARK: - Onboarding Context

enum OnboardingContext {
    case firstPet
    case additionalPet(onDismiss: () -> Void)

    var isAdditionalPet: Bool {
        if case .additionalPet = self { return true }
        return false
    }

    func dismissAdditionalPet() {
        if case .additionalPet(let onDismiss) = self {
            onDismiss()
        }
    }
}

// MARK: - Onboarding Coordinator

struct OnboardingCoordinator: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.petmojiPalette) private var palette
    @StateObject private var draft = OnboardingDraft()
    @State private var path: [OnboardingStep] = []
    @State private var showDiscardPetConfirm = false
    @State private var isDiscardingPet = false
    @State private var personalityActiveStep = 0
    @State private var personalityIsReview = false
    @State private var persistedPetName = ""
    @State private var isSpriteRevealReady = false
    @State private var didRestore = false
    @State private var isDraftReady = false

    var context: OnboardingContext = .firstPet
    var shouldRestoreDraft: Bool = true

    enum OnboardingStep: Hashable {
        case personality
        case spriteReveal
        case widgetSetup
        case locationTracking
        case paywall
    }

    private var pendingPetId: UUID? {
        draft.completedPet?.id
    }

    private var persistedContext: PersistedOnboardingContext {
        context.isAdditionalPet ? .additionalPet : .firstPet
    }

    private var additionalPetCancelAction: (() -> Void)? {
        guard context.isAdditionalPet else { return nil }
        return { handleCancelTapped() }
    }

    var body: some View {
        NavigationStack(path: $path) {
            PhotoPickerView(
                draft: draft,
                onNext: {
                    path.append(.personality)
                    persistProgress(topStep: .personality)
                },
                onCancel: additionalPetCancelAction,
                onProgressChange: { persistProgress(topStep: .photo) }
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: OnboardingStep.self) { step in
                switch step {
                case .personality:
                    PersonalityBuilderView(
                        draft: draft,
                        initialActiveStep: personalityActiveStep,
                        initialIsReviewScreen: personalityIsReview,
                        onNext: {
                            path.append(.spriteReveal)
                            persistProgress(topStep: .spriteReveal)
                        },
                        onCancel: additionalPetCancelAction,
                        onProgressChange: { activeStep, isReview in
                            personalityActiveStep = activeStep
                            personalityIsReview = isReview
                            persistProgress(topStep: .personality)
                        }
                    )
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden(true)
                    .toolbarBackground(.hidden, for: .navigationBar)

                case .spriteReveal:
                    ExpressionRevealView(
                        draft: draft,
                        context: context,
                        initialPetName: persistedPetName,
                        initialSpriteRevealReady: isSpriteRevealReady,
                        isDraftReady: isDraftReady,
                        onComplete: handleRevealComplete,
                        onCancel: additionalPetCancelAction,
                        onProgressChange: { petName, spriteRevealReady in
                            persistedPetName = petName
                            if spriteRevealReady {
                                isSpriteRevealReady = true
                            }
                            persistProgress(
                                topStep: .spriteReveal,
                                petName: petName,
                                isSpriteRevealReady: spriteRevealReady ? true : isSpriteRevealReady
                            )
                        }
                    )
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden(true)

                case .widgetSetup:
                    WidgetSetupView(
                        onNext: {
                            // Ask for notifications here so users who later skip location
                            // tracking still get prompted (idempotent — the location step's
                            // request becomes a no-op once permission is determined).
                            Task {
                                _ = await MessageScheduler.shared.requestNotificationPermission()
                                path.append(.locationTracking)
                                persistProgress(topStep: .locationTracking)
                            }
                        },
                        onCancel: additionalPetCancelAction
                    )
                    .navigationBarBackButtonHidden(true)
                    .onAppear {
                        persistProgress(topStep: .widgetSetup)
                    }

                case .locationTracking:
                    HomeLocationSetupView(
                        pet: draft.completedPet,
                        onDone: {
                            if SubscriptionConfig.isPaywallEnabled {
                                path.append(.paywall)
                                persistProgress(topStep: .paywall)
                            } else {
                                finishOnboarding()
                            }
                        },
                        onCancel: additionalPetCancelAction
                    )
                    .navigationBarBackButtonHidden(true)
                    .onAppear {
                        persistProgress(topStep: .locationTracking)
                    }

                case .paywall:
                    Group {
                        if SubscriptionConfig.isPaywallEnabled {
                            PaywallView(onUnlocked: finishOnboarding)
                        } else {
                            Color.clear
                                .onAppear { finishOnboarding() }
                        }
                    }
                    .navigationBarBackButtonHidden(true)
                    .onAppear {
                        if SubscriptionConfig.isPaywallEnabled {
                            persistProgress(topStep: .paywall)
                        }
                    }
                }
            }
        }
        .tint(palette.toolbarTint)
        .alert("Discard this pet?", isPresented: $showDiscardPetConfirm) {
            Button("Discard", role: .destructive) {
                Task { await discardPendingPetAndDismiss() }
            }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your new pet will be removed and you'll return home.")
        }
        .disabled(isDiscardingPet)
        .task {
            await restoreProgressIfNeeded()
        }
    }

    private func persistProgress(
        topStep: PersistedOnboardingTopStep,
        petName: String? = nil,
        isSpriteRevealReady: Bool? = nil
    ) {
        OnboardingDraftStore.save(
            draft: draft,
            context: persistedContext,
            topStep: topStep,
            personalityActiveStep: personalityActiveStep,
            personalityIsReview: personalityIsReview,
            petName: petName ?? persistedPetName,
            isSpriteRevealReady: isSpriteRevealReady ?? self.isSpriteRevealReady
        )
    }

    @MainActor
    private func restoreProgressIfNeeded() async {
        defer { isDraftReady = true }

        guard !didRestore else { return }
        didRestore = true

        guard shouldRestoreDraft,
              let progress = OnboardingDraftStore.load(),
              progress.context == persistedContext else {
            return
        }

        OnboardingDraftStore.apply(progress, to: draft)
        personalityActiveStep = progress.personalityActiveStep
        personalityIsReview = progress.personalityIsReview
        persistedPetName = progress.petName
        isSpriteRevealReady = progress.isSpriteRevealReady

        if let petId = progress.pendingPetId,
           let pet = try? await SupabaseService.shared.fetchPet(by: petId) {
            draft.completedPet = pet
            draft.generatedExpressions = pet.expressions
            if progress.isSpriteRevealReady || pet.expressions.happy != nil {
                isSpriteRevealReady = true
            }
        }

        path = OnboardingDraftStore.navigationPath(for: progress.topStep)
    }

    private func handleCancelTapped() {
        if pendingPetId != nil {
            showDiscardPetConfirm = true
        } else {
            OnboardingDraftStore.clear()
            dismissFlow()
        }
    }

    private func dismissFlow() {
        context.dismissAdditionalPet()
    }

    private func handleRevealComplete(_ pet: Pet) {
        draft.completedPet = pet
        if context.isAdditionalPet {
            OnboardingDraftStore.clear()
            Task {
                await appState.loadPets(showLoading: false)
                context.dismissAdditionalPet()
            }
        } else {
            path.append(.widgetSetup)
            persistProgress(topStep: .widgetSetup)
        }
    }

    @MainActor
    private func discardPendingPetAndDismiss() async {
        guard let petId = pendingPetId else {
            OnboardingDraftStore.clear()
            dismissFlow()
            return
        }
        isDiscardingPet = true
        appState.stopSyncingExpressions()
        try? await SupabaseService.shared.deletePet(petId: petId)
        appState.removePetLocally(petId: petId)
        draft.completedPet = nil
        OnboardingDraftStore.clear()
        isDiscardingPet = false
        dismissFlow()
    }

    private func finishOnboarding() {
        if appState.currentPet == nil, let pet = draft.completedPet {
            appState.setPet(pet)
            appState.startSyncingExpressions(petId: pet.id)
        }
        OnboardingDraftStore.clear()
        appState.setHasCompletedOnboarding(true)
        AnalyticsService.capture(AnalyticsEvent.onboardingCompleted)
    }
}

// MARK: - Onboarding Draft (shared state)

@MainActor
final class OnboardingDraft: ObservableObject {
    @Published var photos: [UIImage] = []
    @Published var photoData: [Data] = []
    @Published var name: String = ""
    @Published var species: Species = .dog
    @Published var gender: PetGender = .boy
    @Published var selectedTraits: Set<PersonalityTrait> = []
    @Published var energyLevel: Double = 5.0
    @Published var selectedTriggers: Set<PetTrigger> = []
    @Published var customTrigger: String = ""
    @Published var baseMood: BaseMood = .chill
    @Published var completedPet: Pet?
    @Published var generatedExpressions: ExpressionMap = ExpressionMap()

    var isPhotoStepValid: Bool { !photos.isEmpty }
    var isPersonalityStepValid: Bool {
        selectedTraits.count == 3 && isTriggersStepValid
    }
}

// MARK: - Resume prompt copy

enum OnboardingResumePrompt {
    static func title(isSecondPet: Bool) -> String {
        isSecondPet
            ? "looks like your second pet isn't done!"
            : "looks like your pet isn't done!"
    }

    static let message = "Pick up where you left off and finish creating your pet."
}

// MARK: - First pet onboarding gate (resume vs restart)

struct FirstPetOnboardingGateView: View {
    @EnvironmentObject var appState: AppState
    @State private var gateResolved = !OnboardingDraftStore.hasPendingFirstPetDraft
    @State private var shouldRestoreDraft = true
    @State private var showResumePrompt = false
    @State private var coordinatorID = UUID()

    private var showsOnboarding: Bool {
        gateResolved || !OnboardingDraftStore.hasPendingFirstPetDraft
    }

    var body: some View {
        Group {
            if showsOnboarding {
                OnboardingCoordinator(shouldRestoreDraft: shouldRestoreDraft)
                    .id(coordinatorID)
            } else {
                BrandLandingView(mode: .loading)
            }
        }
        .onAppear { presentResumePromptIfNeeded() }
        .alert(
            OnboardingResumePrompt.title(isSecondPet: false),
            isPresented: $showResumePrompt
        ) {
            Button("Continue") {
                shouldRestoreDraft = true
                gateResolved = true
            }
            Button("Restart", role: .destructive) {
                Task { await restartOnboarding() }
            }
        } message: {
            Text(OnboardingResumePrompt.message)
        }
    }

    private func presentResumePromptIfNeeded() {
        guard OnboardingDraftStore.hasPendingFirstPetDraft, !gateResolved else { return }
        showResumePrompt = true
    }

    @MainActor
    private func restartOnboarding() async {
        await appState.abandonPendingOnboardingDraft()
        shouldRestoreDraft = false
        coordinatorID = UUID()
        gateResolved = true
    }
}
