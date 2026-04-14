# coshot

The chatbot killer, open sourced. A minimal native macOS overlay that captures your screen, runs local OCR, and streams an answer from Cerebras in under a second — then pastes it back wherever you were typing.

`⌥Space` → **Space** → `r` rewrite · `s` summarize · `e` explain · `t` translate · `f` fix grammar · `c` code review · `a` answer · `p` pro tone · `k` key points · `q` questions → **⌘↩** paste.

Built in native SwiftUI + AppKit, ~460KB binary, zero dependencies.

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
| Paste back         | ~120ms    |

**Total: ~1.1-1.5s from hotkey press to pasted result.**

---

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode command line tools: `xcode-select --install`
- Swift 5.9+
- A free [Cerebras API key](https://cloud.cerebras.ai) (`csk-…`)

---

## Install

```bash
git clone https://github.com/Aradotso/coshot.git
cd coshot
./build-app.sh
mv coshot.app /Applications/
open /Applications/coshot.app
```

The build script runs `swift build -c release`, wraps the binary into a proper `.app` bundle with `Info.plist`, copies the prompts resource bundle into place, and ad-hoc signs it so macOS can track permissions across rebuilds.

---

## First launch (3 clicks)

1. **Menu bar** — look for the ⚡ icon. Click it → **Set Cerebras API Key…** → paste your `csk-…` → Save. (Stored in Keychain, service `dev.coshot.cerebras`.)
2. **Press ⌥Space** — first capture triggers a Screen Recording prompt. Approve it in **System Settings → Privacy & Security → Screen Recording**, then quit and relaunch coshot from the menu bar.
3. **⌘↩ to paste** for the first time — triggers an Accessibility prompt so coshot can synthesise `⌘V` in the app you were using. Approve it.

You're done. From now on: `⌥Space` anywhere, command mode, paste.

---

## How to use it

1. You're typing in Slack/Gmail/Cursor/anywhere. You want AI help on whatever is on screen.
2. **`⌥Space`** — coshot floats a panel over your current app (works over fullscreen too), captures the screen, runs OCR. The extracted text appears grey at the top of the panel.
3. **`Space`** — the panel flips into **command mode**. A QWERTY keyboard heatmap lights up the letters that are bound to prompts. Each key shows its prompt name.
4. **Press any letter** — coshot streams the response from Cerebras into the panel live.
5. **`⌘↩`** — coshot hides the panel, returns focus to your previous app, and pastes the result at the cursor.
6. **`Esc`** anywhere dismisses the overlay.

You can also click any prompt in the grid without ever entering command mode — same effect.

---

## Customising prompts

Edit `~/Library/Application Support/coshot/prompts.json` — or click **Open Prompts File** in the menu bar.

```json
{
  "prompts": [
    {
      "key": "r",
      "name": "Rewrite",
      "template": "Rewrite the following text to be clearer and more concise. Output only the rewritten text, no preamble.",
      "model": "llama3.1-8b"
    }
  ]
}
```

| Field      | Meaning                                                                    |
|------------|----------------------------------------------------------------------------|
| `key`      | Single letter. The key that fires this prompt in command mode.             |
| `name`     | Shown on the heatmap key and the clickable fallback grid.                  |
| `template` | The system prompt. Coshot appends the OCR'd screen text as the user turn. |
| `model`    | Optional override. Defaults to `llama3.1-8b`. Try `llama3.3-70b` for harder tasks. |

Coshot re-reads the file on every prompt fire — no restart needed.

---

## Architecture

```
Sources/coshot/
├── App.swift            @main entry, NSApplication bootstrap
├── AppDelegate.swift    status bar menu, hotkey wiring
├── HotkeyMonitor.swift  Carbon RegisterEventHotKey (⌥Space)
├── OverlayPanel.swift   KeyablePanel (NSPanel subclass) + controller
├── OverlayView.swift    SwiftUI shell with status, OCR preview, prompt grid, output
├── CommandModeView.swift the keyboard heatmap with live keycap highlighting
├── OverlayState.swift   @Observable state shared with the SwiftUI view
├── Capture.swift        ScreenCaptureKit + Vision OCR
├── CerebrasClient.swift streaming SSE to api.cerebras.ai/v1/chat/completions
├── PromptLibrary.swift  JSON-backed prompts with app-support persistence
├── Paster.swift         CGEventPost synthetic ⌘V into the prior frontmost app
├── Keychain.swift       Security framework wrapper for the API key
└── Resources/prompts.default.json   seeded prompt set
```

**Key design choices:**

- **`NSPanel` with `.canJoinAllSpaces + .fullScreenAuxiliary`** — this is the one mandatory macOS trick to make a floating window appear over fullscreen apps. Stock SwiftUI `.windowStyle` won't do it.
- **Carbon `RegisterEventHotKey`** — the only reliable system-wide hotkey API. `NSEvent.addGlobalMonitor` can't consume the event.
- **ScreenCaptureKit's `SCScreenshotManager.captureImage`** — the fastest one-shot capture API on macOS 14+. Excludes coshot's own windows so the overlay never appears in the OCR.
- **Vision's `VNRecognizeTextRequest`** with `.accurate + languageCorrection` — free, local, runs on the Neural Engine.
- **Cerebras streaming** — `temperature: 0.2`, SSE, first-token latency dominates perceived speed.
- **`CGEventPost` with clipboard restore** — synthetic ⌘V is the only way to paste into arbitrary apps without AppleScript per-app glue. Previous clipboard contents are restored 1 second after paste.
- **`@Observable` + `NSHostingView`** — zero-ceremony state sharing between AppKit panel and SwiftUI content.

---

## Dev workflow

```bash
# Fast iteration (no .app bundle, uses env var for the key)
export COSHOT_CEREBRAS_KEY=csk-your-key
swift run

# Full rebuild with proper permissions
./build-app.sh && open coshot.app
```

The env var is read as a fallback only — the Keychain value always wins if both are set.

To reset all permissions during dev:

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
| `⌥Space` does nothing | Some macOS builds require Input Monitoring for Carbon hotkeys in `LSUIElement` apps — grant it, or open an issue and we'll add a `CGEventTap` fallback. |
| `Error: Set your Cerebras API key` | Menu bar ⚡ → Set Cerebras API Key. |
| `HTTP 401` | Key is rejected — check [cloud.cerebras.ai](https://cloud.cerebras.ai) for quota and rotate if needed. |
| Panel doesn't appear over a fullscreen app | Ensure you're on macOS 14+. The `.fullScreenAuxiliary` collection behavior is the enabling flag. |
| Prompts file opens empty | Quit coshot, delete `~/Library/Application Support/coshot/prompts.json`, relaunch — it re-seeds from `Resources/prompts.default.json`. |

---

## License

MIT.

---

## Credits

Inspired by [coshot.dev](https://coshot.dev) — recreated open-source as a minimal native Mac app after a technology scout across the Tauri and Electron overlay ecosystem confirmed there's no mature OSS equivalent with this exact combination: global hotkey + ScreenCaptureKit + local OCR + streaming paste-back + command-mode keyboard prompts.
