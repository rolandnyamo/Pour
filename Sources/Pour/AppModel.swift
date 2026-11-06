import DictionaryKit
import FlowCore
import Foundation
import HistoryKit
import HotkeyKit
import Observation
import ParakeetKit
import RefineKit
import ServiceManagement
import TranscriptionKit

/// The app's central state: the two persisted stores, the dictation controller, and
/// settings. One instance, owned by the app delegate, handed down through the
/// environment to every window.
@MainActor
@Observable
final class AppModel {

    let dictionary = DictionaryStore()
    let history: HistoryStore
    let usageStats = UsageStatsStore()
    let controller: DictationController
    private(set) var settings: AppSettings

    /// The main window's sidebar selection — lives here, not as local view state, so
    /// the menu bar's "Settings…" can jump to it from outside the window entirely.
    var selectedSidebarSection: SidebarSection? = .transcriptions

    /// Mirrors of the controller's callback-based state, so SwiftUI views can read
    /// them directly. `DictationController` only supports one subscriber per signal —
    /// this is that one subscriber; everyone else (the menu bar item, the HUD) adds an
    /// observer below instead of touching the controller directly.
    private(set) var dictationState: DictationState = .starting
    private(set) var preview: String = ""
    private(set) var level: Float = 0

    private var stateObservers: [(DictationState) -> Void] = []
    private var previewObservers: [(String) -> Void] = []
    private var lastDeliveredHistoryID: UUID?
    /// Fired right after a `HistoryEntry` lands, for the menu bar's "last transcript" line.
    var onDeliveredEntry: ((HistoryEntry) -> Void)?
    /// Fired whenever settings change — the menu bar's "hold ` to dictate" hint needs
    /// to track the current hotkey, not the one it was launched with.
    var onSettingsChanged: ((AppSettings) -> Void)?

    init() {
        var loaded = AppSettings.load()
        // SMAppService is the actual source of truth (the user could have removed
        // Pour from Login Items in System Settings directly) — reconcile on launch.
        loaded.launchAtLogin = SMAppService.mainApp.status == .enabled
        settings = loaded
        history = HistoryStore(enabled: loaded.historyEnabled)
        usageStats.backfillAppUsage(from: history.entries) { appName in
            InstalledApplicationResolver.application(named: appName)?.bundleIdentifier
        }
        controller = DictationController(
            dictionary: dictionary,
            hotkeyConfig: loaded.hotkeyConfig,
            locale: Locale(identifier: loaded.localeIdentifier),
            deviceUniqueID: loaded.microphoneDeviceUniqueID
        )
        controller.engineFactory = Self.engineFactory(for: loaded.engineKind)
        controller.configurationForTarget = { [weak self] bundleIdentifier in
            let preferences = self?.settings.effectiveRefinementPreferences(for: bundleIdentifier)
                ?? AppSettings().refinementPreferences
            return (preferences.accuracyMode.refineValue, preferences.refineConfiguration)
        }

        controller.onStateChange = { [weak self] state in
            guard let self else { return }
            self.dictationState = state
            for observe in self.stateObservers { observe(state) }
        }
        controller.onPreviewChange = { [weak self] text in
            guard let self else { return }
            self.preview = text
            for observe in self.previewObservers { observe(text) }
        }
        controller.onLevelChange = { [weak self] level in
            self?.level = level
        }
        controller.onDelivered = { [weak self] refinement, text, appName, bundleIdentifier, strategy, elapsed, hits in
            guard let self else { return }
            // Independent of whether History is enabled — a word count isn't the
            // transcript text itself, and stats shouldn't reset just because
            // someone turned History off.
            let wordCount = text.split(whereSeparator: \.isWhitespace).count
            self.usageStats.record(
                wordCount: wordCount,
                appBundleIdentifier: bundleIdentifier,
                appName: appName
            )

            guard let entry = self.history.record(
                text: text,
                appName: appName,
                strategy: strategy.rawValue,
                elapsedMS: Int((elapsed * 1000).rounded()),
                hits: hits,
                rawText: refinement.rawText,
                refinementChanges: refinement.changes.map {
                    HistoryRefinementChange(
                        kind: $0.kind.rawValue,
                        original: $0.original,
                        replacement: $0.replacement,
                        rule: $0.rule
                    )
                },
                detectedCommands: refinement.detectedCommands.map(\.rawValue)
            ) else { return }
            self.lastDeliveredHistoryID = entry.id
            self.onDeliveredEntry?(entry)
        }
        controller.onUndo = { [weak self] in
            guard let self, let id = self.lastDeliveredHistoryID else { return }
            _ = self.history.markRestored(id: id)
            self.lastDeliveredHistoryID = nil
        }
    }

    func addStateObserver(_ observe: @escaping (DictationState) -> Void) {
        stateObservers.append(observe)
    }

    func addPreviewObserver(_ observe: @escaping (String) -> Void) {
        previewObservers.append(observe)
    }

    func bootstrap(onDownloadProgress: ((Double) -> Void)? = nil) async {
        await controller.start(onDownloadProgress: onDownloadProgress)
    }

    func setHotkey(_ config: PushToTalkHotkey.Config) {
        settings.hotkeyKeyCode = config.keyCode
        settings.interactionMode = config.mode
        settings.save()
        controller.updateHotkey(config)
        onSettingsChanged?(settings)
    }

    func setInteractionMode(_ mode: PushToTalkHotkey.InteractionMode) {
        var config = settings.hotkeyConfig
        config.mode = mode
        setHotkey(config)
    }

    func setLocale(_ identifier: String, onDownloadProgress: ((Double) -> Void)? = nil) async {
        settings.localeIdentifier = identifier
        settings.save()
        await controller.updateLocale(Locale(identifier: identifier), onDownloadProgress: onDownloadProgress)
    }

    /// Swaps which `SpeechEngine` Settings' Model picker points at. Parakeet downloads
    /// its own models on first use — `onDownloadProgress` reports that the same way
    /// Apple's OS-managed asset download does.
    func setEngineKind(_ kind: EngineKind, onDownloadProgress: ((Double) -> Void)? = nil) async {
        settings.engineKind = kind
        settings.save()
        controller.engineFactory = Self.engineFactory(for: kind)
        await controller.start(onDownloadProgress: onDownloadProgress)
    }

    private static func engineFactory(for kind: EngineKind) -> DictationController.EngineFactory {
        switch kind {
        case .apple:
            return { locale, onDownloadProgress in
                try await AppleSpeechEngine.make(locale: locale, onDownloadProgress: onDownloadProgress)
            }
        case .parakeet:
            return { _, onDownloadProgress in
                try await ParakeetSpeechEngine.make(onDownloadProgress: onDownloadProgress)
            }
        }
    }

    /// `SMAppService` is itself the source of truth for whether Pour is a login item —
    /// `settings.launchAtLogin` just mirrors it for the UI without an extra query.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
        } catch {
            // Registration failed — leave settings reflecting the service's actual state.
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        settings.save()
    }

    func setMicrophoneDevice(_ uniqueID: String?) {
        settings.microphoneDeviceUniqueID = uniqueID
        settings.save()
        controller.updateMicrophoneDevice(uniqueID)
    }

    func setHistoryEnabled(_ enabled: Bool) {
        settings.historyEnabled = enabled
        settings.save()
        history.setEnabled(enabled)
    }

    func clearHistory() {
        history.clear()
    }

    @discardableResult
    func undoLastInsertion() -> Bool {
        controller.undoLastInsertion()
    }

    func updateRefinement(_ update: (inout AppSettings) -> Void) {
        update(&settings)
        settings.save()
        onSettingsChanged?(settings)
    }

    func saveAppProfile(_ profile: AppProfile) {
        updateRefinement { settings in
            settings.appProfiles.removeAll { $0.bundleIdentifier == profile.bundleIdentifier }
            settings.appProfiles.append(profile)
        }
    }

    func removeAppProfile(_ profile: AppProfile) {
        updateRefinement { settings in
            settings.appProfiles.removeAll { $0.bundleIdentifier == profile.bundleIdentifier }
        }
    }
}

private extension AccuracyMode {
    var refineValue: RefineKit.AccuracyMode {
        switch self {
        case .fast: .fast
        case .smartLocal: .smartLocal
        case .accurate: .accurate
        }
    }
}

private extension RefinementPreferences {
    var refineConfiguration: RefinementConfiguration {
        let level: RefineKit.CleanupLevel = switch cleanupLevel {
        case .off: .off
        case .conservative: .conservative
        case .balanced: .balanced
        case .aggressive: .aggressive
        }
        return RefinementConfiguration(
            cleanupLevel: level,
            fillerRemoval: removeFillers,
            repetitionCleanup: removeRepetitions,
            falseStartCleanup: cleanFalseStarts,
            spokenPunctuation: spokenPunctuation,
            listFormatting: automaticListFormatting
        )
    }
}
