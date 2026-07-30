import Foundation

// MARK: - Pet Model

struct Pet: Codable, Identifiable, Equatable {
    let id: UUID
    let userId: UUID
    var name: String
    var species: Species
    var gender: PetGender
    var expressions: ExpressionMap
    var personalityTraits: [PersonalityTrait]
    var energyLevel: Int            // 1–10
    var triggers: [PetTrigger]
    var customTrigger: String?
    var baseMood: BaseMood
    var homeLat: Double?
    var homeLng: Double?
    var homeAddress: String?
    var timezone: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case species
        case gender
        case expressions
        case personalityTraits = "personality_traits"
        case energyLevel = "energy_level"
        case biggestEnemy = "biggest_enemy"
        case baseMood = "base_mood"
        case homeLat = "home_lat"
        case homeLng = "home_lng"
        case homeAddress = "home_address"
        case timezone
        case createdAt = "created_at"
    }

    init(
        id: UUID,
        userId: UUID,
        name: String,
        species: Species,
        gender: PetGender,
        expressions: ExpressionMap,
        personalityTraits: [PersonalityTrait],
        energyLevel: Int,
        triggers: [PetTrigger],
        customTrigger: String? = nil,
        baseMood: BaseMood,
        homeLat: Double?,
        homeLng: Double?,
        homeAddress: String? = nil,
        timezone: String,
        createdAt: Date
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.species = species
        self.gender = gender
        self.expressions = expressions
        self.personalityTraits = personalityTraits
        self.energyLevel = energyLevel
        self.triggers = triggers
        self.customTrigger = customTrigger
        self.baseMood = baseMood
        self.homeLat = homeLat
        self.homeLng = homeLng
        self.homeAddress = homeAddress
        self.timezone = timezone
        self.createdAt = createdAt
    }

    /// Combined string stored in `biggest_enemy` for Supabase and edge-function prompts.
    var triggerSummary: String {
        PetTrigger.storageString(triggers: triggers, custom: customTrigger)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userId = try container.decode(UUID.self, forKey: .userId)
        name = try container.decode(String.self, forKey: .name)
        species = try container.decode(Species.self, forKey: .species)
        gender = try container.decode(PetGender.self, forKey: .gender)
        expressions = try container.decode(ExpressionMap.self, forKey: .expressions)
        personalityTraits = try container.decode([PersonalityTrait].self, forKey: .personalityTraits)
        energyLevel = try container.decode(Int.self, forKey: .energyLevel)
        baseMood = try container.decode(BaseMood.self, forKey: .baseMood)
        homeLat = try container.decodeIfPresent(Double.self, forKey: .homeLat)
        homeLng = try container.decodeIfPresent(Double.self, forKey: .homeLng)
        homeAddress = try container.decodeIfPresent(String.self, forKey: .homeAddress)
        timezone = try container.decode(String.self, forKey: .timezone)
        createdAt = try container.decode(Date.self, forKey: .createdAt)

        let legacyValue = try container.decode(String.self, forKey: .biggestEnemy)
        let parsed = PetTrigger.parseFromStorageString(legacyValue)
        triggers = parsed.triggers
        customTrigger = parsed.custom
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(name, forKey: .name)
        try container.encode(species, forKey: .species)
        try container.encode(gender, forKey: .gender)
        try container.encode(expressions, forKey: .expressions)
        try container.encode(personalityTraits, forKey: .personalityTraits)
        try container.encode(energyLevel, forKey: .energyLevel)
        try container.encode(triggerSummary, forKey: .biggestEnemy)
        try container.encode(baseMood, forKey: .baseMood)
        try container.encodeIfPresent(homeLat, forKey: .homeLat)
        try container.encodeIfPresent(homeLng, forKey: .homeLng)
        try container.encodeIfPresent(homeAddress, forKey: .homeAddress)
        try container.encode(timezone, forKey: .timezone)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

// MARK: - Sub-types

enum Species: String, Codable, CaseIterable {
    case dog, cat, other
    var displayName: String { rawValue.capitalized }
}

enum PetGender: String, Codable, CaseIterable {
    case boy, girl
    var displayName: String { rawValue.capitalized }
}

struct ExpressionMap: Codable, Equatable {
    var happy: String?
    var sleepy: String?
    var mad: String?
    var excited: String?
    var missesYou: String?
    var judging: String?

    enum CodingKeys: String, CodingKey {
        case happy, sleepy, mad, excited
        case missesYou = "misses_you"
        case judging
    }

    subscript(expression: PetExpression) -> String? {
        switch expression {
        case .happy: return happy
        case .sleepy: return sleepy
        case .mad: return mad
        case .excited: return excited
        case .missesYou: return missesYou
        case .judging: return judging
        }
    }
}

enum PetExpression: String, Codable, CaseIterable {
    case happy, sleepy, mad, excited
    case missesYou = "misses_you"
    case judging

    var displayName: String {
        switch self {
        case .happy: return "Happy"
        case .sleepy: return "Sleepy"
        case .mad: return "Mad"
        case .excited: return "Excited"
        case .missesYou: return "Misses You"
        case .judging: return "Judging"
        }
    }

    var accentColor: String {
        switch self {
        case .happy: return "#FFE566"
        case .sleepy: return "#A8C4E0"
        case .mad: return "#FF8A7A"
        case .excited: return "#C8F06E"
        case .missesYou: return "#F2B8CB"
        case .judging: return "#C9BDD4"
        }
    }

    var promptModifier: String {
        switch self {
        case .happy: return "smiling, bright eyes, happy expression"
        case .sleepy: return "half-closed eyes, drowsy, yawning"
        case .mad: return "furrowed brow, grumpy expression, crossed arms implied"
        case .excited: return "wide eyes, open mouth, ears perked up"
        case .missesYou: return "sad eyes, droopy ears, looking up with longing"
        case .judging: return "one eyebrow raised, unimpressed stare, side-eye"
        }
    }
}

enum PersonalityTrait: String, Codable, CaseIterable {
    case dramatic, lazy, chaotic, sweet, judgy, needy
    case aloof, hyper, foodie, anxious, sneaky, stoic

    var displayName: String { rawValue.capitalized }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "mischievous" {
            self = .sneaky
        } else if let value = PersonalityTrait(rawValue: raw) {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown personality trait: \(raw)"
            )
        }
    }
}

enum PetTrigger: String, Codable, CaseIterable, Hashable {
    case vacuumCleaner = "vacuum cleaner"
    case doorbell
    case mailman
    case bathTime = "bath time"
    case strangers
    case otherPets = "other pets"
    case loudNoises = "loud noises"
    case ownReflection = "their own reflection"
    case beingIgnored = "being ignored"
    case carRides = "car rides"
    case birds
    case foodDelivery = "food delivery"
    case separationAnxiety = "separation anxiety"
    case loneliness

    var displayName: String { rawValue.capitalized }

    /// Parses legacy `biggest_enemy` text (single or comma-separated) into triggers + optional custom phrase.
    static func parseFromStorageString(_ value: String) -> (triggers: [PetTrigger], custom: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ([.vacuumCleaner], nil)
        }

        let parts = trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var triggers: [PetTrigger] = []
        var customParts: [String] = []

        for part in parts {
            if let match = matchPreset(part) {
                if !triggers.contains(match) {
                    triggers.append(match)
                }
            } else {
                customParts.append(part)
            }
        }

        let custom: String? = customParts.isEmpty ? nil : customParts.joined(separator: ", ")

        if triggers.isEmpty {
            if let custom, !custom.isEmpty {
                return ([], custom)
            }
            if let single = matchPreset(trimmed) {
                return ([single], nil)
            }
            return ([], trimmed)
        }

        return (triggers, custom)
    }

    private static func matchPreset(_ text: String) -> PetTrigger? {
        let lowered = text.lowercased()
        if let exact = PetTrigger(rawValue: lowered) {
            return exact
        }
        return PetTrigger.allCases.first {
            $0.rawValue.caseInsensitiveCompare(text) == .orderedSame
                || $0.displayName.caseInsensitiveCompare(text) == .orderedSame
        }
    }

    static func storageString(triggers: [PetTrigger], custom: String?) -> String {
        var parts = triggers.map(\.rawValue)
        if let custom = custom?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            parts.append(custom)
        }
        if parts.isEmpty {
            return PetTrigger.vacuumCleaner.rawValue
        }
        return parts.joined(separator: ", ")
    }
}

enum BaseMood: String, Codable, CaseIterable {
    case chill
    case mildlySuspicious = "mildly suspicious"
    case emotionallyFragile = "emotionally fragile"
    case unimpressed

    var displayName: String { rawValue.capitalized }
}

// MARK: - Draft (used during onboarding)

struct PetDraft {
    var photos: [Data] = []
    var name: String = ""
    var species: Species = .cat
    var personalityTraits: Set<PersonalityTrait> = []
    var energyLevel: Double = 5.0
    var selectedTriggers: Set<PetTrigger> = []
    var customTrigger: String = ""
    var baseMood: BaseMood = .chill

    var isValid: Bool {
        !photos.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Onboarding trigger helpers

extension OnboardingDraft {
    var trimmedCustomTrigger: String {
        customTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isTriggersStepValid: Bool {
        !selectedTriggers.isEmpty || !trimmedCustomTrigger.isEmpty
    }

    var triggersReviewSummary: String {
        PetTrigger.storageString(
            triggers: Array(selectedTriggers),
            custom: trimmedCustomTrigger.isEmpty ? nil : trimmedCustomTrigger
        )
    }

    func triggersForPet() -> [PetTrigger] {
        Array(selectedTriggers)
    }

    func customTriggerForPet() -> String? {
        trimmedCustomTrigger.isEmpty ? nil : trimmedCustomTrigger
    }
}
