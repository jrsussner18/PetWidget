import Foundation
import UIKit

// MARK: - Persisted snapshot

enum PersistedOnboardingContext: String, Codable {
    case firstPet
    case additionalPet
}

enum PersistedOnboardingTopStep: String, Codable {
    case photo
    case personality
    case spriteReveal
    case widgetSetup
    case locationTracking
    case paywall
}

struct PersistedOnboardingProgress: Codable {
    var context: PersistedOnboardingContext
    var topStep: PersistedOnboardingTopStep
    var personalityActiveStep: Int
    var personalityIsReview: Bool
    var species: Species
    var gender: PetGender
    var selectedTraits: [PersonalityTrait]
    var energyLevel: Double
    var selectedTriggers: [PetTrigger]
    var customTrigger: String
    var baseMood: BaseMood
    var photoFileNames: [String]
    var pendingPetId: UUID?
    var petName: String
    var isSpriteRevealReady: Bool
    var savedAt: Date

    init(
        context: PersistedOnboardingContext,
        topStep: PersistedOnboardingTopStep,
        personalityActiveStep: Int,
        personalityIsReview: Bool,
        species: Species,
        gender: PetGender,
        selectedTraits: [PersonalityTrait],
        energyLevel: Double,
        selectedTriggers: [PetTrigger],
        customTrigger: String,
        baseMood: BaseMood,
        photoFileNames: [String],
        pendingPetId: UUID?,
        petName: String,
        isSpriteRevealReady: Bool = false,
        savedAt: Date
    ) {
        self.context = context
        self.topStep = topStep
        self.personalityActiveStep = personalityActiveStep
        self.personalityIsReview = personalityIsReview
        self.species = species
        self.gender = gender
        self.selectedTraits = selectedTraits
        self.energyLevel = energyLevel
        self.selectedTriggers = selectedTriggers
        self.customTrigger = customTrigger
        self.baseMood = baseMood
        self.photoFileNames = photoFileNames
        self.pendingPetId = pendingPetId
        self.petName = petName
        self.isSpriteRevealReady = isSpriteRevealReady
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        context = try container.decode(PersistedOnboardingContext.self, forKey: .context)
        topStep = try container.decode(PersistedOnboardingTopStep.self, forKey: .topStep)
        personalityActiveStep = try container.decode(Int.self, forKey: .personalityActiveStep)
        personalityIsReview = try container.decode(Bool.self, forKey: .personalityIsReview)
        species = try container.decode(Species.self, forKey: .species)
        gender = try container.decode(PetGender.self, forKey: .gender)
        selectedTraits = try container.decode([PersonalityTrait].self, forKey: .selectedTraits)
        energyLevel = try container.decode(Double.self, forKey: .energyLevel)
        selectedTriggers = try container.decode([PetTrigger].self, forKey: .selectedTriggers)
        customTrigger = try container.decode(String.self, forKey: .customTrigger)
        baseMood = try container.decode(BaseMood.self, forKey: .baseMood)
        photoFileNames = try container.decode([String].self, forKey: .photoFileNames)
        pendingPetId = try container.decodeIfPresent(UUID.self, forKey: .pendingPetId)
        petName = try container.decode(String.self, forKey: .petName)
        isSpriteRevealReady = try container.decodeIfPresent(Bool.self, forKey: .isSpriteRevealReady) ?? false
        savedAt = try container.decode(Date.self, forKey: .savedAt)
    }
}

// MARK: - Store

enum OnboardingDraftStore {
    private static let progressKey = "onboarding_draft_v1"
    private static let draftDirectoryName = "OnboardingDraft"

    static var hasPendingAdditionalPetDraft: Bool {
        guard let progress = load() else { return false }
        return progress.context == .additionalPet
    }

    static var hasPendingFirstPetDraft: Bool {
        guard let progress = load() else { return false }
        return progress.context == .firstPet
    }

    static var pendingPetId: UUID? {
        load()?.pendingPetId
    }

    static func load() -> PersistedOnboardingProgress? {
        guard let data = UserDefaults.standard.data(forKey: progressKey) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(PersistedOnboardingProgress.self, from: data)
        } catch {
            clear()
            return nil
        }
    }

    @MainActor
    static func save(
        draft: OnboardingDraft,
        context: PersistedOnboardingContext,
        topStep: PersistedOnboardingTopStep,
        personalityActiveStep: Int,
        personalityIsReview: Bool,
        petName: String = "",
        isSpriteRevealReady: Bool = false
    ) {
        let photoFileNames = savePhotos(draft.photoData)
        let progress = PersistedOnboardingProgress(
            context: context,
            topStep: topStep,
            personalityActiveStep: personalityActiveStep,
            personalityIsReview: personalityIsReview,
            species: draft.species,
            gender: draft.gender,
            selectedTraits: Array(draft.selectedTraits),
            energyLevel: draft.energyLevel,
            selectedTriggers: Array(draft.selectedTriggers),
            customTrigger: draft.customTrigger,
            baseMood: draft.baseMood,
            photoFileNames: photoFileNames,
            pendingPetId: draft.completedPet?.id,
            petName: petName,
            isSpriteRevealReady: isSpriteRevealReady,
            savedAt: Date()
        )

        do {
            let data = try JSONEncoder().encode(progress)
            UserDefaults.standard.set(data, forKey: progressKey)
        } catch {
            assertionFailure("Failed to save onboarding draft: \(error)")
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: progressKey)
        try? FileManager.default.removeItem(at: draftDirectoryURL)
    }

    @MainActor
    static func apply(_ progress: PersistedOnboardingProgress, to draft: OnboardingDraft) {
        draft.species = progress.species
        draft.gender = progress.gender
        draft.selectedTraits = Set(progress.selectedTraits)
        draft.energyLevel = progress.energyLevel
        draft.selectedTriggers = Set(progress.selectedTriggers)
        draft.customTrigger = progress.customTrigger
        draft.baseMood = progress.baseMood

        let loadedData = loadPhotos(fileNames: progress.photoFileNames)
        draft.photoData = loadedData
        draft.photos = loadedData.compactMap { UIImage(data: $0) }
    }

    static func navigationPath(for topStep: PersistedOnboardingTopStep) -> [OnboardingCoordinator.OnboardingStep] {
        switch topStep {
        case .photo:
            return []
        case .personality:
            return [.personality]
        case .spriteReveal:
            return [.personality, .spriteReveal]
        case .widgetSetup:
            return [.personality, .spriteReveal, .widgetSetup]
        case .locationTracking:
            return [.personality, .spriteReveal, .widgetSetup, .locationTracking]
        case .paywall:
            return [.personality, .spriteReveal, .widgetSetup, .locationTracking, .paywall]
        }
    }

    // MARK: - Photo files

    private static var draftDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(draftDirectoryName, isDirectory: true)
    }

    private static func savePhotos(_ photoData: [Data]) -> [String] {
        guard !photoData.isEmpty else { return [] }

        let directory = draftDirectoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let existing = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for file in existing where file.hasPrefix("photo_") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
        }

        var fileNames: [String] = []
        for (index, data) in photoData.enumerated() {
            let compressed = compressPhotoData(data)
            let fileName = "photo_\(index).jpg"
            let fileURL = directory.appendingPathComponent(fileName)
            do {
                try compressed.write(to: fileURL, options: .atomic)
                fileNames.append(fileName)
            } catch {
                assertionFailure("Failed to write onboarding photo \(fileName): \(error)")
            }
        }
        return fileNames
    }

    private static func loadPhotos(fileNames: [String]) -> [Data] {
        guard !fileNames.isEmpty else { return [] }
        let directory = draftDirectoryURL
        return fileNames.compactMap { name in
            try? Data(contentsOf: directory.appendingPathComponent(name))
        }
    }

    private static func compressPhotoData(_ data: Data) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let maxEdge: CGFloat = 1200
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height))
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.75) ?? data
    }
}
