import SwiftUI
import UIKit

private enum PetCardToggleAnimation {
    /// Slower, low-bounce spring so the card height and hero art ease in instead of snapping.
    static let main = Animation.spring(duration: 0.58, bounce: 0.12)
}

struct PetHomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.petmojiPalette) private var palette
    @Namespace private var petCardHeroNamespace
    @State private var latestMessageByPet: [UUID: PetMessage] = [:]
    @State private var recentMessagesByPet: [UUID: [ChatMessage]] = [:]
    @State private var isLoadingByPet: [UUID: Bool] = [:]
    @State private var breatheByPet: [UUID: Bool] = [:]
    @State private var showSettings = false
    @State private var showAddPetOnboarding = false
    @State private var selectedPetForChatRoom: Pet?
    @State private var showChatRoom = false
    @State private var showResumeSecondPetPrompt = false
    @State private var showAddPetConfirm = false
    @State private var didShowResumePrompt = false
    @State private var declinedResumeOnce = false
    #if DEBUG
    @State private var showPaywallDebug = false
    #endif
    @AppStorage("petHomeExpandedPetIDs") private var expandedPetIDsRaw = ""

    private var pets: [Pet] { appState.availablePets }
    private var supportsCollapsibleCards: Bool { pets.count > 1 }
    private var expandedPetIDs: Set<UUID> {
        Set(expandedPetIDsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "good morning"
        case 12..<17: return "good afternoon"
        case 17..<21: return "good evening"
        default: return "goodnight"
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset: CGFloat = 16
            let contentWidth = max(220, proxy.size.width - (horizontalInset * 2))
            let recentPreviewLimit = proxy.size.height < 760 ? 2 : 3

            ZStack {
                PMSageScreenBackdrop()

                VStack(spacing: 12) {
                    HomeHeader(
                        greeting: greeting,
                        petCount: pets.count,
                        canAddPet: appState.canAddPet,
                        onAddPet: handleAddPetTapped,
                        onShowSettings: { showSettings = true },
                        onShowPaywallDebug: {
                            #if DEBUG
                            showPaywallDebug = true
                            #endif
                        }
                    )
                    .padding(.horizontal, horizontalInset)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            if pets.isEmpty {
                                RoundedRectangle(cornerRadius: 30, style: .continuous)
                                    .fill(palette.elevatedCardFill)
                                    .overlay(
                                        Text("no pet yet")
                                            .font(.bodyL)
                                            .foregroundStyle(palette.textSecondary)
                                    )
                                    .frame(height: 260)
                            } else {
                                ForEach(pets) { pet in
                                    let isExpanded = supportsCollapsibleCards
                                        ? expandedPetIDs.contains(pet.id)
                                        : true

                                    Group {
                                        if isExpanded {
                                            ExpandedPetCardContent(
                                                pet: pet,
                                                latestMessage: latestMessageByPet[pet.id],
                                                recentMessages: recentMessagesByPet[pet.id] ?? [],
                                                isLoadingMessage: isLoadingByPet[pet.id] ?? false,
                                                isBreathing: breatheByPet[pet.id] ?? false,
                                                contentWidth: contentWidth,
                                                recentPreviewLimit: recentPreviewLimit,
                                                heroNamespace: petCardHeroNamespace,
                                                showsCollapseControl: supportsCollapsibleCards,
                                                onToggleCardExpansion: {
                                                    toggleExpanded(for: pet.id)
                                                },
                                                onOpenChatRoom: {
                                                    appState.selectPet(pet)
                                                    selectedPetForChatRoom = pet
                                                    showChatRoom = true
                                                    AnalyticsService.capture(
                                                        AnalyticsEvent.chatOpened,
                                                        properties: ["pet_id": pet.id.uuidString]
                                                    )
                                                },
                                                onSpriteAppeared: { scheduleHeroBreathe(for: pet.id) }
                                            )
                                        } else {
                                            CollapsedPetCardContent(
                                                pet: pet,
                                                latestMessage: latestMessageByPet[pet.id],
                                                isLoadingMessage: isLoadingByPet[pet.id] ?? false,
                                                heroNamespace: petCardHeroNamespace
                                            ) {
                                                appState.selectPet(pet)
                                                toggleExpanded(for: pet.id)
                                            }
                                        }
                                    }
                                    .animation(
                                        supportsCollapsibleCards ? PetCardToggleAnimation.main : nil,
                                        value: isExpanded
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .padding(.horizontal, horizontalInset)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 12) + 12)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if pets.isEmpty {
                    PMSageCTAButton(title: "open settings") { showSettings = true }
                        .padding(.horizontal, 16)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 8) + 8)
                }
            }
        }
        .navigationDestination(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showAddPetOnboarding) {
            OnboardingCoordinator(context: .additionalPet {
                showAddPetOnboarding = false
            })
            .environmentObject(appState)
            .environment(\.petmojiPalette, PetmojiPalette.palette(for: appState.visualStyle))
            .preferredColorScheme(appState.visualStyle == .widgetGlass ? .dark : .light)
        }
        #if DEBUG
        .fullScreenCover(isPresented: $showPaywallDebug) {
            PaywallView(
                onUnlocked: { showPaywallDebug = false },
                allowsAutoUnlock: false
            )
            .environmentObject(appState)
            .environment(\.petmojiPalette, PetmojiPalette.palette(for: appState.visualStyle))
            .preferredColorScheme(appState.visualStyle == .widgetGlass ? .dark : .light)
        }
        #endif
        .navigationDestination(isPresented: $showChatRoom) {
            if let pet = selectedPetForChatRoom {
                PetChatRoomView(pet: pet)
            }
        }
        .task(id: pets.map(\.id)) {
            await loadMessagesForAllPets()
            reconcilePerPetState()
            reconcilePersistedExpansionWithAvailablePets()
            if !supportsCollapsibleCards, let petID = pets.first?.id {
                scheduleHeroBreathe(for: petID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .petMessageDelivered)) { notification in
            guard let raw = notification.userInfo?["pet_id"] as? String,
                  let petId = UUID(uuidString: raw),
                  let pet = pets.first(where: { $0.id == petId }) else { return }
            Task { await refreshMessagePreview(for: pet) }
        }
        .onChange(of: appState.pendingWidgetDeepLink) { _, link in
            guard case .openChat = link else { return }
            openDeepLinkedChat()
        }
        .onAppear {
            if case .openChat = appState.pendingWidgetDeepLink {
                openDeepLinkedChat()
            }
            presentResumeSecondPetPromptIfNeeded()
        }
        .alert(OnboardingResumePrompt.title(isSecondPet: true), isPresented: $showResumeSecondPetPrompt) {
            Button("Continue") {
                declinedResumeOnce = false
                showAddPetOnboarding = true
            }
            Button("Not now", role: .cancel) {
                handleResumeDeclined()
            }
        } message: {
            Text(OnboardingResumePrompt.message)
        }
        .alert("Add another pet?", isPresented: $showAddPetConfirm) {
            Button("Add pet") {
                showAddPetOnboarding = true
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Create a second pet with its own personality, sprites, and messages.")
        }
    }

    private func handleAddPetTapped() {
        guard appState.canAddPet else { return }
        if OnboardingDraftStore.hasPendingAdditionalPetDraft {
            showResumeSecondPetPrompt = true
        } else {
            showAddPetConfirm = true
        }
    }

    private func handleResumeDeclined() {
        if declinedResumeOnce {
            declinedResumeOnce = false
            Task { await abandonPendingAdditionalPetDraft() }
        } else {
            declinedResumeOnce = true
        }
    }

    @MainActor
    private func abandonPendingAdditionalPetDraft() async {
        await appState.abandonPendingOnboardingDraft()
    }

    private func presentResumeSecondPetPromptIfNeeded() {
        guard !didShowResumePrompt,
              OnboardingDraftStore.hasPendingAdditionalPetDraft else {
            return
        }
        didShowResumePrompt = true
        showResumeSecondPetPrompt = true
    }

    private func openDeepLinkedChat() {
        let deepLinkPetId: UUID?
        if case .openChat(let petId) = appState.pendingWidgetDeepLink {
            deepLinkPetId = petId
        } else {
            deepLinkPetId = nil
        }
        appState.pendingWidgetDeepLink = .none

        let selected = deepLinkPetId.flatMap { id in pets.first { $0.id == id } }
            ?? appState.widgetPet
            ?? pets.first

        if let selected {
            appState.selectPet(selected)
            setExpanded(true, for: selected.id)
            selectedPetForChatRoom = selected
            showChatRoom = true
            AnalyticsService.capture(
                AnalyticsEvent.chatOpened,
                properties: ["pet_id": selected.id.uuidString]
            )
        }
    }

    private func reconcilePerPetState() {
        let validIDs = Set(pets.map(\.id))
        latestMessageByPet = latestMessageByPet.filter { validIDs.contains($0.key) }
        recentMessagesByPet = recentMessagesByPet.filter { validIDs.contains($0.key) }
        isLoadingByPet = isLoadingByPet.filter { validIDs.contains($0.key) }
        breatheByPet = breatheByPet.filter { validIDs.contains($0.key) }
    }

    private func reconcilePersistedExpansionWithAvailablePets() {
        let validIDs = Set(pets.map(\.id))
        if pets.count == 1, let onlyPetID = pets.first?.id {
            persistExpandedIDs([onlyPetID])
            return
        }
        persistExpandedIDs(expandedPetIDs.intersection(validIDs))
    }

    private func toggleExpanded(for petID: UUID) {
        guard supportsCollapsibleCards else { return }
        setExpanded(!expandedPetIDs.contains(petID), for: petID)
    }

    /// One animation curve for both expand and collapse so the hero `matchedGeometryEffect` and layout stay symmetric.
    private func setExpanded(_ expanded: Bool, for petID: UUID, animated: Bool = true) {
        let apply = {
            var next = expandedPetIDs
            if expanded {
                next.insert(petID)
            } else {
                next.remove(petID)
                breatheByPet[petID] = false
                refreshMessagePreview(forPetID: petID)
            }
            persistExpandedIDs(next)
        }
        if animated {
            withAnimation(PetCardToggleAnimation.main, apply)
        } else {
            apply()
        }
    }

    /// Waits for the expand spring to mostly settle before starting breathe so expand matches the calmer collapse motion.
    private func scheduleHeroBreathe(for petID: UUID) {
        Task { @MainActor in
            if supportsCollapsibleCards {
                try? await Task.sleep(for: .seconds(0.45))
                guard expandedPetIDs.contains(petID) else { return }
            }
            breatheByPet[petID] = true
        }
    }

    private func persistExpandedIDs(_ ids: Set<UUID>) {
        expandedPetIDsRaw = ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    private func loadMessagesForAllPets() async {
        for pet in pets {
            await loadMessageData(for: pet)
        }
    }

    private func loadMessageData(for pet: Pet) async {
        isLoadingByPet[pet.id] = true
        defer { isLoadingByPet[pet.id] = false }
        await refreshMessagePreview(for: pet)
    }

    private func refreshMessagePreview(for pet: Pet) async {
        await ChatHistoryStore.mergeServerMessages(for: pet.id)

        let history = ChatHistoryStore.loadHistory(for: pet.id)
        if !history.isEmpty {
            recentMessagesByPet[pet.id] = Array(history.suffix(8))
        }

        if let fetchedLatest = try? await SupabaseService.shared.fetchLatestMessage(for: pet.id) {
            ChatHistoryStore.appendPetMessage(fetchedLatest)
            latestMessageByPet[pet.id] = fetchedLatest
            let refreshedHistory = ChatHistoryStore.loadHistory(for: pet.id)
            recentMessagesByPet[pet.id] = Array(refreshedHistory.suffix(8))
        } else if let latestPetChat = history.last(where: { $0.isFromPet }) {
            latestMessageByPet[pet.id] = petMessage(from: latestPetChat, petId: pet.id)
        }

        if let message = latestMessageByPet[pet.id], pet.id == appState.widgetPet?.id {
            WidgetSnapshotSync.writeFromPet(pet, message: message)
        }
    }

    private func refreshMessagePreview(forPetID petID: UUID) {
        guard let pet = pets.first(where: { $0.id == petID }) else { return }
        Task { await refreshMessagePreview(for: pet) }
    }

    private func petMessage(from chat: ChatMessage, petId: UUID) -> PetMessage {
        PetMessage(
            id: chat.id,
            petId: petId,
            content: chat.content,
            expression: chat.expression ?? .happy,
            triggerType: .chatReply,
            scheduledFor: chat.timestamp,
            sentAt: chat.timestamp
        )
    }
}

private struct HomeChromeIconButton: View {
    @Environment(\.petmojiPalette) private var palette

    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(palette.iconTint)
                .frame(width: 56, height: 56)
                .background(palette.chromeButtonFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(palette.chromeButtonStroke, lineWidth: 1.25)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct HomeHeader: View {
    @Environment(\.petmojiPalette) private var palette

    let greeting: String
    let petCount: Int
    let canAddPet: Bool
    let onAddPet: () -> Void
    let onShowSettings: () -> Void
    var onShowPaywallDebug: (() -> Void)? = nil

    private var checkInText: String {
        if petCount == 1 {
            return "your pet is checking in"
        }
        return "your pets are checking in"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.titleL.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(checkInText)
                    .font(.bodyM)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                #if DEBUG
                if let onShowPaywallDebug {
                    HomeChromeIconButton(
                        systemName: "creditcard.fill",
                        accessibilityLabel: "debug paywall",
                        action: onShowPaywallDebug
                    )
                }
                #endif
                if canAddPet {
                    HomeChromeIconButton(
                        systemName: "plus",
                        accessibilityLabel: "add another pet",
                        action: onAddPet
                    )
                }
                HomeChromeIconButton(
                    systemName: "gearshape.fill",
                    accessibilityLabel: "settings",
                    action: onShowSettings
                )
            }
        }
    }
}

// MARK: - Hero sprite (shared matched-geometry source for expand/collapse)

private struct PetCardHeroSprite: View {
    @Environment(\.petmojiPalette) private var palette

    let urlString: String?
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let heroGeometryID: String
    let heroNamespace: Namespace.ID
    var isBreathing: Bool = false
    var showsCircleStroke: Bool = false

    private let breatheScale: CGFloat = 0.985

    var body: some View {
        SpriteImageView(urlString: urlString, contentMode: .fit)
            .scaleEffect(isBreathing ? breatheScale : 1.0)
            .animation(
                isBreathing ? .easeInOut(duration: 2.5).repeatForever(autoreverses: true) : nil,
                value: isBreathing
            )
            .frame(width: width, height: height)
            .geometryGroup()
            .matchedGeometryEffect(id: heroGeometryID, in: heroNamespace, properties: .frame)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if showsCircleStroke {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(palette.border.opacity(0.85), lineWidth: 1.25)
                }
            }
    }
}

private struct CollapsedPetCardContent: View {
    @Environment(\.petmojiPalette) private var palette

    let pet: Pet
    let latestMessage: PetMessage?
    let isLoadingMessage: Bool
    let heroNamespace: Namespace.ID
    let onTap: () -> Void

    private var expression: PetExpression { latestMessage?.expression ?? .happy }
    private var spriteURL: String? { pet.expressions[expression] ?? pet.expressions[.happy] }
    private var heroGeometryID: String { "petCardHero-\(pet.id.uuidString)" }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PetCardHeroSprite(
                    urlString: spriteURL,
                    width: 84,
                    height: 84,
                    cornerRadius: 42,
                    heroGeometryID: heroGeometryID,
                    heroNamespace: heroNamespace,
                    showsCircleStroke: true
                )
                .padding(2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(pet.name).font(.bodyL).foregroundStyle(palette.textPrimary).lineLimit(1)
                        HomeStatusChip(icon: "heart.fill", title: expression.displayName)
                    }

                    if isLoadingMessage && latestMessage == nil {
                        Text("checking in...").font(.bodyM).foregroundStyle(palette.textSecondary).lineLimit(1)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            if latestMessage != nil {
                                Image(systemName: "pawprint.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.iconTint)
                                    .frame(width: 24, height: 24)
                                    .padding(.top, 2)
                            }
                            Text(latestMessage?.content ?? "tap to open \(pet.name)'s full view")
                                .font(.bodyM)
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }

                Spacer(minLength: 6)
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(palette.accentDark)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand \(pet.name)")
    }
}

private struct ExpandedPetCardContent: View {
    @Environment(\.petmojiPalette) private var palette

    let pet: Pet
    let latestMessage: PetMessage?
    let recentMessages: [ChatMessage]
    let isLoadingMessage: Bool
    let isBreathing: Bool
    let contentWidth: CGFloat
    let recentPreviewLimit: Int
    let heroNamespace: Namespace.ID
    var showsCollapseControl: Bool = true
    let onToggleCardExpansion: () -> Void
    let onOpenChatRoom: () -> Void
    let onSpriteAppeared: () -> Void

    private var expression: PetExpression { latestMessage?.expression ?? .happy }
    private var spriteURL: String? { pet.expressions[expression] ?? pet.expressions[.happy] }
    private var heroGeometryID: String { "petCardHero-\(pet.id.uuidString)" }

    private var recentMessagesPanelFill: Color { palette.elevatedCardFill }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(pet.name).font(.titleL).foregroundStyle(palette.textPrimary).lineLimit(1)
                Spacer()
                if showsCollapseControl {
                    Button(action: onToggleCardExpansion) {
                        Label("Collapse", systemImage: "chevron.up").font(.bodyS).foregroundStyle(palette.accentDark)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(action: onOpenChatRoom) {
                VStack(spacing: 14) {
                    let spriteSize = max(170, contentWidth - 56)

                    PetCardHeroSprite(
                        urlString: spriteURL,
                        width: spriteSize,
                        height: spriteSize,
                        cornerRadius: 28,
                        heroGeometryID: heroGeometryID,
                        heroNamespace: heroNamespace,
                        isBreathing: isBreathing
                    )
                    .onAppear(perform: onSpriteAppeared)
                    .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                    HStack(spacing: 10) {
                        HomeStatusChip(icon: "heart.fill", title: expression.displayName)
                        HomeStatusChip(icon: "bolt.fill", title: "Active")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            .buttonStyle(.plain)

            Button(action: onOpenChatRoom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recent messages")
                            .font(.bodyL)
                            .foregroundStyle(palette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.accentDark)
                    }
                    .padding(.horizontal, 6)

                    if recentMessages.isEmpty && isLoadingMessage {
                        TypingIndicator()
                    } else if recentMessages.isEmpty {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(palette.visualStyle == .widgetGlass ? palette.homeInsetFill : palette.elevatedCardFill)
                            .overlay(
                                Text("start chatting with your pet")
                                    .font(.bodyM)
                                    .foregroundStyle(palette.textSecondary)
                                    .padding(.horizontal, 14)
                            )
                            .frame(height: 64)
                    } else {
                        ForEach(recentMessages.suffix(recentPreviewLimit)) { message in
                            HomePreviewBubble(message: message)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(recentMessagesPanelFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(palette.border.opacity(0.8), lineWidth: 1.2)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onOpenChatRoom) {
                Text("chat with \(pet.name.lowercased())")
                    .font(.buttonFont)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.pmSageAccentDark, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(palette.border.opacity(0.6), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }
}

private struct PetChatRoomView: View {
    let pet: Pet

    var body: some View {
        ChatPanel(pet: pet)
            .navigationTitle("Chat with \(pet.name)")
            .navigationBarTitleDisplayMode(.inline)
            .pmSageScreenBackground()
    }
}

struct HomeStatusChip: View {
    @Environment(\.petmojiPalette) private var palette

    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(title.lowercased()).font(.bodyS).lineLimit(1)
        }
        .foregroundStyle(palette.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.visualStyle == .classic ? Color.white.opacity(0.9) : palette.elevatedCardFill, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.border.opacity(0.8), lineWidth: 1))
    }
}

struct HomePreviewBubble: View {
    @Environment(\.petmojiPalette) private var palette

    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isFromPet {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.iconTint)
                    .frame(width: 24, height: 24)
                Text(message.content)
                    .font(.bodyM)
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(palette.bubblePetBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Text(message.content)
                    .font(.bodyM)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.pmSageAccentDark, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct TypingIndicator: View {
    @Environment(\.petmojiPalette) private var palette

    @State private var animating = false
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(palette.typingDot)
                    .frame(width: 8, height: 8)
                    .opacity(animating ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.18), value: animating)
            }
        }
        .padding(16)
        .background(palette.chromeButtonFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(palette.border, lineWidth: 1.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animating = true }
    }
}
