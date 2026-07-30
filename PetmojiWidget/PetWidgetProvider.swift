import WidgetKit
import SwiftUI

// WidgetKit passes non-`Sendable` completion handlers; `Task` requires a `@Sendable` closure.
// These boxes opt out of static checking for that handoff only.
private final class PetWidgetSnapshotCompletion: @unchecked Sendable {
    private let handler: (PetWidgetEntry) -> Void
    init(_ handler: @escaping (PetWidgetEntry) -> Void) { self.handler = handler }
    func callAsFunction(_ entry: PetWidgetEntry) { handler(entry) }
}

private final class PetWidgetTimelineCompletion: @unchecked Sendable {
    private let handler: (Timeline<PetWidgetEntry>) -> Void
    init(_ handler: @escaping (Timeline<PetWidgetEntry>) -> Void) { self.handler = handler }
    func callAsFunction(_ timeline: Timeline<PetWidgetEntry>) { handler(timeline) }
}

// MARK: - Widget Timeline Entry

struct PetWidgetEntry: TimelineEntry {
    let date: Date
    let petId: UUID?
    let petName: String
    let spriteURL: String?
    let spriteImageData: Data?     // Data is Sendable; convert to UIImage at render time
    /// Scales the sprite down so opaque pixels (including tall ears) fit inside the widget slot.
    let spriteFitScale: CGFloat
    let message: String
    let expression: WidgetExpression

    static let placeholder = PetWidgetEntry(
        date: .now,
        petId: nil,
        petName: "Mochi",
        spriteURL: nil,
        spriteImageData: nil,
        spriteFitScale: 0.88,
        message: "thinking about naps. and also snacks.",
        expression: .sleepy
    )

    var spriteImage: UIImage? {
        guard let data = spriteImageData else { return nil }
        return UIImage(data: data)
    }
}

enum WidgetExpression: String, Codable {
    case happy, sleepy, mad, excited, missesYou, judging

    var accentHex: String {
        switch self {
        case .happy:     return "#FFE566"
        case .sleepy:    return "#A8C4E0"
        case .mad:       return "#FF8A7A"
        case .excited:   return "#C8F06E"
        case .missesYou: return "#F2B8CB"
        case .judging:   return "#C9BDD4"
        }
    }

    init(from petExpression: String) {
        switch petExpression {
        case "happy":      self = .happy
        case "sleepy":     self = .sleepy
        case "mad":        self = .mad
        case "excited":    self = .excited
        case "misses_you": self = .missesYou
        case "judging":    self = .judging
        default:           self = .happy
        }
    }
}

// MARK: - Timeline Provider

struct PetWidgetProvider: TimelineProvider {
    private static let appGroupSuiteName = "group.com.petmoji.app"

    func placeholder(in context: Context) -> PetWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (PetWidgetEntry) -> Void) {
        let complete = PetWidgetSnapshotCompletion(completion)
        Task {
            let entry = await Self.loadEntry()
            complete(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PetWidgetEntry>) -> Void) {
        let complete = PetWidgetTimelineCompletion(completion)
        Task {
            let entry = await Self.loadEntry()
            // Short fallback so a missed reloadAllTimelines still picks up app-group writes soon.
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date) ?? entry.date
            complete(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
    }

    // MARK: - Build entry with pre-downloaded image data

    /// Static helpers avoid capturing `self` in `Task`'s `@Sendable` closure (Swift 6).
    private nonisolated static func loadEntry() async -> PetWidgetEntry {
        let defaults = UserDefaults(suiteName: appGroupSuiteName)
        guard let name = defaults?.string(forKey: "pet_name"),
              let message = defaults?.string(forKey: "widget_message") else {
            return .placeholder
        }

        let expressionStr = defaults?.string(forKey: "widget_expression") ?? "happy"
        let spriteURL = defaults?.string(forKey: "widget_sprite_url")
        let petId = defaults?.string(forKey: "widget_pet_id").flatMap(UUID.init(uuidString:))
            ?? defaults?.string(forKey: "pet_id").flatMap(UUID.init(uuidString:))

        // Prefer the app-group sprite cache written by the main app (reliable); fall back to network.
        let imageData: Data?
        if let cached = Self.cachedSpriteData(matching: spriteURL) {
            imageData = cached
        } else {
            imageData = await Self.downloadImageData(from: spriteURL)
        }
        let fitScale: CGFloat = {
            guard let imageData, let image = UIImage(data: imageData) else { return 0.88 }
            return image.widgetContentFitScale()
        }()

        return PetWidgetEntry(
            date: .now,
            petId: petId,
            petName: name,
            spriteURL: spriteURL,
            spriteImageData: imageData,
            spriteFitScale: fitScale,
            message: message,
            expression: WidgetExpression(from: expressionStr)
        )
    }

    private nonisolated static func cachedSpriteData(matching urlString: String?) -> Data? {
        guard let urlString else { return nil }
        let defaults = UserDefaults(suiteName: appGroupSuiteName)
        guard defaults?.string(forKey: "widget_sprite_cache_url") == urlString,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupSuiteName
              ) else { return nil }
        let fileURL = container.appendingPathComponent("widget_latest_sprite.img", isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        return data
    }

    private nonisolated static func downloadImageData(from urlString: String?) async -> Data? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }
}
