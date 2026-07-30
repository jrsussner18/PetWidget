import SwiftUI
import MapKit
import CoreLocation

// MARK: - Resolved home selection

struct ResolvedHomeAddress: Equatable {
    let displayAddress: String
    let latitude: Double
    let longitude: Double
}

// MARK: - Address search sheet

struct HomeAddressSearchSheet: View {
    @Environment(\.petmojiPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    let petName: String
    var initialAddress: String?
    let onConfirm: (ResolvedHomeAddress) -> Void

    @StateObject private var searchModel = HomeAddressSearchModel()
    @State private var query = ""
    @State private var selected: ResolvedHomeAddress?
    @State private var isResolving = false
    @State private var isPrefilling = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                PMSageScreenBackdrop()

                VStack(alignment: .leading, spacing: 16) {
                    Text("set \(petName)'s home address")
                        .font(.titleL)
                        .foregroundStyle(palette.accentDark)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("search for the home address — not wherever you are right now. you can use current location as a starting point if you want.")
                        .font(.bodyS)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("search address…", text: $query)
                        .font(.bodyL)
                        .foregroundStyle(palette.textPrimary)
                        .textContentType(.fullStreetAddress)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .tint(palette.accent)
                        .padding(16)
                        .background(palette.chromeButtonFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(palette.border, lineWidth: 1.5)
                        )
                        .onChange(of: query) { _, newValue in
                            if selected?.displayAddress != newValue {
                                selected = nil
                            }
                            errorMessage = nil
                            searchModel.updateQuery(newValue)
                        }

                    Button {
                        prefillFromCurrentLocation()
                    } label: {
                        HStack(spacing: 8) {
                            if isPrefilling {
                                ProgressView()
                                    .tint(palette.accentDark)
                            }
                            Text(isPrefilling ? "finding current location…" : "use current location")
                                .font(.bodyM)
                                .foregroundStyle(palette.accentDark)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isPrefilling || isResolving)

                    if let selected {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("selected")
                                .font(.bodyS)
                                .foregroundStyle(palette.textSecondary)
                            Text(selected.displayAddress)
                                .font(.bodyL)
                                .foregroundStyle(palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(palette.accent.opacity(0.12))
                        )
                    } else if !searchModel.suggestions.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(searchModel.suggestions) { suggestion in
                                    Button {
                                        selectSuggestion(suggestion)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(suggestion.title)
                                                .font(.bodyL)
                                                .foregroundStyle(palette.textPrimary)
                                            if !suggestion.subtitle.isEmpty {
                                                Text(suggestion.subtitle)
                                                    .font(.bodyS)
                                                    .foregroundStyle(palette.textSecondary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 12)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isResolving)

                                    Divider().opacity(0.35)
                                }
                            }
                        }
                    } else if searchModel.isSearching {
                        HStack {
                            ProgressView()
                            Text("searching…")
                                .font(.bodyS)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.bodyS)
                            .foregroundStyle(.red.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    PMSageCTAButton(
                        title: isResolving ? "saving…" : "confirm home",
                        action: confirmSelection,
                        isEnabled: selected != nil && !isResolving && !isPrefilling
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .font(.bodyM)
                        .foregroundStyle(palette.accentDark)
                }
            }
            .onAppear {
                if let initialAddress, !initialAddress.isEmpty, query.isEmpty {
                    query = initialAddress
                    searchModel.updateQuery(initialAddress)
                }
            }
        }
    }

    private func selectSuggestion(_ suggestion: AddressSuggestion) {
        errorMessage = nil
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                let resolved = try await searchModel.resolve(suggestion)
                selected = resolved
                query = resolved.displayAddress
                searchModel.clearSuggestions()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? HomeLocationError.geocodeFailed.errorDescription
            }
        }
    }

    private func prefillFromCurrentLocation() {
        errorMessage = nil
        isPrefilling = true
        Task {
            defer { isPrefilling = false }
            do {
                let resolved = try await LocationService.shared.reverseGeocodeCurrentLocation()
                query = resolved.displayAddress
                selected = resolved
                searchModel.clearSuggestions()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? HomeLocationError.locationUnavailable.errorDescription
            }
        }
    }

    private func confirmSelection() {
        guard let selected else {
            errorMessage = HomeLocationError.addressUnresolved.errorDescription
            return
        }
        onConfirm(selected)
        dismiss()
    }
}

// MARK: - Sendable suggestion snapshot

struct AddressSuggestion: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let subtitle: String

    var queryText: String {
        [title, subtitle]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

// MARK: - Search model

@MainActor
final class HomeAddressSearchModel: NSObject, ObservableObject {
    @Published private(set) var suggestions: [AddressSuggestion] = []
    @Published private(set) var isSearching = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func updateQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completer.queryFragment = ""
            suggestions = []
            isSearching = false
            return
        }
        isSearching = true
        completer.queryFragment = trimmed
    }

    func clearSuggestions() {
        suggestions = []
        isSearching = false
    }

    func resolve(_ suggestion: AddressSuggestion) async throws -> ResolvedHomeAddress {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = suggestion.queryText
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw HomeLocationError.geocodeFailed
        }
        let coordinate = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            throw HomeLocationError.geocodeFailed
        }

        let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = suggestion.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let display: String
        if !title.isEmpty, !subtitle.isEmpty {
            display = "\(title), \(subtitle)"
        } else if !title.isEmpty {
            display = title
        } else if let name = item.name, !name.isEmpty {
            display = name
        } else {
            display = subtitle
        }

        guard !display.isEmpty else { throw HomeLocationError.geocodeFailed }

        return ResolvedHomeAddress(
            displayAddress: display,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }
}

extension HomeAddressSearchModel: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let snapshots: [AddressSuggestion] = completer.results.prefix(8).map { result in
            AddressSuggestion(
                id: "\(result.title)|\(result.subtitle)",
                title: result.title,
                subtitle: result.subtitle
            )
        }
        Task { @MainActor in
            self.suggestions = snapshots
            self.isSearching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.suggestions = []
            self.isSearching = false
        }
    }
}
