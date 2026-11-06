import AVFoundation
import AppKit
import AudioCapture
import DictionaryKit
import Foundation
import HotkeyKit
import InjectKit
import RefineKit
import TranscriptionKit

/// Thread-safe "claim exactly once" flag. `awaitTranscriptionAndDeliver`'s normal
/// completion and its watchdog timeout race on two different threads — this makes sure
/// only whichever one gets there first acts, instead of both trying to settle the state.
private final class SettleGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false

    func trySettle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return false }
        settled = true
        return true
    }
}

/// The state machine from the architecture doc, minus the phases we haven't built.
/// Phase 2 inserts `.refining` between `.finishing` and `.injecting`.
public enum DictationState: Equatable {
    case starting
    case idle
    case capturing
    case finishing
    case refining
    case injecting
    /// Something is missing — a permission, a mic, a model. Carries a sentence for the UI.
    case blocked(String)

    public var isBusy: Bool {
        switch self {
        case .capturing, .finishing, .refining, .injecting: return true
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
    public var onDelivered: ((RefinementResult, String, String?, String?, InjectionStrategy, TimeInterval, [CorrectionHit]) -> Void)?
    /// Resolves global/per-app preferences captured with the destination at key-down.
    public var configurationForTarget: ((String?) -> (AccuracyMode, RefinementConfiguration))?
    public var onUndo: (() -> Void)?

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
    private var deviceUniqueID: String?
    private var engine: (any SpeechEngine)?
    private var capture: MicrophoneCapture?

    private var commands: AsyncStream<Command>.Continuation?
    private var loop: Task<Void, Never>?

    private var target: InjectionTarget = .none
    private var releasedAt: CFAbsoluteTime = 0
    private let refiner = LocalTranscriptRefiner()
    private var lastDeliveryTarget: InjectionTarget?

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

    public init(
        dictionary: DictionaryStore,
        hotkeyConfig: PushToTalkHotkey.Config = .init(),
        locale: Locale = .current,
        deviceUniqueID: String? = nil
    ) {
        self.dictionary = dictionary
        self.hotkeyConfig = hotkeyConfig
        self.hotkey = PushToTalkHotkey(config: hotkeyConfig)
        self.locale = locale
        self.deviceUniqueID = deviceUniqueID
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

    /// Switches the input device Settings' mic picker points at. `nil` means the
    /// system default. Cheaper than `start()` — swaps the device under the running
    /// mic rather than tearing down and reloading the speech engine.
    public func updateMicrophoneDevice(_ uniqueID: String?) {
        deviceUniqueID = uniqueID
        do {
            try capture?.setPreferredDevice(uniqueID)
        } catch {
            // Previously swallowed entirely — a failed switch (e.g. a Bluetooth route
            // still negotiating) left capture silently dead with no feedback at all.
            state = .blocked(error.localizedDescription)
        }
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

        // Accessibility alone lets the push-to-talk event tap get created without
        // erroring — it just never delivers a keystroke. This is the grant that
        // actually makes the tap live, and it's easy to miss since nothing else
        // surfaces its absence.
        guard Permissions.isInputMonitoringTrusted else {
            Permissions.requestInputMonitoring()
            guard generation == startGeneration else { return }
            state = .blocked("Pour needs Input Monitoring access to see the push-to-talk key. Grant it, then choose Retry.")
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

            let capture = MicrophoneCapture(targetFormat: engine.audioFormat, preferredDeviceUniqueID: deviceUniqueID)
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

    /// `engine.endUtterance()` can, rarely, hang deep inside Apple's SpeechAnalyzer
    /// framework — badly enough to block one of Swift Concurrency's own limited
    /// cooperative-pool threads, which starves *everything* waiting on that pool,
    /// including a `Task`-based timeout racing against it. That's why an in-process
    /// `withThrowingTaskGroup` timeout here previously "fired" (its own sleep completed)
    /// but the group's result never resumed. Worse: `finishCapture()` used to be awaited
    /// directly by `perform(_:)` on the one serial command loop that also handles every
    /// later press — a hang here wedged that loop forever, and no Retry or device switch
    /// could ever recover without a full app restart.
    ///
    /// So the actual wait now happens in a detached, un-awaited task, and this function
    /// returns as soon as it's launched that — the command loop is freed immediately,
    /// regardless of what `endUtterance()` ends up doing. A `DispatchQueue` watchdog
    /// (a different thread pool than Swift Concurrency's, and not vulnerable to the same
    /// starvation) forces `state` back out of `.finishing` on a timeout either way.
    private func finishCapture() async {
        guard state == .capturing, let engine, let capture else { return }

        let generation = startGeneration
        releasedAt = CFAbsoluteTimeGetCurrent()
        capture.endForwarding()
        state = .finishing

        Task { [weak self] in
            await self?.awaitTranscriptionAndDeliver(engine: engine, generation: generation)
        }
    }

    private func awaitTranscriptionAndDeliver(engine: any SpeechEngine, generation: Int) async {
        let settled = SettleGuard()

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, settled.trySettle(), generation == self.startGeneration else { return }
            Task { await engine.cancelUtterance() }
            Task { @MainActor in
                self.preview = ""
                self.state = .blocked("Transcription timed out.")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: watchdog)

        let text: String
        do {
            text = try await engine.endUtterance()
        } catch {
            guard settled.trySettle() else { return }
            watchdog.cancel()
            guard generation == startGeneration else { return }
            state = .blocked(error.localizedDescription)
            return
        }

        guard settled.trySettle() else { return }
        watchdog.cancel()
        guard generation == startGeneration else { return }
        await deliverTranscript(text)
    }

    private func deliverTranscript(_ text: String) async {
        guard !text.isEmpty else {
            preview = ""
            state = .idle
            return
        }

        state = .refining
        // Give SwiftUI/HUD observers a render opportunity before the inexpensive
        // local pass completes; this is a yield, not an artificial latency delay.
        await Task.yield()
        let resolved = configurationForTarget?(target.bundleID)
            ?? (.accurate, RefinementConfiguration())
        let refinement = refiner.refineSynchronously(
            text,
            mode: resolved.0,
            configuration: resolved.1
        )

        // Dictionary corrections remain the guaranteed final pass, after general
        // cleanup, so a user's canonical spelling always wins.
        let (corrected, hits) = dictionary.applyCorrections(to: refinement.refinedText)
        lastTranscript = corrected
        state = .injecting

        let strategy = TextInjector.insert(corrected, into: target)
        lastDeliveryTarget = target
        let elapsed = CFAbsoluteTimeGetCurrent() - releasedAt
        onDelivered?(refinement, corrected, target.appName, target.bundleID, strategy, elapsed, hits)

        preview = ""
        state = .idle
    }

    /// Reverts the last delivered text only while its destination app still has focus.
    /// Returns false instead of risking an undo in an unrelated application.
    @discardableResult
    public func undoLastInsertion() -> Bool {
        guard let lastDeliveryTarget,
              TextInjector.undoLastInsertion(in: lastDeliveryTarget)
        else { return false }
        onUndo?()
        self.lastDeliveryTarget = nil
        return true
    }

    private func cancelCapture() async {
        guard state == .capturing || state == .finishing else { return }
        capture?.endForwarding()
        // Not awaited — same reasoning as `awaitTranscriptionAndDeliver`'s watchdog
        // cleanup: this calls back into the engine that may itself be the thing hung,
        // and awaiting it here would put the hang right back on the serial command loop
        // that Esc is supposed to escape from immediately.
        if let engine { Task { await engine.cancelUtterance() } }
        preview = ""
        state = .idle
    }
}
