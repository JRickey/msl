import Foundation

public struct AppPreferences: Equatable, Sendable {
    public var showMenuBarItem: Bool

    public init(showMenuBarItem: Bool = true) {
        self.showMenuBarItem = showMenuBarItem
    }
}

public final class AppPreferencesStore {
    public static let showMenuBarItemKey = "dev.msl.app.showMenuBarItem"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppPreferences {
        let stored = defaults.object(forKey: Self.showMenuBarItemKey)
        let showMenuBarItem = stored == nil ? true : defaults.bool(forKey: Self.showMenuBarItemKey)
        assert(stored != nil || showMenuBarItem, "a missing menu-bar preference defaults on")
        return AppPreferences(showMenuBarItem: showMenuBarItem)
    }

    public func save(_ preferences: AppPreferences) {
        defaults.set(preferences.showMenuBarItem, forKey: Self.showMenuBarItemKey)
        assert(
            defaults.object(forKey: Self.showMenuBarItemKey) != nil,
            "saved preferences must have a persisted value"
        )
    }
}

public enum StatusItemPreferenceAction: Equatable, Sendable {
    case none
    case create
    case dispose
}

public enum StatusItemPreferencePolicy {
    public static func action(
        showMenuBarItem: Bool,
        hasStatusController: Bool
    ) -> StatusItemPreferenceAction {
        switch (showMenuBarItem, hasStatusController) {
        case (true, false): return .create
        case (false, true): return .dispose
        case (true, true), (false, false): return .none
        }
    }
}
