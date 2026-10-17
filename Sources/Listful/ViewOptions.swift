import Foundation
import Observation

/// App-wide view state that outlives any one open task list.
@MainActor @Observable
final class ViewOptions {
    private static let showDecruftedKey = "showDecrufted"

    var showDecrufted: Bool {
        didSet { UserDefaults.standard.set(showDecrufted, forKey: Self.showDecruftedKey) }
    }

    init() {
        showDecrufted = UserDefaults.standard.bool(forKey: Self.showDecruftedKey)
    }
}
