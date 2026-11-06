import AVFoundation
import CoreAudio
import Foundation

/// One selectable input device, for Settings' microphone picker.
public struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    public let id: String // CoreAudio's persistent unique ID for the device
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A microphone that is always running.
///
/// Starting `AVAudioEngine` on key-down costs 150–250ms and clips the first syllable,
/// which is exactly the latency the whole app is trying to protect. So the engine runs
/// from launch, converting into the analyzer's format continuously, and "starting" a
/// dictation just means opening the gate — plus flushing a short pre-roll buffer so the
/// beginning of the word you'd already started saying isn't lost.
public final class MicrophoneCapture {

    public enum Failure: Error, LocalizedError {
        case noInputDevice
        case converterUnavailable
        case engineStartFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No microphone is available, or Pour hasn't been granted microphone access."
            case .converterUnavailable:
                return "Could not convert microphone audio into the format the speech engine needs."
            case .engineStartFailed(let reason):
                return "The audio engine wouldn't start: \(reason)"
            }
        }
    }

    private let targetFormat: AVAudioFormat
    private let preRollCapacity: AVAudioFrameCount
    /// Rebuilt from scratch on every device switch, not reused. AVAudioEngine caches
    /// graph/format state from whenever it first started; repointing a live engine's
    /// input at a device with a different native sample rate (built-in mic's 48kHz vs.
    /// AirPods' 24kHz) left that cached state stale — CoreAudio would either silently
    /// hand back all-zero buffers or reject the restart outright with -10868
    /// (`kAudioUnitErr_FormatNotSupported`). A fresh instance negotiates the new
    /// device's real format from a clean slate every time.
    private var engine = AVAudioEngine()
    private let lock = NSLock()

    private var converter: AVAudioConverter?
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFrameCount = 0
    private var observer: NSObjectProtocol?

    /// A flapping Bluetooth route (AirPods reconnecting) can fire
    /// `.AVAudioEngineConfigurationChange` repeatedly in a burst. The notification lands
    /// on the main queue, so the retry-with-backoff in `resolvedInputFormat` must not run
    /// there — a busy main thread was the actual cause of the app looking hung during a
    /// route switch. Reconfiguring happens on this dedicated queue instead; `reconfiguring`
    /// (guarded by `lock`, same as the other cross-thread state here) coalesces overlapping
    /// notifications rather than stacking retries on top of each other.
    private let reconfigureQueue = DispatchQueue(label: "com.brewedai.pour.mic-reconfigure")
    private var reconfiguring = false
    /// Configuration notifications often arrive while a Bluetooth route is still
    /// negotiating. Remember that another pass is needed instead of discarding every
    /// notification that arrives during the current pass.
    private var reconfigurePending = false

    /// The engine's observed `isRunning` value is not a statement of intent: CoreAudio
    /// commonly stops it *before* posting a configuration-change notification. Keep
    /// the desired lifecycle separately so losing a headset cannot turn an always-warm
    /// capture engine into a permanently stopped one.
    private var wantsEngineRunning = false

    /// Rate-limits how often `handleConfigurationChange` will act. Two distinct storms
    /// motivate this: explicitly overriding the input device (`applyPreferredDevice`)
    /// makes a freshly started engine post `.AVAudioEngineConfigurationChange` about
    /// *itself*, which without this guard re-entered `handleConfigurationChange` and
    /// posted again, forever; separately, a genuinely flapping Bluetooth route (AirPods
    /// repeatedly dropping and re-establishing their mic profile) can fire real
    /// notifications faster than reconfiguring can keep up. Marked unconditionally at
    /// the top of `handleConfigurationChange`, not only on a successful `engine.start()`
    /// — during exactly that flapping case `start()` can keep failing, and gating the
    /// mark on success would leave the cooldown permanently disarmed for the rest of
    /// the storm. Both cases were observed reconfiguring dozens of times a second.
    private var lastReconfigureAttemptAt: CFAbsoluteTime = 0
    private let reconfigureCooldown: CFAbsoluteTime = 0.75

    /// CoreAudio unique ID of the input device Settings asked for. `nil` means "system
    /// default," which is also the fallback if this device has been unplugged.
    private var preferredDeviceUniqueID: String?

    /// RMS level, 0...1, of the raw input — independent of the dictation gate, so the
    /// UI can show a live meter whether or not a capture is in progress. Called on the
    /// audio thread; hop to the main thread in the handler.
    public var onLevel: ((Float) -> Void)?

    /// Adaptive floor and ceiling the meter normalizes against — measured, not
    /// guessed. This Mac's actual ambient RMS runs ~0.0001–0.0008, far below any
    /// fixed dB threshold that looked reasonable on paper; a fixed floor either
    /// pegged the meter at 1.0 constantly or clamped everything to 0, depending on
    /// which Mac and mic gain it happened to run on. Tracking both ends live instead.
    private var levelFloor: Float = 0.0005
    private var levelPeak: Float = 0.01

    public init(targetFormat: AVAudioFormat, preRollSeconds: Double = 0.3, preferredDeviceUniqueID: String? = nil) {
        self.targetFormat = targetFormat
        self.preRollCapacity = AVAudioFrameCount(targetFormat.sampleRate * preRollSeconds)
        self.preferredDeviceUniqueID = preferredDeviceUniqueID
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public var isRunning: Bool { engine.isRunning }

    /// Every input device currently visible to the system, for Settings' picker.
    /// Queried fresh each call — cheap, and callers only need it when the picker
    /// is on screen or a device is plugged/unplugged.
    public static func availableDevices() -> [MicrophoneDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    // MARK: - Engine lifecycle

    public func startEngine() throws {
        guard !engine.isRunning else { return }
        lock.lock()
        wantsEngineRunning = true
        lock.unlock()
        applyPreferredDevice()
        try installTap()

        do {
            engine.prepare()
            try engine.start()
            lastReconfigureAttemptAt = CFAbsoluteTimeGetCurrent()
        } catch {
            throw Failure.engineStartFailed(error.localizedDescription)
        }

        if observer == nil {
            // Plugging in AirPods mid-session changes the input format and invalidates
            // the converter. Rebuild rather than quietly feeding garbage to the analyzer.
            // `object: nil` rather than the current engine instance — the engine gets
            // replaced on every device switch (see `engine`'s doc comment), and scoping
            // to a specific instance here would silently stop catching notifications
            // from its successor. NotificationCenter.default is in-process only, so this
            // still can't pick up another app's AVAudioEngine.
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleConfigurationChange()
            }
        }
    }

    public func stopEngine() {
        lock.lock()
        wantsEngineRunning = false
        reconfigurePending = false
        lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        sink = nil
        preRoll.removeAll()
        preRollFrames = 0
        lock.unlock()
    }

    /// Switches the input device Settings' mic picker points at. `nil` restores the
    /// system default. Safe to call whether or not the engine is currently running —
    /// if it is, the tap is torn down and rebuilt against the new device.
    public func setPreferredDevice(_ uniqueID: String?) throws {
        lock.lock()
        preferredDeviceUniqueID = uniqueID
        let shouldRun = wantsEngineRunning
        reconfigurePending = shouldRun
        lock.unlock()
        guard shouldRun else { return }
        handleConfigurationChange()
    }

    /// Points the input node's underlying audio unit at `preferredDeviceUniqueID`.
    /// Best-effort: an unresolvable ID (unplugged since it was chosen) just leaves the
    /// system default in place rather than failing the whole engine start.
    private func applyPreferredDevice() {
        lock.lock()
        let uniqueID = preferredDeviceUniqueID
        lock.unlock()
        guard let uniqueID,
              var deviceID = Self.coreAudioDeviceID(forUniqueID: uniqueID),
              let audioUnit = engine.inputNode.audioUnit
        else { return }

        // AVAudioEngine already follows the system-default input. Forcing the audio
        // unit back onto that exact same device is not a no-op: with Bluetooth inputs
        // it tears down the active HFP route while its 24 kHz format is still being
        // negotiated, and the subsequent engine.start() can fail. Only override the
        // unit when Settings actually points at a different device.
        if deviceID == Self.defaultInputDeviceID() { return }

        // Setting CurrentDevice on a unit that's already been touched (even a "fresh"
        // AVAudioEngine's inputNode counts — it gets implicitly initialized as soon as
        // it's accessed) leaves the unit's cached stream format stale: it keeps
        // reporting whatever format it had before, not the new device's actual native
        // one. `installTap` would then build a converter and tap against that stale
        // format, and `engine.start()` would reject the real mismatch with -10868
        // (kAudioUnitErr_FormatNotSupported) — reproduced switching to AirPods (24kHz)
        // from a unit still reporting 48kHz. Uninitializing before the property change
        // and reinitializing after forces a fresh format re-query against the new device.
        AudioUnitUninitialize(audioUnit)
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        AudioUnitInitialize(audioUnit)
    }

    /// Resolves a device's persistent UID (what `availableDevices()` hands out, and
    /// what Settings stores) to the `AudioDeviceID` CoreAudio actually wants — the
    /// latter isn't stable across reboots/replugs, so it's never persisted itself.
    private static func coreAudioDeviceID(forUniqueID uniqueID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid = uniqueID as CFString
        var deviceID = kAudioObjectUnknown
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString?>.size),
                uidPtr,
                &propSize,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = kAudioObjectUnknown
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propSize,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func installTap() throws {
        let inputNode = engine.inputNode
        let inputFormat = try resolvedInputFormat(of: inputNode)
        guard let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw Failure.converterUnavailable
        }
        converter = newConverter

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
    }

    /// A Bluetooth route switch (AirPods connecting) takes the input device a beat to
    /// actually come up — `outputFormat(forBus:)` reports a zero sample rate for a few
    /// hundred ms while HFP negotiation finishes. Poll briefly rather than failing the
    /// whole reconfigure on that transient window, which otherwise left capture dead
    /// until the app restarted.
    private func resolvedInputFormat(of inputNode: AVAudioInputNode, attempts: Int = 20) throws -> AVAudioFormat {
        for attempt in 0..<attempts {
            let format = inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0 { return format }
            if attempt < attempts - 1 { Thread.sleep(forTimeInterval: 0.1) }
        }
        throw Failure.noInputDevice
    }

    private func handleConfigurationChange() {
        // Called on the main queue (see the observer registration above) — must return
        // fast. A route already being reconfigured means another notification is due
        // once it settles, so this one is redundant rather than something to queue up.
        //
        // Also skip anything arriving right after our own last reconfigure attempt —
        // see `lastReconfigureAttemptAt`'s doc comment. This has to be marked unconditionally,
        // not only after `engine.start()` succeeds: a genuinely flapping Bluetooth route
        // (AirPods repeatedly dropping and re-establishing their mic profile) can make
        // `engine.start()` keep failing, and if the timestamp only ever updated on
        // success, the cooldown would never engage during exactly the storm it exists
        // to dampen — observed reconfiguring dozens of times a second with the route
        // never settling.
        lock.lock()
        guard wantsEngineRunning else { lock.unlock(); return }
        if reconfiguring {
            reconfigurePending = true
            lock.unlock()
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastReconfigureAttemptAt > reconfigureCooldown else {
            reconfigurePending = true
            lock.unlock()
            schedulePendingReconfigure(after: reconfigureCooldown)
            return
        }
        lastReconfigureAttemptAt = now
        reconfiguring = true
        reconfigurePending = false
        lock.unlock()

        reconfigureQueue.async { [weak self] in
            guard let self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.engine = AVAudioEngine()
            self.applyPreferredDevice()

            // If the new route still isn't ready, leave the engine stopped rather than
            // starting it with no tap installed — that used to look "running" while
            // silently delivering nothing.
            let tapInstalled = (try? self.installTap()) != nil
            self.lock.lock()
            let shouldRun = self.wantsEngineRunning
            self.lock.unlock()
            var restarted = false
            if tapInstalled && shouldRun {
                self.engine.prepare()
                do {
                    try self.engine.start()
                    restarted = true
                } catch {}
            }

            self.lock.lock()
            self.reconfiguring = false
            // A failed attempt needs another pass even if CoreAudio emits no final
            // notification after the route finishes settling.
            let retry = self.wantsEngineRunning && (self.reconfigurePending || !restarted)
            self.reconfigurePending = false
            self.lock.unlock()

            if retry {
                self.schedulePendingReconfigure(after: self.reconfigureCooldown)
            }
        }
    }

    private func schedulePendingReconfigure(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let wantsEngineRunning = self.wantsEngineRunning
            let pending = self.reconfigurePending
            self.lock.unlock()
            let needed = wantsEngineRunning && (pending || !self.engine.isRunning)
            if needed { self.handleConfigurationChange() }
        }
    }

    // MARK: - Gate

    /// Open the gate. The pre-roll is flushed first, so `sink` receives the audio from
    /// just *before* the key went down.
    public func beginForwarding(to newSink: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        let backlog = preRoll
        preRoll.removeAll()
        preRollFrames = 0
        sink = newSink
        lock.unlock()

        for buffer in backlog { newSink(buffer) }
    }

    /// Close the gate. Safe to call from any thread; the audio thread will stop
    /// delivering before this returns.
    public func endForwarding() {
        lock.lock()
        sink = nil
        lock.unlock()
    }

    // MARK: - Audio thread

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let level = rmsLevel(of: buffer)
        if let onLevel {
            onLevel(level)
        }

        guard let converted = convert(buffer) else { return }

        lock.lock()
        if let sink {
            lock.unlock()
            sink(converted)
            return
        }
        // Gate closed: keep the tail of recent audio around as pre-roll.
        preRoll.append(converted)
        preRollFrames += converted.frameLength
        while preRollFrames > preRollCapacity, !preRoll.isEmpty {
            preRollFrames -= preRoll.removeFirst().frameLength
        }
        lock.unlock()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Root-mean-square of the first channel, normalized against a floor and ceiling
    /// that both track the live signal instead of a fixed dB threshold. Measured on
    /// this Mac: ambient RMS sits around 0.0001–0.0008 — an order of magnitude below
    /// where a "reasonable-looking" fixed floor (-48dBFS ≈ 0.004) would clamp
    /// everything to exactly 0 before it ever reached the ceiling logic.
    private func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frameCount { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(frameCount))

        // Floor tracks the quiet baseline: snaps down fast to genuine silence, creeps
        // up slowly so a sustained loud sound can't drag it upward and numb the meter.
        if rms < levelFloor {
            levelFloor = rms
        } else {
            levelFloor = levelFloor * 0.999 + rms * 0.001
        }

        // Peak: fast attack to a new loud moment, slow release back down over a few
        // seconds — a standard VU-meter envelope follower.
        if rms > levelPeak {
            levelPeak = rms
        } else {
            levelPeak = levelPeak * 0.998 + rms * 0.002
        }

        let range = max(levelPeak - levelFloor, 0.0005)
        let linear = max(0, min(1, (rms - levelFloor) / range))
        return sqrt(linear) // perceptual curve: makes quieter speech visibly move
    }
}
