import AudioCapture
import AVFoundation
import DesignKit
import HotkeyKit
import SwiftUI
import TranscriptionKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var availableLocales: [Locale] = []
    @State private var availableMicrophones: [MicrophoneDevice] = []
    @State private var downloadProgress: Double?
    @State private var confirmingHistoryClear = false
    @State private var profileBundleID = ""
    @State private var profileName = ""
    @State private var profilePreset: AppProfilePreset = .standard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PourSpace.xl) {
                settingsCard(title: "General") {
                    HStack {
                        Text("Launch at login")
                            .font(PourFont.body(13))
                            .foregroundStyle(PourColor.text)
                        Spacer()
                        Toggle("", isOn: launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(PourColor.amber)
                    }
                }

                settingsCard(title: "Privacy") {
                    VStack(alignment: .leading, spacing: PourSpace.sm) {
                        HStack {
                            VStack(alignment: .leading, spacing: PourSpace.xxs) {
                                Text("Enable History")
                                    .font(PourFont.body(13))
                                    .foregroundStyle(PourColor.text)
                                Text("Save transcripts locally for up to five days.")
                                    .font(PourFont.callout())
                                    .foregroundStyle(PourColor.textMuted)
                            }
                            Spacer()
                            Toggle("", isOn: historyEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(PourColor.amber)
                        }
                        Divider().overlay(PourColor.borderHairline)
                        HStack {
                            Text("Delete every saved transcript from this Mac.")
                                .font(PourFont.callout())
                                .foregroundStyle(PourColor.textMuted)
                            Spacer()
                            Button("Clear History", role: .destructive) {
                                confirmingHistoryClear = true
                            }
                            .disabled(model.history.entries.isEmpty)
                        }
                    }
                }

                settingsCard(title: "Microphone") {
                    VStack(alignment: .leading, spacing: PourSpace.sm) {
                        HStack {
                            Text("Input device")
                                .font(PourFont.body(13))
                                .foregroundStyle(PourColor.text)
                            Spacer()
                            Picker("", selection: microphoneDeviceID) {
                                Text("System Default").tag(Optional<String>.none)
                                ForEach(availableMicrophones) { device in
                                    Text(device.name).tag(Optional(device.id))
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 200)
                            .tint(PourColor.blue500)
                        }
                        Text("Which mic Pour listens to. Follows the system default unless you pick one here.")
                            .font(PourFont.callout())
                            .foregroundStyle(PourColor.textMuted)
                    }
                }

                settingsCard(title: "Hotkey") {
                    VStack(alignment: .leading, spacing: PourSpace.sm) {
                        HStack {
                            Text("Push-to-talk key")
                                .font(PourFont.body(13))
                                .foregroundStyle(PourColor.text)
                            Spacer()
                            HotkeyRecorder(keyCode: hotkeyKeyCode) { newCode in
                                var config = model.settings.hotkeyConfig
                                config.keyCode = newCode
                                model.setHotkey(config)
                            }
                        }
                        Divider().overlay(PourColor.borderHairline)
                        HStack {
                            Text("Style")
                                .font(PourFont.body(13))
                                .foregroundStyle(PourColor.text)
                            Spacer()
                            Picker("", selection: interactionMode) {
                                Text("Hold to talk").tag(PushToTalkHotkey.InteractionMode.holdToTalk)
                                Text("Press to start/stop").tag(PushToTalkHotkey.InteractionMode.toggle)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 260)
                        }
                        Text(interactionModeHint)
                            .font(PourFont.callout())
                            .foregroundStyle(PourColor.textMuted)
                    }
                }

                settingsCard(title: "Model") {
                    VStack(alignment: .leading, spacing: PourSpace.md) {
                        HStack {
                            Text("Engine")
                                .font(PourFont.body(13))
                                .foregroundStyle(PourColor.text)
                            Spacer()
                            Picker("", selection: engineKind) {
                                Text("Apple").tag(EngineKind.apple)
                                Text("Parakeet").tag(EngineKind.parakeet)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 200)
                        }
                        Text(engineHint)
                            .font(PourFont.callout())
                            .foregroundStyle(PourColor.textMuted)

                        Divider().overlay(PourColor.borderHairline)

                        HStack {
                            Text("Language")
                                .font(PourFont.body(13))
                                .foregroundStyle(PourColor.text)
                            Spacer()
                            Picker("", selection: localeIdentifier) {
                                ForEach(availableLocales, id: \.identifier) { locale in
                                    Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                        .tag(locale.identifier)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 200)
                            .tint(PourColor.blue500)
                        }
                        .disabled(model.settings.engineKind != .apple)
                        .opacity(model.settings.engineKind == .apple ? 1 : 0.4)

                        if let downloadProgress {
                            ProgressView(value: downloadProgress)
                                .tint(PourColor.amber)
                            Text("Downloading speech model\u{2026} \(Int(downloadProgress * 100))%")
                                .font(PourFont.callout())
                                .foregroundStyle(PourColor.textMuted)
                        }
                    }
                }

                settingsCard(title: "Refinement") {
                    VStack(alignment: .leading, spacing: PourSpace.md) {
                        HStack {
                            VStack(alignment: .leading, spacing: PourSpace.xxs) {
                                Text("Processing mode").font(PourFont.body(13)).foregroundStyle(PourColor.text)
                                Text(accuracyHint).font(PourFont.callout()).foregroundStyle(PourColor.textMuted)
                            }
                            Spacer()
                            Picker("", selection: accuracyMode) {
                                ForEach(AccuracyMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden().frame(width: 150)
                        }

                        HStack {
                            Text("Cleanup strength").font(PourFont.body(13)).foregroundStyle(PourColor.text)
                            Spacer()
                            Picker("", selection: cleanupLevel) {
                                Text("Off").tag(CleanupLevel.off)
                                Text("Conservative").tag(CleanupLevel.conservative)
                                Text("Balanced").tag(CleanupLevel.balanced)
                                Text("Aggressive").tag(CleanupLevel.aggressive)
                            }
                            .labelsHidden().frame(width: 150)
                        }

                        Divider().overlay(PourColor.borderHairline)
                        refinementToggle("Remove safe fillers", detail: "Removes standalone um, uh, erm, and ah.", value: refinementFlag(\.removeFillers))
                        refinementToggle("Collapse repetitions", detail: "Turns “the the report” into “the report.”", value: refinementFlag(\.removeRepetitions))
                        refinementToggle("Resolve false starts", detail: "Uses explicit cues such as “actually” and “no.”", value: refinementFlag(\.cleanFalseStarts))
                        refinementToggle("Spoken punctuation", detail: "Understands “comma,” “new line,” and related commands.", value: refinementFlag(\.spokenPunctuation))
                        refinementToggle("Format spoken lists", detail: "Turns first/second/finally sequences into bullets.", value: refinementFlag(\.automaticListFormatting))
                        refinementToggle("Expand change details", detail: "Opens original-versus-refined details automatically in History.", value: refinementFlag(\.showChangesBeforeInsertion))

                        VStack(alignment: .leading, spacing: PourSpace.xxs) {
                            Text("LIVE EXAMPLE").font(PourFont.caption()).foregroundStyle(PourColor.textDim)
                            Text("Um, send the the report comma new paragraph thanks")
                                .font(PourFont.mono(11)).foregroundStyle(PourColor.textDim).strikethrough(model.settings.removeFillers)
                            Text(refinementExample)
                                .font(PourFont.monoMedium(11)).foregroundStyle(PourColor.success)
                        }
                        .padding(PourSpace.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PourColor.surfacePanel2)
                        .clipShape(RoundedRectangle(cornerRadius: PourRadius.sm, style: .continuous))
                    }
                }

                settingsCard(title: "Application Profiles") {
                    VStack(alignment: .leading, spacing: PourSpace.md) {
                        Text("Override refinement for Messages, email, notes, or coding tools. Profiles are matched by bundle identifier.")
                            .font(PourFont.callout()).foregroundStyle(PourColor.textMuted)

                        ForEach(model.settings.appProfiles) { profile in
                            HStack(spacing: PourSpace.sm) {
                                Image(systemName: "app.badge.checkmark").foregroundStyle(PourColor.blue400)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).font(PourFont.body(13)).foregroundStyle(PourColor.text)
                                    Text("\(profile.bundleIdentifier) · \(profile.preset.rawValue.capitalized)")
                                        .font(PourFont.mono(10)).foregroundStyle(PourColor.textDim)
                                }
                                Spacer()
                                Button("Remove", role: .destructive) { model.removeAppProfile(profile) }
                                    .buttonStyle(.borderless)
                            }
                        }

                        Divider().overlay(PourColor.borderHairline)
                        TextField("App name", text: $profileName)
                        TextField("Bundle identifier (for example com.apple.MobileSMS)", text: $profileBundleID)
                        HStack {
                            Picker("Profile", selection: $profilePreset) {
                                ForEach(AppProfilePreset.allCases, id: \.self) { preset in
                                    Text(preset.rawValue.capitalized).tag(preset)
                                }
                            }
                            Spacer()
                            Button("Add Profile") { addProfile() }
                                .buttonStyle(.pourPrimary)
                                .disabled(profileBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                footer
            }
            .padding(PourSpace.lg)
            .frame(maxWidth: 480, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Settings")
        .task {
            availableLocales = await AppleSpeechEngine.supportedLocales()
        }
        .task { refreshMicrophones() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            refreshMicrophones()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            refreshMicrophones()
        }
        .confirmationDialog(
            "Clear all transcription history?",
            isPresented: $confirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                model.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every saved transcript from this Mac.")
        }
    }

    @ViewBuilder
    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PourSpace.sm) {
            Text(title.uppercased())
                .font(PourFont.caption())
                .foregroundStyle(PourColor.textDim)
            content()
        }
        .pourCard(padding: PourSpace.lg)
    }

    private var footer: some View {
        HStack(spacing: PourSpace.xxs) {
            Text("A Brewed AI passion project ·")
                .foregroundStyle(PourColor.textDim)
            Link("brewed-ai.com", destination: URL(string: "https://brewed-ai.com/")!)
                .foregroundStyle(PourColor.blue500)
        }
        .font(PourFont.callout())
    }

    private var hotkeyKeyCode: Binding<CGKeyCode> {
        Binding(
            get: { model.settings.hotkeyKeyCode },
            set: { _ in } // HotkeyRecorder reports through onChange; AppModel is the source of truth.
        )
    }

    private var interactionMode: Binding<PushToTalkHotkey.InteractionMode> {
        Binding(
            get: { model.settings.interactionMode },
            set: { model.setInteractionMode($0) }
        )
    }

    private var interactionModeHint: String {
        switch model.settings.interactionMode {
        case .holdToTalk:
            "Hold this key to dictate, anywhere. Click, then press the key you want. Let go to finish."
        case .toggle:
            "Press once to start dictating, press again to stop. Esc still cancels."
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { model.settings.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private func refreshMicrophones() {
        let devices = MicrophoneCapture.availableDevices()
        // Keep the current selection visible in the list even if it just went
        // offline, so the picker doesn't silently snap back to System Default.
        if let selected = model.settings.microphoneDeviceUniqueID,
           !devices.contains(where: { $0.id == selected }) {
            availableMicrophones = devices + [MicrophoneDevice(id: selected, name: "Unavailable Device")]
        } else {
            availableMicrophones = devices
        }
    }

    private var microphoneDeviceID: Binding<String?> {
        Binding(
            get: { model.settings.microphoneDeviceUniqueID },
            set: { model.setMicrophoneDevice($0) }
        )
    }

    private var historyEnabled: Binding<Bool> {
        Binding(
            get: { model.settings.historyEnabled },
            set: { model.setHistoryEnabled($0) }
        )
    }

    private var engineKind: Binding<EngineKind> {
        Binding(
            get: { model.settings.engineKind },
            set: { newValue in
                Task {
                    downloadProgress = 0
                    await model.setEngineKind(newValue) { fraction in
                        Task { @MainActor in downloadProgress = fraction }
                    }
                    downloadProgress = nil
                }
            }
        )
    }

    private var engineHint: String {
        switch model.settings.engineKind {
        case .apple:
            "Apple's on-device SpeechAnalyzer. Models are managed by macOS."
        case .parakeet:
            "FluidAudio's Parakeet, on-device. Downloads its own model on first use (needs " +
            "network once) and is English-only for now, so the language picker is disabled."
        }
    }

    private var localeIdentifier: Binding<String> {
        Binding(
            get: { model.settings.localeIdentifier },
            set: { newValue in
                Task {
                    downloadProgress = 0
                    await model.setLocale(newValue) { fraction in
                        Task { @MainActor in downloadProgress = fraction }
                    }
                    downloadProgress = nil
                }
            }
        )
    }

    private var cleanupLevel: Binding<CleanupLevel> {
        Binding(get: { model.settings.cleanupLevel }, set: { value in
            model.updateRefinement { $0.cleanupLevel = value }
        })
    }

    private var accuracyMode: Binding<AccuracyMode> {
        Binding(get: { model.settings.accuracyMode }, set: { value in
            model.updateRefinement { $0.accuracyMode = value }
        })
    }

    private func refinementFlag(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in
            model.updateRefinement { $0[keyPath: keyPath] = value }
        })
    }

    private func refinementToggle(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: PourSpace.xxs) {
                Text(title).font(PourFont.body(13)).foregroundStyle(PourColor.text)
                Text(detail).font(PourFont.callout()).foregroundStyle(PourColor.textMuted)
            }
            Spacer()
            Toggle("", isOn: value).labelsHidden().toggleStyle(.switch).tint(PourColor.amber)
        }
    }

    private var accuracyHint: String {
        switch model.settings.accuracyMode {
        case .fast: "Lowest latency with whitespace normalization only."
        case .accurate: "Applies your selected deterministic cleanup rules."
        case .smartLocal: "Adds contextual cleanup on this Mac; nothing is uploaded."
        }
    }

    private var refinementExample: String {
        guard model.settings.cleanupLevel != .off else { return "Um, send the the report comma new paragraph thanks" }
        let start = model.settings.removeFillers ? "Send" : "Um, send"
        let noun = model.settings.removeRepetitions ? "the report" : "the the report"
        let punctuation = model.settings.spokenPunctuation ? ",\n\n" : " comma new paragraph "
        return start + " " + noun + punctuation + "thanks"
    }

    private func addProfile() {
        let bundle = profileBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else { return }
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        model.saveAppProfile(AppProfile(
            bundleIdentifier: bundle,
            name: name.isEmpty ? bundle : name,
            preset: profilePreset
        ))
        profileBundleID = ""
        profileName = ""
        profilePreset = .standard
    }
}
