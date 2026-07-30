import SwiftUI

// MARK: - Home Location Setup View

struct HomeLocationSetupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.petmojiPalette) private var palette
    @ObservedObject private var locationService = LocationService.shared

    var pet: Pet?
    let onDone: () -> Void
    var onCancel: (() -> Void)?

    @State private var isSettingUp = false
    @State private var homeSaved = false
    @State private var skippedHome = false
    @State private var homeError: String?
    @State private var showAddressSheet = false
    @State private var isSavingHome = false
    @State private var titleHeight: CGFloat = 0

    private var resolvedPet: Pet? {
        pet ?? appState.currentPet ?? appState.availablePets.first
    }

    private func demoMaxHeight(in availableHeight: CGFloat) -> CGFloat {
        let subtextAndTop: CGFloat = 48
        return max(140, availableHeight - subtextAndTop - 8)
    }

    var body: some View {
        ZStack {
            PMSageScreenBackdrop()

            GeometryReader { geo in
                let contentWidth = geo.size.width - 48
                let demoMaxHeight = demoMaxHeight(in: geo.size.height)

                VStack(alignment: .leading, spacing: 8) {
                    Spacer(minLength: 0)

                    Text("want me to message when you leave home?")
                        .font(.titleL)
                        .foregroundStyle(palette.accentDark)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .background(
                            GeometryReader { titleGeo in
                                Color.clear
                                    .preference(key: TitleHeightKey.self, value: titleGeo.size.height)
                            }
                        )

                    Text("turn on location and notifications for the best experience")
                        .font(.bodyS)
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 20)

                    LocationNotificationDemoMockup(
                        petName: resolvedPet?.name ?? "Mochi",
                        maxWidth: contentWidth,
                        maxHeight: demoMaxHeight
                    )

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .offset(y: -((titleHeight + 8) / 2))
                .onPreferenceChange(TitleHeightKey.self) { titleHeight = $0 }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            VStack(spacing: 8) {
                if let homeError {
                    Text(homeError)
                        .font(.bodyS)
                        .foregroundStyle(.red.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }

                LocationTrackingPrimaryButton(
                    title: locationButtonTitle,
                    subtitle: locationButtonSubtitle,
                    isLoading: isSettingUp || isSavingHome,
                    isEnabled: !homeSaved,
                    action: enableLocationTracking
                )
                .disabled(isSettingUp || isSavingHome || resolvedPet == nil || homeSaved)

                Button("Skip for now") {
                    skippedHome = true
                    homeError = nil
                    onDone()
                }
                .font(.bodyM)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity)
                .disabled(isSettingUp || isSavingHome)

                if let onCancel {
                    PMOnboardingCancelButton(action: onCancel)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
            .background(Color.clear)
        }
        .pmOnboardingScreenTitle("", titleTopPadding: 0)
        .sheet(isPresented: $showAddressSheet) {
            HomeAddressSearchSheet(
                petName: resolvedPet?.name ?? "your pet",
                initialAddress: resolvedPet?.homeAddress
            ) { resolved in
                if let resolvedPet {
                    saveResolvedHome(resolved, for: resolvedPet)
                }
            }
        }
    }

    private var locationButtonTitle: String {
        if isSettingUp { return "setting up location…" }
        if isSavingHome { return "saving home…" }
        if homeSaved { return "home location saved" }
        return "turn on location tracking"
    }

    private var locationButtonSubtitle: String? {
        guard homeSaved else { return nil }
        return "update home in Settings anytime"
    }

    private func enableLocationTracking() {
        guard let resolvedPet else {
            homeError = "Create your pet first, then set home."
            return
        }
        homeError = nil
        isSettingUp = true
        Task {
            defer { isSettingUp = false }
            do {
                try await locationService.requestOnboardingLocationThenNotifications()

                let status = locationService.authorizationStatus
                guard status == .authorizedWhenInUse || status == .authorizedAlways else {
                    homeError = HomeLocationError.permissionDenied.errorDescription
                    return
                }

                // Permission granted — turn tracking on, then ask for an explicit home address.
                locationService.setLocationTrackingEnabled(true)
                AnalyticsService.capture(AnalyticsEvent.locationTrackingEnabled)
                showAddressSheet = true
            } catch let error as HomeLocationError {
                homeError = error.errorDescription
            } catch {
                homeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func saveResolvedHome(_ resolved: ResolvedHomeAddress, for pet: Pet) {
        homeError = nil
        isSavingHome = true
        Task {
            defer { isSavingHome = false }
            do {
                try await locationService.saveResolvedHome(
                    petId: pet.id,
                    petName: pet.name,
                    address: resolved.displayAddress,
                    lat: resolved.latitude,
                    lng: resolved.longitude,
                    requestPermissions: false
                ) { lat, lng, address in
                    appState.updatePetHome(petId: pet.id, lat: lat, lng: lng, address: address)
                }
                homeSaved = true
                homeError = nil
                try? await Task.sleep(nanoseconds: 500_000_000)
                onDone()
            } catch let error as HomeLocationError {
                homeError = error.errorDescription
            } catch {
                homeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Title height measurement

private struct TitleHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Primary Button

private struct LocationTrackingPrimaryButton: View {
    @Environment(\.petmojiPalette) private var palette

    let title: String
    let subtitle: String?
    let isLoading: Bool
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.buttonFont)
                        .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.9))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.bodyS)
                        .foregroundStyle(.white.opacity(isEnabled ? 0.85 : 0.75))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                Capsule(style: .continuous)
                    .fill(isEnabled ? palette.accent : palette.accent.opacity(0.55))
            )
            .shadow(
                color: isEnabled
                    ? palette.accentDark.opacity(palette.visualStyle == .widgetGlass ? 0.45 : 0.28)
                    : .clear,
                radius: 10,
                x: 0,
                y: 6
            )
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isEnabled && !isLoading)
    }
}
