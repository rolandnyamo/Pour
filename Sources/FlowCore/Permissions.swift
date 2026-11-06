import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics

public enum Permissions {

    // MARK: - Microphone

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - Accessibility

    /// Needed twice over: to create the event tap, and to write text into other apps.
    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system's "open System Settings" prompt if not already granted.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url { NSWorkspace.shared.open(url) }
    }

    public static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        if let url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Input Monitoring

    /// A session-wide `CGEventTapCreate` (how the push-to-talk key is seen) needs this
    /// separately from Accessibility. Without it, tap creation still succeeds — it just
    /// never delivers an event, silently, with no error anywhere and no entry in
    /// System Settings until something explicitly requests it.
    public static var isInputMonitoringTrusted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Registers Pour with TCC and shows the system prompt if not already granted.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    public static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        if let url { NSWorkspace.shared.open(url) }
    }
}
