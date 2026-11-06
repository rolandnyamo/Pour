import AppKit
import HistoryKit
import CoreGraphics
import DesignKit
import FlowCore

/// The secondary surface now: status and the hotkey while you're working in another
/// app. The main window — history, the level meter, the Dictionary — is the primary
/// interface; this just keeps a cup in the menu bar that fills while you hold the key.
@MainActor
final class StatusItemController: NSObject {

    var onRetry: (() -> Void)?
    var onQuit: (() -> Void)?
    var onShowWindow: (() -> Void)?

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let hintLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastLine = NSMenuItem(title: "No dictation yet", action: nil, keyEquivalent: "")
    private let retryItem = NSMenuItem(title: "Retry Setup", action: #selector(retry), keyEquivalent: "")
    private let undoItem = NSMenuItem(title: "Undo Last Insertion", action: #selector(undoLast), keyEquivalent: "z")

    /// Brand tint per state, from the approved token sheet: Amber while listening,
    /// Blue while working, Green on delivery, Error red when blocked.
    private enum Brand {
        static let amber = NSColor(PourColor.amber)
        static let blue = NSColor(PourColor.blue500)
        static let green = NSColor(PourColor.success)
        static let violet = NSColor(PourColor.violet)
        static let red = NSColor(PourColor.error)
    }

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        buildMenu()
        statusItem.menu = menu

        model.addStateObserver { [weak self] state in self?.render(state) }
        model.addPreviewObserver { [weak self] text in self?.renderPreview(text) }
        model.onSettingsChanged = { [weak self] settings in self?.updateHotkeyLabel(settings.hotkeyKeyCode) }

        updateHotkeyLabel(model.settings.hotkeyKeyCode)
        render(.starting)
    }

    // MARK: - Menu

    private func buildMenu() {
        statusLine.isEnabled = false
        lastLine.isEnabled = false
        retryItem.target = self
        retryItem.isHidden = true
        undoItem.target = self
        undoItem.isEnabled = false

        hintLine.isEnabled = false

        let showItem = NSMenuItem(title: "Open Pour", action: #selector(showWindow), keyEquivalent: "")
        showItem.target = self

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self

        let copyItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLast), keyEquivalent: "c")
        copyItem.target = self

        let axItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAX), keyEquivalent: "")
        axItem.target = self

        let quitItem = NSMenuItem(title: "Quit Pour", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(statusLine)
        menu.addItem(hintLine)
        menu.addItem(.separator())
        menu.addItem(showItem)
        menu.addItem(settingsItem)
        menu.addItem(lastLine)
        menu.addItem(copyItem)
        menu.addItem(undoItem)
        menu.addItem(.separator())
        menu.addItem(retryItem)
        menu.addItem(axItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
    }

    // MARK: - Rendering

    private func render(_ state: DictationState) {
        guard let button = statusItem.button else { return }

        retryItem.isHidden = true
        button.title = ""

        switch state {
        case .starting:
            setSymbol("cup.and.saucer", on: button, tint: nil, label: "Starting")
            statusLine.title = "Starting…"

        case .idle:
            setSymbol("cup.and.saucer", on: button, tint: nil, label: "Ready")
            statusLine.title = "Ready · \(hotkeyPhrase)"

        case .capturing:
            setSymbol("cup.and.saucer.fill", on: button, tint: Brand.amber, label: "Listening")
            statusLine.title = "Listening…"

        case .finishing:
            setSymbol("cup.and.saucer.fill", on: button, tint: Brand.blue, label: "Transcribing")
            statusLine.title = "Transcribing…"

        case .refining:
            setSymbol("wand.and.sparkles", on: button, tint: Brand.violet, label: "Refining")
            statusLine.title = "Refining locally…"

        case .injecting:
            setSymbol("cup.and.saucer.fill", on: button, tint: Brand.blue, label: "Delivering")
            statusLine.title = "Delivering…"

        case .blocked(let reason):
            setSymbol("exclamationmark.triangle.fill", on: button, tint: Brand.red, label: "Blocked")
            statusLine.title = reason
            retryItem.isHidden = false
        }
    }

    private func renderPreview(_ text: String) {
        guard let button = statusItem.button else { return }
        guard !text.isEmpty else {
            button.title = ""
            return
        }
        // Show the tail — that's the part that's still changing.
        let trimmed = text.count > 42 ? "…" + String(text.suffix(42)) : text
        button.title = " " + trimmed
    }

    func renderDelivered(_ entry: HistoryEntry) {
        let where_ = entry.appName.map { " → \($0)" } ?? ""
        let preview = entry.text.count > 48 ? String(entry.text.prefix(48)) + "…" : entry.text
        let corrected = entry.corrections.isEmpty ? "" : " · \(entry.corrections.count) corrected"
        lastLine.title = "\(preview)\(where_) · \(entry.elapsedMS)ms · \(entry.strategy)\(corrected)"
        undoItem.isEnabled = true

        // A green blink on delivery, then back to the resting cup.
        if let button = statusItem.button {
            setSymbol("cup.and.saucer.fill", on: button, tint: Brand.green, label: "Delivered")
        }
    }

    private var hotkeyLabel = "`"

    private var hotkeyPhrase: String {
        switch model.settings.interactionMode {
        case .holdToTalk: "hold \(hotkeyLabel) to dictate"
        case .toggle: "press \(hotkeyLabel) to dictate"
        }
    }

    private func updateHotkeyLabel(_ keyCode: CGKeyCode) {
        hotkeyLabel = KeyName.string(for: keyCode)
        hintLine.title = "\(hotkeyPhrase.prefix(1).uppercased())\(hotkeyPhrase.dropFirst()) · Esc to cancel"
        if case .idle = model.dictationState {
            statusLine.title = "Ready · \(hotkeyPhrase)"
        }
    }

    func showDownloadProgress(_ fraction: Double) {
        statusLine.title = "Downloading speech model… \(Int(fraction * 100))%"
    }

    private func setSymbol(_ name: String, on button: NSStatusBarButton, tint: NSColor?, label: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        // Template images are what `contentTintColor` actually recolors.
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.toolTip = "Pour — \(label)"
    }

    // MARK: - Actions

    @objc private func copyLast() {
        let text = model.controller.lastTranscript
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func undoLast() {
        guard model.undoLastInsertion() else {
            statusLine.title = "Return to the destination app to undo safely."
            return
        }
        undoItem.isEnabled = false
        statusLine.title = "Restored original app state"
    }

    @objc private func openAX() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func showWindow() {
        onShowWindow?()
    }

    @objc private func openSettings() {
        // Settings is a sidebar section in the main window now, not a separate
        // window — just select it and bring the window forward. No more private
        // selectors or menu-item lookups to fight with.
        model.selectedSidebarSection = .settings
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.styleMask.contains(.titled) })?.makeKeyAndOrderFront(nil)
    }

    @objc private func retry() {
        onRetry?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
