import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.petmojiPalette) private var palette

    @State private var petName: String = ""
    @State private var committedPetName: String = ""
    @State private var pendingPetName: String = ""
    @State private var showRenamePetConfirm = false
    @State private var isSavingPetName = false
    @State private var petNameError: String?
    @FocusState private var isPetNameFocused: Bool
    @State private var notificationsEnabled = UserDefaults.standard.object(forKey: "notifications_enabled") as? Bool ?? true
    @State private var isRegenerating = false
    @State private var regenerateError: String?
    @State private var regenerateSuccess = false
    @State private var showRegenerateConfirm = false
    @State private var showDeletePetConfirm = false
    @State private var isDeletingPet = false
    @State private var deletePetError: String?
    @State private var showDeleteAccountConfirm = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?
    @State private var showSignOutConfirm = false
    @State private var showWidgetInstructions = false
    @State private var showHomeAddressSheet = false
    @State private var isUpdatingHome = false
    @State private var homeLocationError: String?
    @ObservedObject private var locationService = LocationService.shared

    private var pet: Pet? { appState.currentPet }

    private var settingsPetSelection: Binding<UUID> {
        Binding(
            get: { appState.currentPet?.id ?? appState.pets.first?.id ?? UUID() },
            set: { id in
                guard let selected = appState.pets.first(where: { $0.id == id }) else { return }
                appState.selectPet(selected)
                committedPetName = selected.name
                petName = selected.name
                petNameError = nil
            }
        )
    }

    private var widgetPetSelection: Binding<UUID> {
        Binding(
            get: { appState.widgetPetId ?? appState.pets.first?.id ?? UUID() },
            set: { id in
                guard let selected = appState.pets.first(where: { $0.id == id }) else { return }
                appState.setWidgetPet(selected)
            }
        )
    }

    private func spriteThumbLoading(_ expression: PetExpression, pet: Pet) -> Bool {
        pet.expressions[expression] == nil && appState.expressionSyncPetId == pet.id
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        ZStack {
            PMSageScreenBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if appState.hasCompletedSignUp {
                        Picker("Settings section", selection: Binding(
                            get: { appState.settingsPersona },
                            set: { appState.setSettingsPersona($0) }
                        )) {
                            ForEach(SettingsPersona.allCases) { persona in
                                Text(persona.segmentTitle).tag(persona)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Settings section")

                        if appState.settingsPersona == .user {
                            userSettingsContent
                        } else {
                            petSettingsContent
                        }
                    }

                    Text("petmoji \(appVersion)")
                        .font(.bodyS)
                        .foregroundStyle(palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(palette.accentDark)
        .onAppear {
            syncPetNameFieldsFromCurrentPet()
            Task {
                await appState.refreshProfileIfNeeded()
                if let profile = try? await SupabaseService.shared.fetchProfile() {
                    notificationsEnabled = profile.notificationsEnabled
                    UserDefaults.standard.set(profile.notificationsEnabled, forKey: "notifications_enabled")
                }
            }
        }
        .onChange(of: appState.currentPet?.id) { _, _ in
            syncPetNameFieldsFromCurrentPet()
        }
        .alert("Delete \(pet?.name ?? "this pet")?", isPresented: $showDeletePetConfirm) {
            Button("Delete", role: .destructive) {
                Task { await deleteSelectedPet() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the pet and its chat history. This can't be undone.")
        }
        .alert("Delete your account?", isPresented: $showDeleteAccountConfirm) {
            Button("Delete Account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure? All of your pets, messages, photos, and profile data will be permanently deleted. This can't be undone.")
        }
        .alert("Change pet name?", isPresented: $showRenamePetConfirm) {
            Button("Change name") {
                Task { await applyPetNameChange() }
            }
            Button("Cancel", role: .cancel) {
                petName = committedPetName
            }
        } message: {
            Text("Change \(committedPetName)'s name to \(pendingPetName)?")
        }
        .sheet(isPresented: $showHomeAddressSheet) {
            HomeAddressSearchSheet(
                petName: pet?.name ?? "your pet",
                initialAddress: pet?.homeAddress
            ) { resolved in
                saveResolvedHome(resolved)
            }
        }
        .alert("Regenerate sprites?", isPresented: $showRegenerateConfirm) {
            Button("Regenerate") {
                isRegenerating = true
                regenerateError = nil
                regenerateSuccess = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This re-runs AI on your saved photos (about 30 seconds). Your current sprites will be replaced.")
        }
        .sheet(isPresented: $isRegenerating) {
            RegeneratingModal(
                isPresented: $isRegenerating,
                error: $regenerateError,
                success: $regenerateSuccess,
                pet: pet
            )
            .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $showWidgetInstructions) {
            NavigationStack {
                WidgetSetupView(
                    onNext: { showWidgetInstructions = false },
                    ctaTitle: "got it",
                    subtitle: nil
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showWidgetInstructions = false }
                            .font(.bodyM)
                            .tint(palette.accentDark)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var userSettingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSageSection(
                title: "account",
                footer: "Dark Mode uses the same dark glass look as your home screen widgets."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    ClassicDarkModeToggleRow()

                    AccountInfoRow(
                        label: "full name",
                        value: appState.userDisplayName
                    )
                    AccountInfoRow(
                        label: "email",
                        value: appState.userEmail
                    )

                    LocationTrackingToggleRow(onEnable: handleLocationTrackingEnabled)

                    if !locationService.isLocationTrackingEnabled {
                        Text("Your pet won't react when you leave home while this is off.")
                            .font(.bodyS)
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if locationService.needsAlwaysForLeaveHomeAlerts {
                        Text("Choose Always Allow for location so your pet can react when you leave home in the background.")
                            .font(.bodyS)
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !locationService.hasHomeLocation, appState.currentPet?.homeLat == nil {
                        Text("Set your home in the Pet tab so leave-home messages can work.")
                            .font(.bodyS)
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SignOutPillButton(showConfirm: $showSignOutConfirm) {
                Task { await appState.signOut() }
            }

            SettingsSageSection(title: "danger zone", titleColor: .red) {
                Button("delete account", role: .destructive) {
                    showDeleteAccountConfirm = true
                }
                .font(.bodyL)
                .disabled(isDeletingAccount)

                if let deleteAccountError {
                    Text(deleteAccountError)
                        .font(.bodyS)
                        .foregroundStyle(.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var petSettingsContent: some View {
        SettingsSageSection(
            title: "pet profile",
            footer: "Press return to save. You'll be asked to confirm before the name changes."
        ) {
            if appState.pets.count > 1 {
                Picker("Pet profile", selection: settingsPetSelection) {
                    ForEach(appState.pets) { listedPet in
                        Text(listedPet.name).tag(listedPet.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, 12)
                .accessibilityLabel("Pet profile")
            }

            HStack(spacing: 16) {
                SpriteImageView(urlString: pet?.expressions[.happy])
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
                    .overlay(
                        Circle().strokeBorder(palette.border.opacity(0.85), lineWidth: 1.25)
                    )

                VStack(alignment: .leading, spacing: 8) {
                    TextField("pet name", text: $petName)
                        .font(.bodyL)
                        .foregroundStyle(palette.textPrimary)
                        .focused($isPetNameFocused)
                        .submitLabel(.done)
                        .disabled(isSavingPetName)
                        .onSubmit { requestPetNameChange() }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(palette.chromeButtonFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(palette.border, lineWidth: 1.5)
                        )

                    if let pet {
                        Text(pet.species.displayName)
                            .font(.bodyS)
                            .foregroundStyle(palette.textSecondary)
                    }

                    if let petNameError {
                        Text(petNameError)
                            .font(.bodyS)
                            .foregroundStyle(.red.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        SettingsSageSection(
            title: "home screen widget",
            footer: appState.pets.count > 1
                ? "Choose which pet appears on your home screen widget, or add a new widget."
                : "Add the Petmoji widget to your home screen to see your pet's latest message at a glance."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if appState.pets.count > 1 {
                    Picker("Widget pet", selection: widgetPetSelection) {
                        ForEach(appState.pets) { listedPet in
                            Text(listedPet.name).tag(listedPet.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Home screen widget pet")

                    Divider().overlay(palette.border.opacity(0.6))
                }

                Button {
                    showWidgetInstructions = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.square.on.square")
                        Text("add widget to home screen")
                    }
                    .font(.bodyL)
                    .foregroundStyle(palette.accentDark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Add widget to home screen")
                .accessibilityHint("Opens step-by-step instructions for adding the home screen widget")
            }
        }

        SettingsSageSection(
            title: "location",
            footer: !locationService.isLocationTrackingEnabled
                ? "Turn on location tracking in the User tab to enable leave-home messages."
                : (locationService.needsAlwaysForLeaveHomeAlerts
                    ? "Choose Always Allow for location so your pet can react when you leave home in the background."
                    : nil)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !locationService.isLocationTrackingEnabled {
                    Text("Location tracking is off.")
                        .font(.bodyM)
                        .foregroundStyle(palette.textSecondary)
                } else if let address = pet?.homeAddress, !address.isEmpty {
                    Text(address)
                        .font(.bodyM)
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if pet?.homeLat != nil, pet?.homeLng != nil {
                    Text("Home is set for leave-home messages.")
                        .font(.bodyM)
                        .foregroundStyle(palette.textSecondary)
                } else {
                    Text("Home isn't set yet. Your pet can't react when you leave.")
                        .font(.bodyM)
                        .foregroundStyle(palette.textSecondary)
                }

                Button {
                    showHomeAddressSheet = true
                } label: {
                    Text(isUpdatingHome ? "updating home…" : "update home location")
                        .font(.bodyL)
                        .foregroundStyle(palette.accentDark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isUpdatingHome || pet == nil || !locationService.isLocationTrackingEnabled)

                if let homeLocationError {
                    Text(homeLocationError)
                        .font(.bodyS)
                        .foregroundStyle(.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        SettingsSageSection(
            title: "notifications",
            footer: "When on, your pet sends occasional check-in messages throughout the day as push notifications. New messages also show up in chat and on your home screen."
        ) {
            Toggle("scheduled messages", isOn: $notificationsEnabled)
                .font(.bodyM)
                .foregroundStyle(palette.textPrimary)
                .tint(palette.accent)
                .onChange(of: notificationsEnabled) { _, enabled in
                    UserDefaults.standard.set(enabled, forKey: "notifications_enabled")
                    Task {
                        try? await SupabaseService.shared.updateNotificationsEnabled(enabled)
                    }
                }
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("sprites")
                .font(.titleL)
                .foregroundStyle(palette.accentDark)

            VStack(spacing: 12) {
                Group {
                    if let pet {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8),
                            ],
                            alignment: .center,
                            spacing: 8
                        ) {
                            ForEach(PetExpression.allCases, id: \.self) { expression in
                                ExpressionThumbnail(
                                    expression: expression,
                                    urlString: pet.expressions[expression],
                                    isSelected: false,
                                    size: 52,
                                    isLoading: spriteThumbLoading(expression, pet: pet),
                                    interactive: false,
                                    action: {}
                                )
                                .frame(maxWidth: .infinity)
                            }
                        }
                    } else {
                        Text("no pet loaded")
                            .font(.bodyM)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .settingsSageInsetCard()

                VStack(alignment: .leading, spacing: 12) {
                    Button("regenerate sprites") {
                        showRegenerateConfirm = true
                    }
                    .font(.bodyL)
                    .foregroundStyle(palette.accentDark)

                    if let error = regenerateError {
                        Text(error)
                            .font(.bodyS)
                            .foregroundStyle(.red.opacity(0.9))
                    }
                    if regenerateSuccess {
                        Label("sprites regenerated!", systemImage: "checkmark.circle.fill")
                            .font(.bodyM)
                            .foregroundStyle(palette.accentDark)
                    }
                }
                .settingsSageInsetCard()
            }

            Text("re-runs AI sprite generation from your original photos.")
                .font(.bodyS)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        }

        SettingsSageSection(title: "danger zone", titleColor: .red) {
            Button("delete pet", role: .destructive) {
                showDeletePetConfirm = true
            }
            .font(.bodyL)
            .disabled(pet == nil || isDeletingPet)

            if let deletePetError {
                Text(deletePetError)
                    .font(.bodyS)
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func syncPetNameFieldsFromCurrentPet() {
        let name = pet?.name ?? ""
        committedPetName = name
        petName = name
        petNameError = nil
    }

    private func requestPetNameChange() {
        let trimmed = petName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            petName = committedPetName
            petNameError = "Enter a name first."
            return
        }
        guard trimmed != committedPetName else {
            isPetNameFocused = false
            return
        }
        petNameError = nil
        pendingPetName = trimmed
        isPetNameFocused = false
        showRenamePetConfirm = true
    }

    @MainActor
    private func applyPetNameChange() async {
        guard let pet else { return }
        let trimmed = pendingPetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            petName = committedPetName
            return
        }

        isSavingPetName = true
        petNameError = nil
        defer { isSavingPetName = false }

        do {
            try await SupabaseService.shared.updatePetName(petId: pet.id, name: trimmed)
            var updated = pet
            updated.name = trimmed
            appState.setPet(updated)
            if appState.widgetPetId == pet.id {
                MessageScheduler.shared.savePetMetadata(name: trimmed, petId: pet.id.uuidString)
                await appState.syncWidgetSnapshot()
            }
            committedPetName = trimmed
            petName = trimmed
        } catch {
            petName = committedPetName
            petNameError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Right after location tracking is switched on (off → on), prompt for an explicit home address.
    /// Declining (dismissing the sheet) is fine; they can set it later via "update home location".
    private func handleLocationTrackingEnabled() {
        guard pet != nil else { return }
        showHomeAddressSheet = true
    }

    private func saveResolvedHome(_ resolved: ResolvedHomeAddress) {
        guard let pet else {
            homeLocationError = "No pet loaded."
            return
        }
        homeLocationError = nil
        isUpdatingHome = true
        Task {
            defer { isUpdatingHome = false }
            do {
                try await locationService.saveResolvedHome(
                    petId: pet.id,
                    petName: pet.name,
                    address: resolved.displayAddress,
                    lat: resolved.latitude,
                    lng: resolved.longitude
                ) { lat, lng, address in
                    appState.updateCurrentPetHome(lat: lat, lng: lng, address: address)
                }
            } catch {
                homeLocationError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    @MainActor
    private func deleteSelectedPet() async {
        guard let pet else { return }
        isDeletingPet = true
        deletePetError = nil
        await appState.deletePet(pet)
        syncPetNameFieldsFromCurrentPet()
        isDeletingPet = false
    }

    @MainActor
    private func deleteAccount() async {
        isDeletingAccount = true
        deleteAccountError = nil
        do {
            try await appState.deleteAccount()
        } catch {
            deleteAccountError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isDeletingAccount = false
    }
}

// MARK: - Location tracking toggle

private struct LocationTrackingToggleRow: View {
    @ObservedObject private var locationService = LocationService.shared
    @Environment(\.petmojiPalette) private var palette

    /// Called when the user switches tracking from off → on.
    var onEnable: () -> Void = {}

    var body: some View {
        HStack(alignment: .center) {
            Text("Location tracking")
                .font(.bodyM)
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { locationService.isLocationTrackingEnabled },
                set: { enabled in
                    locationService.setLocationTrackingEnabled(enabled)
                    if enabled { onEnable() }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Location tracking")
        .accessibilityValue(locationService.isLocationTrackingEnabled ? "On" : "Off")
    }
}

// MARK: - Dark Mode (system-style switch)

private struct ClassicDarkModeToggleRow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.petmojiPalette) private var palette

    var body: some View {
        HStack(alignment: .center) {
            Text("Dark Mode")
                .font(.bodyM)
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { appState.isDarkModeEnabled },
                set: { appState.setDarkModeEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dark Mode")
        .accessibilityValue(appState.isDarkModeEnabled ? "On" : "Off")
    }
}

// MARK: - Sign out

private struct SignOutPillButton: View {
    @Environment(\.petmojiPalette) private var palette

    @Binding var showConfirm: Bool
    let onSignOut: () -> Void

    var body: some View {
        Button {
            showConfirm = true
        } label: {
            Text("sign out")
                .font(.bodyL)
                .foregroundStyle(palette.accentDark)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(palette.elevatedCardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(palette.elevatedCardStroke, lineWidth: 1.2)
                )
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(SettingsPillButtonStyle())
        .accessibilityLabel("Sign out")
        .accessibilityHint("Opens a confirmation before signing out")
        .popover(
            isPresented: $showConfirm,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            SignOutConfirmPopover(
                isPresented: $showConfirm,
                onSignOut: onSignOut
            )
        }
    }
}

/// Full-pill press feedback for settings action buttons.
private struct SettingsPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct AccountInfoRow: View {
    @Environment(\.petmojiPalette) private var palette

    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.bodyS)
                .foregroundStyle(palette.textSecondary)
            Text(value.trimmingCharacters(in: .whitespaces).isEmpty ? "—" : value)
                .font(.bodyL)
                .foregroundStyle(palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SignOutConfirmPopover: View {
    @Environment(\.petmojiPalette) private var palette

    @Binding var isPresented: Bool
    let onSignOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign out?")
                .font(.titleL)
                .foregroundStyle(palette.accentDark)
            Text("You'll return to sign in. Your pet and profile stay saved on your account.")
                .font(.bodyM)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.bordered)
                    .tint(palette.accentDark)
                Button("Sign Out", role: .destructive) {
                    isPresented = false
                    onSignOut()
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - Settings inset card (matches `SettingsSageSection` inner chrome)

private struct SettingsSageInsetCardModifier: ViewModifier {
    @Environment(\.petmojiPalette) private var palette

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(palette.elevatedCardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(palette.elevatedCardStroke, lineWidth: 1.2)
            )
    }
}

private extension View {
    func settingsSageInsetCard() -> some View {
        modifier(SettingsSageInsetCardModifier())
    }
}

// MARK: - Sage section (matches home pet cards)

private struct SettingsSageSection<Content: View>: View {
    @Environment(\.petmojiPalette) private var palette

    let title: String
    var footer: String?
    var titleColor: Color?
    @ViewBuilder var content: () -> Content

    init(title: String, footer: String? = nil, titleColor: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.titleColor = titleColor
        self.content = content
    }

    private var resolvedTitleColor: Color {
        titleColor ?? palette.accentDark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.titleL)
                .foregroundStyle(resolvedTitleColor)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(palette.elevatedCardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(palette.elevatedCardStroke, lineWidth: 1.2)
                )

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.bodyS)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }
}

// MARK: - Regenerating Modal

struct RegeneratingModal: View {
    @Environment(\.petmojiPalette) private var palette

    @Binding var isPresented: Bool
    @Binding var error: String?
    @Binding var success: Bool
    let pet: Pet?

    @EnvironmentObject var appState: AppState
    @State private var phase: Phase = .working
    @State private var rotation: Double = 0

    enum Phase { case working, done, failed(String) }

    var body: some View {
        ZStack {
            PMSageScreenBackdrop()

            VStack(spacing: 32) {
                Spacer()

                switch phase {
                case .working:
                    VStack(spacing: 20) {
                        Text("✨")
                            .font(.system(size: 72))
                            .rotationEffect(.degrees(rotation))
                            .onAppear {
                                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                                    rotation = 360
                                }
                            }

                        Text("regenerating sprites...")
                            .font(.titleL)
                            .foregroundStyle(palette.textPrimary)

                        Text("keep the app open — this takes about 30 seconds")
                            .font(.bodyM)
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                case .done:
                    VStack(spacing: 16) {
                        Text("🎉")
                            .font(.system(size: 72))

                        Text("new sprite ready!")
                            .font(.titleL)
                            .foregroundStyle(palette.textPrimary)

                        Text("the rest will fill in over the next minute — you can close this.")
                            .font(.bodyM)
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                case .failed(let msg):
                    VStack(spacing: 16) {
                        Text("😬")
                            .font(.system(size: 72))

                        Text("something went wrong")
                            .font(.titleL)
                            .foregroundStyle(palette.textPrimary)

                        Text(msg)
                            .font(.bodyM)
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }

                Spacer()

                if case .working = phase {
                    EmptyView()
                } else {
                    PMPrimaryButton(title: "done") {
                        isPresented = false
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            Task { await runRegeneration() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func runRegeneration() async {
        guard let pet = pet ?? appState.currentPet else {
            phase = .failed("no pet found")
            return
        }

        do {
            let photoURLs = try await SupabaseService.shared.getStoredPhotoURLs(petId: pet.id)
            guard !photoURLs.isEmpty else {
                phase = .failed("no photos found for this pet")
                return
            }
            let initialExpressions = try await SupabaseService.shared.generateSprites(
                petId: pet.id,
                photoURLs: photoURLs,
                petName: pet.name == "unnamed" ? "" : pet.name,
                species: pet.species
            )
            await MainActor.run {
                if var updated = appState.currentPet {
                    updated.expressions = initialExpressions
                    appState.setPet(updated)
                }
                appState.startSyncingExpressions(petId: pet.id)
                success = true
                phase = .done
                AnalyticsService.capture(
                    AnalyticsEvent.spritesGenerated,
                    properties: [
                        "source": "settings",
                        "pet_id": pet.id.uuidString,
                    ]
                )
            }
        } catch {
            await MainActor.run {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
