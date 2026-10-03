import Foundation

struct BenchPreference: Codable, Equatable {
    var jobID: UUID?
    var itemID: UUID?
    var showsPane = true
}

final class BenchPreferences {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, libraryRoot: URL) {
        self.defaults = defaults
        key = "benchReference." + libraryRoot.standardizedFileURL.path
    }

    var value: BenchPreference {
        get {
            guard let data = defaults.data(forKey: key),
                let preference = try? JSONDecoder().decode(BenchPreference.self, from: data)
            else { return BenchPreference() }
            return preference
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: key)
        }
    }
}

nonisolated enum BenchLayout {
    static let referenceWidth = 340.0
    static let minimumEditingWidth = 540.0

    static func showsPane(availableWidth: Double, requested: Bool) -> Bool {
        requested && availableWidth >= referenceWidth + minimumEditingWidth + 1
    }
}
