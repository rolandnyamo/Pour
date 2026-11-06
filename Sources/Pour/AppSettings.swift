import CoreGraphics
import Foundation
import HotkeyKit

/// Which `SpeechEngine` Settings' Model picker points `DictationController` at.
/// Apple's SpeechAnalyzer is the default and always available; Parakeet is optional
/// (downloads its own models on first use — see `ParakeetKit`).
enum EngineKind: String, Codable {
    case apple
    case parakeet
}

/// How much Pour may reshape a transcript after recognition.
enum CleanupLevel: String, Codable, CaseIterable {
    case off
    case conservative
    case balanced
    case aggressive
}

/// Whether insertion favors immediate results or a higher-quality final pass.
enum AccuracyMode: String, Codable, CaseIterable {
    case fast
    case smartLocal
    case accurate

    var displayName: String {
        switch self {
        case .fast: "Fast"
        case .smartLocal: "Smart Local"
        case .accurate: "Accurate"
        }
    }
}

/// Built-in starting points for application-specific refinement.
enum AppProfilePreset: String, Codable, CaseIterable {
    case standard
    case messages
    case email
    case notes
    case coding
    case custom
}

/// Fully resolved values consumed by dictation/refinement code.
struct RefinementPreferences: Codable, Equatable {
    var cleanupLevel: CleanupLevel
    var accuracyMode: AccuracyMode
    var removeFillers: Bool
    var removeRepetitions: Bool
    var cleanFalseStarts: Bool
    var spokenPunctuation: Bool
    var automaticListFormatting: Bool
    var showChangesBeforeInsertion: Bool
}

/// Optional per-application values. A nil value inherits its preset (or the
/// global setting for the `standard` and `custom` presets).
struct AppProfile: Codable, Identifiable, Equatable {
    var bundleIdentifier: String
    var name: String
    var isEnabled: Bool = true
    var preset: AppProfilePreset = .standard
    var cleanupLevel: CleanupLevel?
    var accuracyMode: AccuracyMode?
    var removeFillers: Bool?
    var removeRepetitions: Bool?
    var cleanFalseStarts: Bool?
    var spokenPunctuation: Bool?
    var automaticListFormatting: Bool?
    var showChangesBeforeInsertion: Bool?

    var id: String { bundleIdentifier }

    init(bundleIdentifier: String, name: String, isEnabled: Bool = true,
         preset: AppProfilePreset = .standard) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.isEnabled = isEnabled
        self.preset = preset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? bundleIdentifier
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        preset = try c.decodeIfPresent(AppProfilePreset.self, forKey: .preset) ?? .standard
        cleanupLevel = try c.decodeIfPresent(CleanupLevel.self, forKey: .cleanupLevel)
        accuracyMode = try c.decodeIfPresent(AccuracyMode.self, forKey: .accuracyMode)
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers)
        removeRepetitions = try c.decodeIfPresent(Bool.self, forKey: .removeRepetitions)
        cleanFalseStarts = try c.decodeIfPresent(Bool.self, forKey: .cleanFalseStarts)
        spokenPunctuation = try c.decodeIfPresent(Bool.self, forKey: .spokenPunctuation)
        automaticListFormatting = try c.decodeIfPresent(Bool.self, forKey: .automaticListFormatting)
        showChangesBeforeInsertion = try c.decodeIfPresent(Bool.self, forKey: .showChangesBeforeInsertion)
    }
}

/// Persisted user settings: the push-to-talk key and its interaction mode, and the
/// transcription engine/locale ("the model," in Settings).
struct AppSettings: Codable {
    var hotkeyKeyCode: CGKeyCode = 50 // kVK_ANSI_Grave — Pour's original default
    var interactionMode: PushToTalkHotkey.InteractionMode = .holdToTalk
    var engineKind: EngineKind = .apple
    var localeIdentifier: String = Locale.current.identifier
    var launchAtLogin: Bool = false
    var historyEnabled: Bool = true
    /// CoreAudio unique ID of the chosen input device. `nil` means "System Default."
    var microphoneDeviceUniqueID: String? = nil
    var cleanupLevel: CleanupLevel = .conservative
    var accuracyMode: AccuracyMode = .accurate
    var removeFillers: Bool = true
    var removeRepetitions: Bool = true
    var cleanFalseStarts: Bool = false
    var spokenPunctuation: Bool = true
    var automaticListFormatting: Bool = false
    var showChangesBeforeInsertion: Bool = false
    var appProfiles: [AppProfile] = []

    init() {}

    // Custom decoding with per-field fallbacks: a field added after some users
    // already have a saved settings file must not make the whole decode fail and
    // silently reset their hotkey and locale back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyKeyCode = try c.decodeIfPresent(CGKeyCode.self, forKey: .hotkeyKeyCode) ?? 50
        interactionMode = try c.decodeIfPresent(PushToTalkHotkey.InteractionMode.self, forKey: .interactionMode) ?? .holdToTalk
        engineKind = try c.decodeIfPresent(EngineKind.self, forKey: .engineKind) ?? .apple
        localeIdentifier = try c.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? Locale.current.identifier
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
        microphoneDeviceUniqueID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceUniqueID)
        cleanupLevel = try c.decodeIfPresent(CleanupLevel.self, forKey: .cleanupLevel) ?? .conservative
        accuracyMode = try c.decodeIfPresent(AccuracyMode.self, forKey: .accuracyMode) ?? .accurate
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? true
        removeRepetitions = try c.decodeIfPresent(Bool.self, forKey: .removeRepetitions) ?? true
        cleanFalseStarts = try c.decodeIfPresent(Bool.self, forKey: .cleanFalseStarts) ?? false
        spokenPunctuation = try c.decodeIfPresent(Bool.self, forKey: .spokenPunctuation) ?? true
        automaticListFormatting = try c.decodeIfPresent(Bool.self, forKey: .automaticListFormatting) ?? false
        showChangesBeforeInsertion = try c.decodeIfPresent(Bool.self, forKey: .showChangesBeforeInsertion) ?? false
        appProfiles = try c.decodeIfPresent([AppProfile].self, forKey: .appProfiles) ?? []
    }

    private static let defaultsKey = "com.brewedai.pour.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    var hotkeyConfig: PushToTalkHotkey.Config {
        var config = PushToTalkHotkey.Config()
        config.keyCode = hotkeyKeyCode
        config.mode = interactionMode
        return config
    }

    var refinementPreferences: RefinementPreferences {
        RefinementPreferences(
            cleanupLevel: cleanupLevel,
            accuracyMode: accuracyMode,
            removeFillers: removeFillers,
            removeRepetitions: removeRepetitions,
            cleanFalseStarts: cleanFalseStarts,
            spokenPunctuation: spokenPunctuation,
            automaticListFormatting: automaticListFormatting,
            showChangesBeforeInsertion: showChangesBeforeInsertion
        )
    }

    func appProfile(for bundleIdentifier: String?) -> AppProfile? {
        guard let bundleIdentifier else { return nil }
        return appProfiles.first {
            $0.isEnabled && $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    func effectiveRefinementPreferences(for bundleIdentifier: String?) -> RefinementPreferences {
        guard let profile = appProfile(for: bundleIdentifier) else {
            return refinementPreferences
        }

        let base = presetPreferences(profile.preset) ?? refinementPreferences
        return RefinementPreferences(
            cleanupLevel: profile.cleanupLevel ?? base.cleanupLevel,
            accuracyMode: profile.accuracyMode ?? base.accuracyMode,
            removeFillers: profile.removeFillers ?? base.removeFillers,
            removeRepetitions: profile.removeRepetitions ?? base.removeRepetitions,
            cleanFalseStarts: profile.cleanFalseStarts ?? base.cleanFalseStarts,
            spokenPunctuation: profile.spokenPunctuation ?? base.spokenPunctuation,
            automaticListFormatting: profile.automaticListFormatting ?? base.automaticListFormatting,
            showChangesBeforeInsertion: profile.showChangesBeforeInsertion ?? base.showChangesBeforeInsertion
        )
    }

    private func presetPreferences(_ preset: AppProfilePreset) -> RefinementPreferences? {
        switch preset {
        case .standard, .custom:
            return nil
        case .messages:
            return RefinementPreferences(cleanupLevel: .conservative, accuracyMode: .fast,
                                         removeFillers: true, removeRepetitions: true,
                                         cleanFalseStarts: false, spokenPunctuation: true,
                                         automaticListFormatting: false, showChangesBeforeInsertion: false)
        case .email:
            return RefinementPreferences(cleanupLevel: .balanced, accuracyMode: .smartLocal,
                                         removeFillers: true, removeRepetitions: true,
                                         cleanFalseStarts: true, spokenPunctuation: true,
                                         automaticListFormatting: true, showChangesBeforeInsertion: false)
        case .notes:
            return RefinementPreferences(cleanupLevel: .balanced, accuracyMode: .fast,
                                         removeFillers: true, removeRepetitions: true,
                                         cleanFalseStarts: false, spokenPunctuation: true,
                                         automaticListFormatting: true, showChangesBeforeInsertion: false)
        case .coding:
            return RefinementPreferences(cleanupLevel: .off, accuracyMode: .accurate,
                                         removeFillers: false, removeRepetitions: false,
                                         cleanFalseStarts: false, spokenPunctuation: false,
                                         automaticListFormatting: false, showChangesBeforeInsertion: false)
        }
    }
}
