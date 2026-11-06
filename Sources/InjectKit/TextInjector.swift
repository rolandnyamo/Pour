import AppKit
import ApplicationServices
import Foundation

/// Where the text is going. Captured at key-down, because that's the last moment the
/// answer is unambiguous — by the time transcription finishes, focus may have moved.
public struct InjectionTarget {
    public let app: NSRunningApplication?
    public let element: AXUIElement?

    public var bundleID: String? { app?.bundleIdentifier }
    public var appName: String? { app?.localizedName }

    public init(app: NSRunningApplication?, element: AXUIElement?) {
        self.app = app
        self.element = element
    }

    public static let none = InjectionTarget(app: nil, element: nil)
}

public enum InjectionStrategy: String {
    /// Wrote directly into the focused element via the Accessibility API. No clipboard touched.
    case accessibility
    /// Put the text on the pasteboard and synthesized ⌘V, then restored the pasteboard.
    case paste
}

public enum TextInjector {

    /// Apps whose Accessibility text-setting is unreliable — mostly Chromium and Electron.
    /// These go straight to paste. Grow this list as you find more.
    public static var pasteOnlyBundleIDs: Set<String> = [
        // Terminal hosts. Their focused text areas often claim that AXSelectedText is
        // settable and return success while silently discarding the write. That made
        // terminal programs such as Claude Code look like Pour had delivered text
        // even though nothing appeared.
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",

        // Electron code editors and their common release channels.
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "ai.deepseek.harness",
        "com.tinyspeck.slackmacgap",
        "notion.id",
        "com.google.Chrome",
        "com.brave.Browser",
        "com.figma.Desktop",
        "com.hnc.Discord",
        "com.microsoft.teams2",
        "io.dsh.desktop",

        // Native Cocoa apps with the same silent-discard bug: AXSelectedText reports
        // settable and the write returns success, but Outlook's rich-text compose
        // field never applies it. Confirmed 2026-08-31 via history.json — logged
        // strategy "accessibility" for a delivery the user never saw land.
        "com.microsoft.Outlook"
    ]

    private static let syntheticMarker: Int64 = 0x504F_5552 // "POUR"

    // MARK: - Capture

    /// Snapshot the frontmost app and its focused element. Cheap enough to call on key-down.
    public static func captureTarget() -> InjectionTarget {
        let app = NSWorkspace.shared.frontmostApplication
        guard let pid = app?.processIdentifier else {
            return InjectionTarget(app: app, element: nil)
        }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard status == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return InjectionTarget(app: app, element: nil)
        }

        return InjectionTarget(app: app, element: (value as! AXUIElement))
    }

    /// Best-effort screen-coordinate frame of the focused element, for positioning a
    /// HUD near the caret. `nil` if the app doesn't expose position/size — some
    /// custom-drawn text views don't, and that's fine, callers fall back to the pointer.
    public static func frame(of target: InjectionTarget) -> CGRect? {
        guard let element = target.element else { return nil }

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        // AX coordinates are top-left-origin across the whole virtual display space;
        // AppKit screen coordinates are bottom-left-origin relative to the main screen.
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let flippedY = mainScreenHeight - point.y - size.height
        return CGRect(x: point.x, y: flippedY, width: size.width, height: size.height)
    }

    // MARK: - Insert

    /// Try the clean path, fall back to the compatible one. Returns which one was used
    /// so the caller can log it — you'll want that data when tuning `pasteOnlyBundleIDs`.
    @discardableResult
    public static func insert(_ text: String, into target: InjectionTarget) -> InjectionStrategy {
        guard !text.isEmpty else { return .accessibility }

        // Bundle identifiers are documented as case-insensitive. Some third-party
        // apps do not use stable casing between release channels, so do not let a
        // casing mismatch put them back on the unreliable Accessibility path.
        let blocked = target.bundleID.map { bundleID in
            pasteOnlyBundleIDs.contains { candidate in
                candidate.caseInsensitiveCompare(bundleID) == .orderedSame
            }
        } ?? false
        if !blocked, let element = target.element, setSelectedText(text, on: element) {
            return .accessibility
        }

        pasteViaClipboard(text)
        return .paste
    }

    /// Reverts the most recent insertion using the target application's native undo
    /// manager. This is deliberately guarded by app identity: sending Command-Z after
    /// focus has moved could destroy unrelated work in another application.
    @discardableResult
    public static func undoLastInsertion(in target: InjectionTarget) -> Bool {
        guard let bundleID = target.bundleID,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
        else { return false }
        postCommandKey(virtualKey: 6) // kVK_ANSI_Z
        return true
    }

    // MARK: - Strategy 1: Accessibility

    private static func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let canSet = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard canSet == .success, settable.boolValue else { return false }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    // MARK: - Strategy 2: clipboard + ⌘V

    /// Clipboard-history managers (Maccy, Pastebot, Clipy, and friends) respect these
    /// de facto marker types and skip recording an item that carries them — doesn't
    /// stop a deliberately malicious poller, but it's a real, free mitigation for the
    /// transcript otherwise sitting on the general pasteboard for ~370ms.
    private static let transientMarkerType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedMarkerType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private static func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientMarkerType)
        item.setData(Data(), forType: concealedMarkerType)
        pasteboard.writeObjects([item])
        let ourChangeCount = pasteboard.changeCount

        // A beat for the pasteboard write to settle before the target app reads it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            postCommandV()

            // Restore — but only if nothing else has claimed the pasteboard since.
            // Clipboard managers will race you here, and stomping them is rude.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard pasteboard.changeCount == ourChangeCount else { return }
                restore(saved, to: pasteboard)
            }
        }
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        // Items belong to the pasteboard and can't be re-added, so deep-copy the payloads.
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    private static func postCommandV() {
        postCommandKey(virtualKey: 9) // kVK_ANSI_V
    }

    private static func postCommandKey(virtualKey: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
