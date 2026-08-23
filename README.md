# Pour

Push-to-talk dictation for macOS. Hold **`** (backtick), talk, let go — the text lands in
whatever field you were already in. Dictation audio and text are processed on this Mac and
aren't uploaded by Pour. macOS may contact Apple to download required speech-model assets.

A free, open-source Brewed AI passion project. Pour is independent and is not affiliated with
Wispr Flow or Wispr AI.

---

## Requirements

- macOS 26 (Tahoe) or newer — Pour is built on the `SpeechAnalyzer` API introduced there
- Xcode 26 with the command line tools selected (`sudo xcode-select -s /Applications/Xcode.app`)
- Apple Silicon

## Install

Run the installer to check this Mac, download Pour's source into a temporary directory, build
it, install `Pour.app` in `~/Applications`, and launch it:

```sh
curl -fsSL https://raw.githubusercontent.com/Brewed-Craig/Pour/main/install.sh | bash
```

You can [review the installer](install.sh) before running it. The first install downloads and
compiles Pour's Swift dependencies, so it can take several minutes. The temporary source and
build files are removed when installation finishes; Xcode is still required because the app is
built locally. Run the same command again to update or repair the installation.

The installer uses the same signing selection as `build.sh`. Without a Developer ID or the free
local certificate described below, the build is ad-hoc signed and macOS may ask you to approve
Pour's permissions again after an update.

## Build and run

```sh
./build.sh doctor     # check the toolchain and find your signing identity
./build.sh run        # build, bundle, sign, launch in the foreground
```

`run` launches Pour in the foreground so you can see its logs. Quit with ⌃C, or from the
menu bar item.

### Signing (read this before the first run)

macOS ties the Accessibility grant to the app's **signed identity**. Ad-hoc signing produces
a new identity on every build, so Pour's hotkey and text injection will silently stop working
after each rebuild and you'll waste an afternoon debugging the wrong layer.

`build.sh` looks for a `Developer ID Application` certificate automatically, then falls back to
a certificate named exactly `Pour Local Code Signing`, then ad-hoc. If you have a paid Apple
Developer ID and more than one matching certificate, pin it:

```sh
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh run
```

#### No Apple Developer account? Make a free local certificate instead

A Developer ID costs $99/year and isn't needed just to stop the permission prompts on your own
Mac — a free self-signed certificate gives you the same *stable identity* that Accessibility
grants are keyed to. It won't pass Gatekeeper on another machine and it isn't for distribution,
but for building and running Pour locally it's all you need.

1. Open **Keychain Access** (`/Applications/Utilities/Keychain Access.app`).
2. Menu bar: **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name it **exactly** `Pour Local Code Signing` — `build.sh` looks for that name.
4. **Identity Type:** Self Signed Root
5. **Certificate Type:** Code Signing
6. Optionally check **Let me override defaults** and extend the validity period (the default is
   1 year; 10 years avoids having to redo this).
7. Click **Create**, then click through the rest of the assistant with the defaults.
8. Find the new certificate in the **login** keychain, double-click it, expand **Trust**, and
   set **Code Signing** to **Always Trust**. This stops macOS prompting to unlock your keychain
   every time `build.sh` signs the app.

Verify it's picked up:

```sh
./build.sh doctor
# Signing
#   identity   Pour Local Code Signing
```

From here, every `./build.sh run` signs with the same identity, so macOS remembers your
Accessibility and Microphone grants across rebuilds — no more re-approving Pour every time you
change the code.

To re-test the permission flow from scratch:

```sh
./build.sh reset
```

## First launch

1. macOS asks for **Microphone** access → allow.
2. Pour asks for **Accessibility** access and opens System Settings → add and enable Pour.
3. Choose **Retry Setup** from the menu bar item.
4. On the very first run the OS downloads the speech model for your locale. The menu shows
   progress. This happens once.

The menu bar cup tells you the state: outline = ready, amber = listening, blue = transcribing,
green = delivered, red triangle = something's blocked (the menu says what).

## How the hotkey behaves

Two interaction styles, switchable in Settings → Hotkey → Style:

**Hold to talk** (default)
- **Hold `** — dictates while held.
- **Tap ` quickly** (under 220ms) — types a literal backtick, as normal. You don't lose the key.
- **Esc while holding** — discards the dictation.

**Press to start/stop**
- **Press `** — starts dictating.
- **Press ` again** — stops and delivers.
- **Esc while dictating** — discards it.
- The key is fully reserved in this mode — every press means start or stop, so there's no
  literal-character fallback.

**⌘` / ⌃` / ⌥`** always pass straight through, in either mode — those are real shortcuts.

Change the key itself from Settings (click the field, then press a key), or set the default in
`Sources/HotkeyKit/PushToTalkHotkey.swift` → `Config.keyCode`.

## Privacy

- Pour starts the microphone engine after permission is granted and keeps a rolling 300 ms
  pre-roll in memory so the first syllable is not clipped. The buffer is never written to disk;
  only the pre-roll and audio captured while the key is held reach Apple's on-device analyzer.
- Pour does not upload dictation audio or transcript text. macOS may download an OS-managed
  speech model from Apple when a locale is used for the first time.
- Transcripts and target-app names are stored locally in
  `~/Library/Application Support/Pour/history.json` and automatically removed after five days.
  History can be disabled or cleared immediately in Settings.
- Aggregate usage totals, including the names and bundle identifiers of apps you dictate into,
  are stored locally in `~/Library/Application Support/Pour/usage-stats.json`.
  On upgrade, retained history is used to restore app names for existing totals. Usage older than
  the five-day history window stays under `Unknown App` rather than being assigned incorrectly.
- History and dictionary files use owner-only permissions; dictionary entries and settings stay
  in the current macOS user account.
- When direct Accessibility insertion is unavailable, Pour briefly places the transcript on the
  clipboard for about 370 ms, pastes it, and restores the previous clipboard contents if nothing
  else changed them. Pour marks this item as transient and concealed for compatible clipboard
  managers, but another process actively monitoring the clipboard could still read it during that
  brief window.

---

## Layout

```
Sources/
  Pour/              menu bar app — status item, app delegate. Thin on purpose.
  FlowCore/          state machine, permissions. Owns the hot path.
  HotkeyKit/         CGEventTap push-to-talk with tap-to-type passthrough
  AudioCapture/      always-warm AVAudioEngine with a 300ms pre-roll buffer
  TranscriptionKit/  SpeechEngine protocol + AppleSpeechEngine
  InjectKit/         Accessibility insert → clipboard paste fallback
  DictionaryKit/     personal vocabulary, corrections, and conservative risk warnings
  HistoryKit/        local transcript history and aggregate usage stats
  DesignKit/         reusable visual components and bundled fonts
```

Two design decisions worth knowing before you edit anything:

**The mic never stops.** Starting `AVAudioEngine` on key-down costs 150–250ms and clips your
first syllable. It runs from launch instead, converting continuously, and key-down just opens
a gate — flushing 300ms of pre-roll so the start of the word isn't lost.

**Everything goes through one serial command loop.** `DictationController` processes press /
release / cancel one at a time. Press and release can arrive milliseconds apart while
`beginUtterance` is still awaiting, and without serialization that race eats the first
dictation of every session.

## Included now

- Menu-bar controls and a configurable push-to-talk hotkey — hold-to-talk or press-to-toggle
- Live non-activating HUD with a level-reactive waveform
- Five-day searchable local transcription history
- Summary stats plus a per-app usage chart with app icons
- Personal vocabulary and correction dictionary
- Locale/model picker and settings window
- Launch at Login (`SMAppService`)

## Possible next steps

- **RefineKit** — the cleanup pass (filler removal, backtrack resolution, list formatting) via
  a local MLX model, plus personal dictionary and snippets. Hooks in at the marked spot in
  `DictationController.finishCapture()`.
- Per-app profiles, an engine picker, and a notarized DMG for distribution beyond your own Mac.

## Notes

- Swift 5 language mode is deliberate (`Package.swift`). Strict concurrency checking across
  CoreGraphics event taps and `AVAudioEngine` callbacks still needs focused work.
- Not sandboxed, and can't be — `CGEventTap` and the Accessibility API don't work inside the
  App Sandbox. Distribution is a notarized DMG.
- `TextInjector.pasteOnlyBundleIDs` lists apps whose Accessibility text-setting is unreliable
  (Electron, Chromium). Add to it as you find more; the menu's last-transcript line tells you
  which strategy each dictation used.

## Licenses

Pour's source code is available under the [MIT License](LICENSE).
Bundled fonts have their own SIL Open Font License terms; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
