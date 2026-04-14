# AGENTS.md — instructions for AI coding agents

This file tells AI coding agents (Claude Code, Codex, Cursor, etc.) how to set up, run, and extend coshot.

## What coshot is

A native macOS overlay: `⌥Space` summons a floating panel, ScreenCaptureKit grabs the screen, Vision runs local OCR, Cerebras streams an answer, `⌘↩` pastes it back into the previous app. Native SwiftUI + AppKit, ~460KB binary, SPM executable wrapped into a `.app` bundle by `build-app.sh`.

## Setup for a new user — the ONLY interactive steps

A fresh user needs exactly **three** things from you as the agent. Do not add more steps.

1. **Ask the user for their Cerebras API key.**
   - Format: `csk-…`
   - Get one free at https://cloud.cerebras.ai
   - Do NOT hardcode it anywhere. Store it in Keychain with:
     ```bash
     security add-generic-password -U -s dev.coshot.cerebras -a api-key -w '<KEY>'
     ```
   - The app reads it via `Keychain.load()` (service `dev.coshot.cerebras`, account `api-key`). A `COSHOT_CEREBRAS_KEY` env var works as a dev fallback.

2. **Tell the user to grant Screen Recording permission.**
   - Trigger by pressing `⌥Space` once after launch → macOS will prompt.
   - If it fails silently, open the pane directly:
     ```bash
     open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
     ```
   - After toggling coshot on, **quit and relaunch** — Screen Recording approval only takes effect on app restart.

3. **Tell the user to grant Accessibility permission.**
   - Triggered automatically the first time `⌘↩` fires (the synthetic ⌘V paste).
   - Direct pane: `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`
   - No restart needed after approving.

Nothing else is required. No config files, no env vars, no extra installs.

## Build & run

```bash
./build-app.sh         # produces coshot.app
open coshot.app        # or: mv coshot.app /Applications && open /Applications/coshot.app
```

Dev loop (no .app bundle, reads the env var fallback):

```bash
export COSHOT_CEREBRAS_KEY=csk-...
swift run
```

Note: running `swift run` directly will NOT get Screen Recording permission — the binary isn't in a `.app` bundle so TCC can't track it. Use `./build-app.sh && open coshot.app` for any capture-path testing.

To reset permissions during dev:

```bash
tccutil reset ScreenCapture dev.coshot.app
tccutil reset Accessibility dev.coshot.app
```

To relaunch cleanly:

```bash
pkill -f "coshot.app/Contents/MacOS/coshot"
open coshot.app
```

## Architecture map

```
Sources/coshot/
├── App.swift            @main + NSApplication bootstrap (accessory policy)
├── AppDelegate.swift    status bar menu + hotkey wiring
├── HotkeyMonitor.swift  Carbon RegisterEventHotKey — ⌥Space
├── OverlayPanel.swift   NSPanel subclass + controller (show/hide, key events, LLM dispatch)
├── OverlayView.swift    SwiftUI root content
├── CommandModeView.swift QWERTY keyboard heatmap
├── OverlayState.swift   @Observable state
├── Capture.swift        ScreenCaptureKit + Vision OCR
├── CerebrasClient.swift streaming SSE
├── PromptLibrary.swift  JSON persistence at ~/Library/Application Support/coshot/prompts.json
├── Paster.swift         CGEventPost ⌘V
├── Keychain.swift       Security framework wrapper
└── Resources/prompts.default.json  seed prompts
```

## Load-bearing details (do not change without care)

- **`NSPanel` with `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`** — this is what lets the overlay float over fullscreen apps. Stock `alwaysOnTop` does not work here.
- **Carbon `RegisterEventHotKey`** — the only reliable system-wide hotkey API. `NSEvent.addGlobalMonitorForEvents` cannot consume the key event.
- **`SCContentFilter(display:excludingApplications:…)`** must exclude coshot's own bundle ID, otherwise the overlay leaks into the capture.
- **`SCScreenshotManager.captureImage`** (macOS 14+) is the fast single-shot API — do not use `SCStream` for one-off captures.
- **Paste flow:** hide panel → 120ms delay → `CGEventPost` synthetic ⌘V. The delay lets the previous app regain focus. Less than that and the event goes to coshot.
- **Clipboard restore:** after pasting, the prior clipboard string is restored after 1s. If this is racy on some apps, bump the delay — do not remove the restore.
- **File is named `App.swift`, not `main.swift`** — `@main` attribute is incompatible with top-level code, so the entry point must live in a non-`main.swift` file.

## Extending

- **Add a prompt:** edit `~/Library/Application Support/coshot/prompts.json`. Coshot re-reads on every fire. No rebuild.
- **Change the hotkey:** `AppDelegate.applicationDidFinishLaunching` → `hotkey.register(keyCode: ..., modifiers: ...)`. Use `kVK_*` constants from `Carbon.HIToolbox`.
- **Add a model:** set `model` per prompt in `prompts.json`. Cerebras valid IDs include `llama3.1-8b`, `llama3.3-70b`, `qwen-3-32b`. Default is `llama3.1-8b` (fastest).
- **Swap providers:** replace `CerebrasClient.swift`. It's ~60 lines, OpenAI-compatible SSE, easy to retarget at Groq/OpenAI/Ollama.

## Things NOT to do

- Don't commit `.env.local`, `.build/`, or `coshot.app/` — they're in `.gitignore` for a reason.
- Don't hardcode the API key in any Swift file. Keychain only.
- Don't switch to Electron/Tauri. The whole point of this project is the sub-1.5s capture → paste loop that only native APIs deliver.
- Don't add a README "quickstart" section that bypasses the three-step setup above. Users who skip Screen Recording approval will hit `TCC declined` and think the app is broken.
