import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppPreferences {
    enum Language: String, CaseIterable, Identifiable {
        case system
        case simplifiedChinese
        case english

        var id: Self { self }

        var locale: Locale? {
            switch self {
            case .system: nil
            case .simplifiedChinese: Locale(identifier: "zh-Hans")
            case .english: Locale(identifier: "en")
            }
        }

        func text(zh: String, en: String) -> String {
            switch self {
            case .simplifiedChinese:
                zh
            case .english:
                en
            case .system:
                Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: Self { self }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    var language: Language {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    var replaceOriginal: Bool {
        didSet { defaults.set(replaceOriginal, forKey: Keys.replaceOriginal) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = Language(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        replaceOriginal = defaults.bool(forKey: Keys.replaceOriginal)
    }

    private enum Keys {
        static let language = "language"
        static let appearance = "appearance"
        static let replaceOriginal = "replaceOriginal"
    }
}

