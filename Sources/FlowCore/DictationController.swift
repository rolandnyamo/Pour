import AVFoundation
import AppKit
import AudioCapture
import DictionaryKit
import Foundation
import HotkeyKit
import InjectKit
import TranscriptionKit

/// The state machine from the architecture doc, minus the phases we haven't built.
/// Phase 2 inserts `.refining` between `.finishing` and `.injecting`.
public enum DictationState: Equatable {
    case starting
    case idle
    case capturing
    case finishing
    case injecting
    /// Something is missing — a permission, a mic, a model. Carries a sentence for the UI.
    case blocked(String)

    public var isBusy: Bool {
        switch self {
        case .capturing, .finishing, .injecting: return true
        default: return false
        }
    }
}

/// Owns the hot path: hotkey → capture → transcription → injection.
///
/// Every state transition runs through one serial command loop. Press and release can
/// arrive milliseconds apart while `beginUtterance` is still awaiting, and without
/// serialization that race eats the first dictation of every session.
@MainActor
public final class DictationController {

    // MARK: Observable surface

    public private(set) var state: DictationState = .starting {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Live text while capturing. Phase 1 renders this in the HUD; for now the menu bar shows it.
    public private(set) var preview: String = "" {
        didSet { onPreviewChange?(preview) }
    }

    public private(set) var lastTranscript: String = ""

    /// Screen-coordinate frame of wherever the last capture is landing, captured at
    /// key-down alongside `target` — for a HUD to park itself near the caret. `nil`
    /// when the focused app doesn't expose element geometry.
    public private(set) var targetFrame: CGRect?

    /// Raw mic RMS level, 0...1. Updates continuously — the mic never stops — but the
    /// UI should only draw it while `state == .capturing`.
    public private(set) var level: Float = 0 {
        didSet { onLevelChange?(level) }
    }

    public var onStateChange: ((DictationState) -> Void)?
    public var onPreviewChange: ((String) -> Void)?
    public var onLevelChange: ((Float) -> Void)?
    /// Fired after a successful injection: the corrected text, the app name and bundle
    /// identifier it landed in, how it got there, the elapsed time, and corrections.
    public var onDelivered: ((String, String?, String?, InjectionStrategy, TimeInterval, [CorrectionHit]) -> Void)?

    // MARK: Internals

    private enum Command {
        case press
        case release
        case cancel
    }

    private let dictionary: DictionaryStore
    private var hotkeyConfig: PushToTalkHotkey.Config
    private var hotkey: PushToTalkHotkey
    private var locale: Locale
    private var engine: (any SpeechEngine)?
    private var capture: MicrophoneCapture?

    private var commands: AsyncStream<Command>.Continuation?
    private var loop: Task<Void, Never>?

    private var target: InjectionTarget = .none
    private var releasedAt: CFAbsoluteTime = 0

    /// Bumped at the top of every `start()`. `start()` can be called again (a locale
    /// or engine switch) before a prior call's `engineFactory` await — which can take
    /// a while for an engine that has to download a model — has resolved. Without this,
    /// two `start()`s can race: both eventually try to commit `self.engine`/`self.capture`
    /// and fire `onDownloadProgress`, with no guarantee the one the user actually asked
    /// for last is the one that wins. Every commit point checks its captured generation
    /// against the current one first and bails — discarding, not just ignoring, a stale
    /// result — if it's been superseded.
    private var startGeneration = 0

    /// How `start()` builds its engine. FlowCore doesn't know Parakeet (or any other
    /// engine) exists — the app layer swaps this in based on Settings' engine picker.
    /// Defaults to Apple's SpeechAnalyzer, so nothing about the base app changes for
    /// anyone who never touches the picker.
    public typealias EngineFactory = (Locale, ((Double) -> Void)?) async throws -> any SpeechEngine
    public var engineFactory: EngineFactory = { locale, onDownloadProgress in
        try await AppleSpeechEngine.make(locale: locale, onDownloadProgress: onDownloadProgress)
    }

    public init(dictionary: DictionaryStore, hotkeyConfig: PushToTalkHotkey.Config = .init(), locale: Locale = .current) {
        self.dictionary = dictionary
        self.hotkeyConfig = hotkeyConfig
        self.hotkey = PushToTalkHotkey(config: hotkeyConfig)
        self.locale = locale
    }

    /// Re-arms the tap with a new key combo. Safe to call while idle or mid-session —
    /// the old tap is torn down and a fresh one takes its place before returning.
    public func updateHotkey(_ config: PushToTalkHotkey.Config) {
        hotkeyConfig = config
        let wasRunning = hotkey.isRunning
        hotkey.stop()
        hotkey = PushToTalkHotkey(config: config)
        wireHotkeyCallbacks()
        if wasRunning {
            try? hotkey.start()
        }
    }

    /// Switches the transcription locale — Settings' "model" picker. Tears down and
    /// rebuilds the engine, same as a fresh `start()`.
    public func updateLocale(_ newLocale: Locale, onDownloadProgress: ((Double) -> Void)? = nil) async {
        locale = newLocale
        await start(onDownloadProgress: onDownloadProgress)
    }

    // MARK: - Bootstrap

    /// Requests permissions, loads the speech model, warms the mic, and arms the hotkey.
    /// Safe to call again after the user grants a permission that was missing.
    public func start(onDownloadProgress: ((Double) -> Void)? = nil) async {
        startGeneration += 1
        let generation = startGeneration

        state = .starting

        // Retry after granting a permission comes back through here — don't leave a
        // second audio engine running.
        capture?.stopEngine()
        capture = nil
        await engine?.cancelUtterance()
        engine = nil

        guard await Permissions.requestMicrophone() else {
            guard generation == startGeneration else { return }
            state = .blocked("Pour needs microphone access.")
            return
        }

        guard Permissions.isAccessibilityTrusted else {
            Permissions.requestAccessibility()
            guard generation == startGeneration else { return }
            state = .blocked("Pour needs Accessibility access. Grant it, then choose Retry.")
            return
        }

        // Progress can arrive on any thread/executor (FluidAudio's download progress
        // is @Sendable, not MainActor) and can keep firing for a while after this
        // start() has been superseded — hop back and check the generation every time.
        let progressForwarder: (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, generation == self.startGeneration else { return }
                onDownloadProgress?(fraction)
            }
        }

        do {
            let engine = try await engineFactory(locale, progressForwarder)

            guard generation == startGeneration else {
                // A newer start() (a fast Retry, or another Settings change) won the
                // race while this one was still loading — discard what was just built
                // instead of letting it clobber whatever the newer call already set up.
                await engine.cancelUtterance()
                return
            }

            let capture = MicrophoneCapture(targetFormat: engine.audioFormat)
            capture.onLevel = { [weak self] level in
                Task { @MainActor in
                    guard let self, generation == self.startGeneration else { return }
                    self.level = level
                }
            }
            try capture.startEngine()

            self.engine = engine
            self.capture = capture

            startCommandLoop()
            try hotkey.start()

            state = .idle
        } catch {
            guard generation == startGeneration else { return }
            state = .blocked(error.localizedDescription)
        }
    }

    /// The main window's Start/Stop button — funnels into the same serial command
    /// queue as the hotkey, so a click and a held key can never race each other.
    public func beginCaptureFromUI() {
        commands?.yield(.press)
    }

    public func endCaptureFromUI() {
        commands?.yield(.release)
    }

    public func stop() {
        hotkey.stop()
        capture?.stopEngine()
        commands?.finish()
        loop?.cancel()
        loop = nil
        commands = nil
        state = .idle
    }

    private func startCommandLoop() {
        guard loop == nil else { return }

        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commands = continuation

        loop = Task { [weak self] in
            for await command in stream {
                guard let self else { return }
                await self.perform(command)
            }
        }

        wireHotkeyCallbacks()
    }

    // These fire on the event tap thread. Enqueueing is all they're allowed to do —
    // anything slower and macOS disables the tap.
    private func wireHotkeyCallbacks() {
        hotkey.onPress = { [weak self] in
            self?.commands?.yield(.press)
        }
        hotkey.onRelease = { [weak self] _ in
            self?.commands?.yield(.release)
        }
        hotkey.onCancel = { [weak self] in
            self?.commands?.yield(.cancel)
        }
    }

    // MARK: - The hot path

    private func perform(_ command: Command) async {
        switch command {
        case .press:   await beginCapture()
        case .release: await finishCapture()
        case .cancel:  await cancelCapture()
        }
    }

    private func beginCapture() async {
        guard state == .idle, let engine, let capture else { return }

        // Hazard 02: grab the destination now, while focus is still unambiguous.
        target = TextInjector.captureTarget()
        targetFrame = TextInjector.frame(of: target)
        preview = ""
        state = .capturing

        do {
            await engine.updateContext(vocabulary: dictionary.biasVocabulary())
            try await engine.beginUtterance { [weak self] update in
                Task { @MainActor in
                    guard let self, self.state == .capturing else { return }
                    self.preview = update.text
                }
            }
            capture.beginForwarding { buffer in
                engine.feed(buffer)
            }
        } catch {
            capture.endForwarding()
            state = .blocked(error.localizedDescription)
        }
    }

    private func finishCapture() async {
        guard state == .capturing, let engine, let capture else { return }

        releasedAt = CFAbsoluteTimeGetCurrent()
        capture.endForwarding()
        state = .finishing

        let text: String
        do {
            text = try await engine.endUtterance()
        } catch {
            state = .blocked(error.localizedDescription)
            return
        }

        guard !text.isEmpty else {
            preview = ""
            state = .idle
            return
        }

        // The dictionary's correction pass — the guaranteed path, run before anything
        // reaches the target app. RefineKit's cleanup pass and the length-ratio guard
        // still slot in right here, ahead of injection.
        let (corrected, hits) = dictionary.applyCorrections(to: text)
        lastTranscript = corrected
        state = .injecting

        let strategy = TextInjector.insert(corrected, into: target)
        let elapsed = CFAbsoluteTimeGetCurrent() - releasedAt
        onDelivered?(corrected, target.appName, target.bundleID, strategy, elapsed, hits)

        preview = ""
        state = .idle
    }

    private func cancelCapture() async {
        guard state == .capturing || state == .finishing else { return }
        capture?.endForwarding()
        await engine?.cancelUtterance()
        preview = ""
        state = .idle
    }
}
