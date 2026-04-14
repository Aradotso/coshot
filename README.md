# coshot

The chatbot killer, open sourced. A minimal native macOS overlay that captures your screen, runs local OCR, and streams an answer from Cerebras in under a second — then pastes it back wherever you were typing.

`⌥Space` → **A** answer · **S** summarize · **D** rewrite · **F** fix grammar · **G** explain → auto-paste.

Built in native SwiftUI + AppKit, ~460KB binary, notarized by Apple, auto-updates from GitHub Releases within 60s of a new ship.

---

## Why

Every "ChatGPT for Mac" is either a 150MB Electron wrapper around a web view or a paid closed-source menubar app. Coshot is the opposite: a ~500 LOC Swift Package that talks directly to the fastest model on the fastest inference provider, captures via ScreenCaptureKit (the same API Apple uses), OCRs locally with the Vision framework (free, ~40ms), and pastes back with `CGEventPost`.

**Latency budget (M-series Mac, warm):**

| Stage              | Time      |
|--------------------|-----------|
| Hotkey → panel     | ~20ms     |
| ScreenCaptureKit   | ~60-120ms |
| Vision OCR         | ~40-80ms  |
| First token (Cerebras `llama3.1-8b`, ~2200 tok/s) | ~250ms |
| Typical full response | ~600-900ms |
| Auto-paste         | ~120ms    |

**Total: ~1.1-1.5s from hotkey press to pasted result. Zero clicks.**

---

## Install

One line. This is the only manual step you'll ever do:

```bash
curl -L https://github.com/Aradotso/coshot/releases/latest/download/coshot.zip -o /tmp/c.zip && unzip -o /tmp/c.zip -d /Applications/ && open /Applications/coshot.app
```

The app is Developer-ID signed and notarized by Apple, so Gatekeeper trusts it on first launch — no quarantine strip needed.

After install:

1. Menu bar ⚡ → **Set Cerebras API Key…** → paste your `csk-…` key from [cloud.cerebras.ai](https://cloud.cerebras.ai) (free tier is generous).
2. Press **⌥Space** — macOS prompts for Screen Recording. Approve it, then quit and relaunch coshot.
3. First **⌘V paste** triggers an Accessibility prompt — approve it too. No relaunch needed.

That's it. You're live.

---

## How to use it

1. You're typing in Slack/Gmail/Cursor/anywhere. You want AI help on whatever is on screen.
2. **`⌥Space`** — coshot floats a panel over your current app (works over fullscreen too). It captures the screen and runs OCR locally via Apple's Vision framework.
3. **Press a letter** — `a` answer, `s` summarize, `d` rewrite, `f` fix grammar, `g` explain. Coshot streams the response from Cerebras live into the panel.
4. **Auto-paste** — when the stream finishes, the panel hides, focus returns to your previous app, and the result is pasted at the cursor. Zero additional clicks.
5. **`Esc`** dismisses without pasting.

You can also click any of the five big keys in the panel to **edit** the prompt file in your default JSON editor — useful for tuning the instructions to your taste.

---

## Auto-update

Coshot polls `api.github.com/repos/Aradotso/coshot/releases/latest` every 60 seconds while running. When a new version ships, a dialog appears:

> **coshot v0.1.N is available**
> You're on v0.1.M. Install now and relaunch?
> [Install & Relaunch]  [Later]

Click Install → coshot downloads the signed zip, quits, a helper script swaps `/Applications/coshot.app` in place, and relaunches. Clicking Later silences the prompt for the current session; it comes back on next launch.

**Manual check:** ⚡ menu → **Check for Updates…**.

The trust chain: GitHub TLS delivers the zip → the unzipped `.app` is signed with Ara's Developer ID Application certificate and stapled with an Apple notarization ticket → macOS Gatekeeper verifies both on every launch. A tampered zip on GitHub would fail to launch.

---

## Customising prompts

Edit `~/Library/Application Support/coshot/prompts.json` — or click any key in the panel to open it automatically.

```json
{
  "prompts": [
    {
      "key": "a",
      "name": "Answer",
      "template": "Answer the question implicit in the following text directly. No preamble, no sign-off.",
      "model": "llama3.1-8b"
    }
  ]
}
```

| Field      | Meaning                                                                    |
|------------|----------------------------------------------------------------------------|
| `key`      | Single letter — the shortcut in the overlay. Default five are `a s d f g`. |
| `name`     | Shown on the big key in the panel.                                         |
| `template` | The system prompt. Coshot appends the OCR'd screen text as the user turn.  |
| `model`    | Optional override. Defaults to `llama3.1-8b`. Try `llama3.3-70b` for harder tasks. |

Coshot re-reads the file every time you summon the panel — no restart needed.

---

## Architecture

```
Sources/coshot/
├── App.swift            @main entry, NSApplication bootstrap (accessory policy)
├── AppDelegate.swift    status bar menu, hotkey wiring, updater poll
├── HotkeyMonitor.swift  Carbon RegisterEventHotKey — ⌥Space
├── OverlayPanel.swift   KeyablePanel (NSPanel subclass) + show/hide/run/paste
├── OverlayView.swift    SwiftUI shell with OCR preview + 5 big keys + output pane
├── CommandModeView.swift HomeRowKeys — the big keys
├── OverlayState.swift   @Observable state
├── Capture.swift        ScreenCaptureKit + Vision OCR
├── CerebrasClient.swift streaming SSE to api.cerebras.ai/v1/chat/completions
├── PromptLibrary.swift  JSON-backed prompts at ~/Library/Application Support/coshot/
├── Paster.swift         CGEventPost synthetic ⌘V into the prior frontmost app
├── Keychain.swift       Security framework wrapper for the API key
├── UpdateChecker.swift  60s poll of GitHub Releases, in-app install + relaunch
└── Resources/prompts.default.json   seeded prompt set (a s d f g)
```

**Key design choices:**

- **`NSPanel` with `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`** — the one mandatory macOS trick to make the overlay float over fullscreen apps.
- **Carbon `RegisterEventHotKey`** — the only reliable system-wide hotkey API.
- **`SCScreenshotManager.captureImage`** (macOS 14+) — the fastest one-shot capture. Excludes coshot's own windows so the overlay never appears in the OCR.
- **Vision's `VNRecognizeTextRequest`** with `.accurate + languageCorrection` — free, local, Neural-Engine accelerated.
- **Cerebras streaming** — `temperature: 0.2`, SSE. First-token latency dominates perceived speed.
- **`CGEventPost` ⌘V + clipboard restore** — auto-paste after stream ends, previous clipboard contents restored 1s later.
- **60-second poll updater, not Sparkle** — no framework embedding, no appcast signing. GitHub TLS + Apple notarization is the trust chain.

---

## Shipping new versions (maintainers)

The release pipeline is `./release.sh`. It pulls Apple signing credentials from Railway (`Ara Backend / prd / mac-setup` service), builds, signs with Developer ID, notarizes with Apple, staples the ticket, and uploads a zip to GitHub Releases. Teammates' running coshot instances pick it up within 60 seconds.

**One-time setup (per release machine):**

```bash
# Link this directory to Railway's mac-setup secrets
railway link --project 5b03413d-9ace-4617-beb5-18b26ce5f339 \
             --environment prd --service mac-setup
```

**Every release:**

```bash
./release.sh           # auto-bumps patch: 0.1.5 → 0.1.6
./release.sh 0.2.0     # explicit version
SKIP_NOTARIZE=1 ./release.sh   # only if Apple's notary service is down
```

~60-90 seconds per release (notarization is the bottleneck). The script:

1. Bumps `CFBundleShortVersionString` in `Info.plist`
2. `swift build -c release` + wraps into `coshot.app`
3. Strips `com.apple.provenance` xattrs and AppleDouble `._` files (critical — ditto packs them as AppleDouble inside the zip which breaks the code-signature seal)
4. `codesign --force --deep --timestamp --options runtime` with Developer ID
5. Submits the zip to Apple notary service via `notarytool submit --wait`
6. `stapler staple` the returned ticket onto the app
7. `/usr/bin/zip -qry` the stapled app (not ditto, to avoid AppleDouble)
8. Tags + pushes to git
9. `gh release create` with the notarized zip

**Secrets managed:** all Apple credentials live in Railway only. No local env files. The Developer ID cert is imported into the releasing developer's login keychain on first run and stays there (idempotent).

---

## Dev loop (without release.sh)

For fast Swift iteration without going through the full signing pipeline:

```bash
export COSHOT_CEREBRAS_KEY=csk-your-key
swift run
```

Capture will fail (the binary isn't in a `.app` bundle so TCC can't grant Screen Recording), but you can test UI, prompt library, and the Cerebras client by pre-seeding `state.ocrText` in `OverlayController.show`.

For any capture-path testing, use `./build-app.sh && open coshot.app`.

To reset permissions during dev:

```bash
tccutil reset ScreenCapture dev.coshot.app
tccutil reset Accessibility dev.coshot.app
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Capture failed: The user declined TCCs…` | System Settings → Privacy & Security → Screen Recording → toggle coshot on → quit & relaunch. |
| Paste does nothing | System Settings → Privacy & Security → Accessibility → toggle coshot on. No relaunch needed. |
| `⌥Space` does nothing | Grant Input Monitoring if prompted. Some macOS builds require it for Carbon hotkeys in `LSUIElement` apps. |
| `Error: Set your Cerebras API key` | Menu bar ⚡ → Set Cerebras API Key. |
| `HTTP 401` from Cerebras | Key rejected. Rotate at [cloud.cerebras.ai](https://cloud.cerebras.ai). |
| `coshot is damaged and can't be opened` after install | Old release with AppleDouble pollution. Fetch the latest; v0.1.4+ is sanitized. |
| Auto-update prompt never fires | GitHub API rate limit (60 req/hour per IP). Check: `curl https://api.github.com/rate_limit`. |
| Prompts file opens empty | Delete `~/Library/Application Support/coshot/prompts.json`, relaunch. |
| Release.sh: `HTTP 403 required agreement missing` | An Apple Developer admin must accept pending agreements at developer.apple.com, then open Xcode once. Wait 10-15 min for propagation. |

---

## License

MIT.

---

## Credits

Inspired by [coshot.dev](https://coshot.dev) — recreated open-source as a minimal native Mac app after a technology scout across the Tauri and Electron overlay ecosystem confirmed there's no mature OSS equivalent with this exact combination: global hotkey + ScreenCaptureKit + local OCR + streaming auto-paste + home-row command mode + 60-second auto-update.
