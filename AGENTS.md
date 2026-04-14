# AGENTS.md — instructions for AI coding agents

This file tells AI coding agents (Claude Code, Codex, Cursor, etc.) how to set up, run, ship, and extend coshot.

## What coshot is

A native macOS overlay: `⌥Space` summons a floating panel, ScreenCaptureKit grabs the screen, Vision runs local OCR, the user taps `a/s/d/f/g` for a prompt, Cerebras streams an answer, coshot auto-pastes it back into the previous app on stream end. Native SwiftUI + AppKit, ~460KB binary, SPM executable wrapped into a `.app` bundle, Developer-ID signed, notarized by Apple, auto-updates every 60 seconds from GitHub Releases.

## Setup for a new user — the ONLY interactive steps

A fresh user needs exactly **three** things from you as the agent. Do not add more steps.

1. **Install the latest notarized build.** One line:
   ```bash
   curl -L https://github.com/Aradotso/coshot/releases/latest/download/coshot.zip -o /tmp/c.zip && unzip -o /tmp/c.zip -d /Applications/ && open /Applications/coshot.app
   ```
   The app is signed with Ara's Developer ID and notarized — no `xattr` quarantine strip needed. From this install on, coshot auto-updates itself every 60 seconds.

2. **Ask the user for their Cerebras API key.**
   - Format: `csk-…`
   - Get one free at https://cloud.cerebras.ai
   - Do NOT hardcode it anywhere. Either (a) tell them to use the ⚡ menu bar item "Set Cerebras API Key…", or (b) store it directly in their Keychain with:
     ```bash
     security add-generic-password -U -s dev.coshot.cerebras -a api-key -w '<KEY>'
     ```
   - The app reads it via `Keychain.load()` (service `dev.coshot.cerebras`, account `api-key`). A `COSHOT_CEREBRAS_KEY` env var works as a dev fallback.

3. **Tell the user to grant Screen Recording + Accessibility.**
   - Screen Recording: press `⌥Space` once → macOS prompts → approve in **System Settings → Privacy & Security → Screen Recording** → quit and relaunch coshot (Screen Recording approval requires a restart). Direct pane:
     ```bash
     open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
     ```
   - Accessibility: triggered automatically on first auto-paste after a successful Cerebras response → approve in **System Settings → Privacy & Security → Accessibility**. No restart needed. Direct pane:
     ```bash
     open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
     ```

Nothing else is required. No config files, no env vars, no extra installs, no manual updates ever again.

## Shipping a new version

This is the primary maintainer workflow. One command:

```bash
./release.sh           # auto-bumps patch version
./release.sh 0.2.0     # explicit version
SKIP_NOTARIZE=1 ./release.sh   # only if Apple's notary service is down
```

Total time per release: ~60-90 seconds. Teammates' running coshot instances detect the new release within 60 seconds and prompt with an "Install & Relaunch" dialog.

### What release.sh does

1. Pulls Apple signing secrets from Railway (`Ara Backend / prd / mac-setup` service) — 6 variables:
   - `APPLE_CODESIGN_DEVELOPER_ID_IDENTITY` — "Developer ID Application: SVEINUNG MYHRE (6N57FMKAZW)"
   - `APPLE_CODESIGN_P12_CERTIFICATE_B64` — base64-encoded p12
   - `APPLE_CODESIGN_P12_CERTIFICATE_PASSWORD`
   - `APPLE_DEVELOPER_ACCOUNT_EMAIL` — `s-myhre@outlook.com`
   - `APPLE_DEVELOPER_APP_SPECIFIC_PASSWORD`
   - `APPLE_DEVELOPER_TEAM_ID` — `6N57FMKAZW`
2. Imports the p12 into the releasing developer's login keychain (idempotent — skips if already there)
3. Bumps `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`
4. `swift build -c release`
5. `./build-app.sh` → wraps binary + `Info.plist` + resource bundle into `coshot.app`
6. **Strips `com.apple.provenance` xattrs and AppleDouble `._*` files** — critical. macOS 14+ auto-tags files with provenance xattrs; if not stripped, ditto/zip packs them as AppleDouble inside the archive, which extract as real `._` files on install, invalidate the code-signature manifest, and trigger Gatekeeper's "coshot is damaged" warning.
7. `codesign --force --deep --timestamp --options runtime` with Developer ID
8. `/usr/bin/zip -qry coshot.zip coshot.app` — not ditto, to avoid re-introducing AppleDouble
9. `xcrun notarytool submit --wait` → Apple's notary service (typically 30-90s)
10. `xcrun stapler staple coshot.app` → embeds the notarization ticket into the bundle
11. Re-zips the stapled bundle
12. `git commit` the Info.plist bump, `git tag -f v$VERSION`, `git push --tags`
13. `gh release create v$VERSION coshot.zip --repo Aradotso/coshot`

### One-time setup per release machine

```bash
cd ~/lab/coshot
railway link --project 5b03413d-9ace-4617-beb5-18b26ce5f339 \
             --environment prd \
             --service mac-setup
```

This persists per-directory so `railway variables --kv` works non-interactively from release.sh.

### Troubleshooting release.sh

| Error | Fix |
|---|---|
| `no APPLE_* vars in Railway — is the CLI logged in?` | Run `railway link` (above) in the coshot directory. |
| `HTTP 403: A required agreement is missing or has expired` | Sven (team admin) logs in to developer.apple.com, accepts any pending Apple Developer Program License Agreement updates, opens Xcode once, waits 10-15 min, retry. |
| `coshot is damaged and can't be opened` on install | Provenance xattr / AppleDouble regression. Verify `release.sh` still runs `xattr -cr coshot.app` before signing and uses `/usr/bin/zip -qry`, not `ditto`. |
| `Team is not yet configured for notarization` | Apple-side issue on the developer account. Contact Apple DTS via developer.apple.com Support. |
| `security: SecKeychainItemImport: Unknown format in import` | p12 decode broken. Don't create an ephemeral keychain — use the login keychain directly (the script already does this). |

## Auto-update internals

`UpdateChecker.swift` polls `https://api.github.com/repos/Aradotso/coshot/releases/latest` every 60 seconds while the app is running. On a newer `tag_name`, it shows an alert. On "Install & Relaunch":

1. Downloads the `coshot.zip` asset to `/tmp/`
2. Writes a bash helper script to `/tmp/coshot-update.sh`
3. Spawns the helper via `Process()` (detached from coshot's lifecycle)
4. Calls `NSApp.terminate(nil)`
5. The helper waits for coshot's PID to exit (up to 12s), unzips into `/Applications/coshot.app`, strips `com.apple.quarantine`, and relaunches

**Security model:** we don't sign the appcast ourselves (there is no appcast). The downloaded `.app` is signed with Ara's Developer ID and stapled with an Apple notarization ticket. Gatekeeper verifies both on every launch, so a tampered zip on GitHub would refuse to run. The trust chain is: GitHub TLS → HTTPS → Apple Developer ID → notarization ticket.

**Rate limits:** GitHub allows 60 unauthenticated requests/hour per IP. At 60s polling that's exactly 60/hour — on the edge. If multiple devices on the same NAT hit the limit, checks silently fail and resume on the next minute. Don't poll faster than 60s without adding an auth token.

**Dismissal:** clicking "Later" sets an in-memory `dismissedVersion` flag so the poll doesn't re-prompt every minute. It resets on app relaunch (in-memory only, not persisted).

## Build & run for dev iteration

```bash
./build-app.sh         # produces unsigned coshot.app (ad-hoc signed only)
open coshot.app
```

For even faster iteration without bundling:

```bash
export COSHOT_CEREBRAS_KEY=csk-...
swift run
```

`swift run` WILL NOT pass Screen Recording TCC — the binary isn't in a `.app` bundle so macOS can't track the permission. Use `./build-app.sh && open coshot.app` for anything that needs capture. For signed builds that persist TCC across rebuilds, use `./release.sh`.

To reset permissions during dev:

```bash
tccutil reset ScreenCapture dev.coshot.app
tccutil reset Accessibility dev.coshot.app
```

To relaunch cleanly:

```bash
pkill -f "coshot.app/Contents/MacOS/coshot"
open /Applications/coshot.app
```

## Architecture map

```
Sources/coshot/
├── App.swift            @main entry, NSApplication bootstrap (accessory policy)
├── AppDelegate.swift    status bar menu, hotkey wiring, UpdateChecker.startPolling()
├── HotkeyMonitor.swift  Carbon RegisterEventHotKey — ⌥Space
├── OverlayPanel.swift   KeyablePanel (NSPanel subclass) + show/hide/run/auto-paste
├── OverlayView.swift    SwiftUI shell with status, OCR preview, 5 big keys, output
├── CommandModeView.swift HomeRowKeys — the big letter-key view
├── OverlayState.swift   @Observable state (prompts, output, status, lastKey)
├── Capture.swift        ScreenCaptureKit + Vision OCR
├── CerebrasClient.swift streaming SSE to api.cerebras.ai/v1/chat/completions
├── PromptLibrary.swift  JSON persistence at ~/Library/Application Support/coshot/
├── Paster.swift         CGEventPost synthetic ⌘V into the prior frontmost app
├── Keychain.swift       Security framework wrapper for the API key
├── UpdateChecker.swift  60s poll loop → GitHub Releases → download + helper swap
└── Resources/prompts.default.json   seeded prompts (a s d f g)
```

## Load-bearing details (do not change without care)

- **`NSPanel` with `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`** — the one mandatory trick to make the overlay float over fullscreen apps. Stock `alwaysOnTop` does not work.
- **Carbon `RegisterEventHotKey`** — the only reliable system-wide hotkey API. `NSEvent.addGlobalMonitorForEvents` cannot consume the key event.
- **`SCContentFilter(display:excludingApplications:…)`** must exclude coshot's own bundle ID, otherwise the overlay leaks into the capture.
- **`SCScreenshotManager.captureImage`** (macOS 14+) — fast single-shot API. Do not use `SCStream` for one-off captures.
- **Key event loop in `OverlayPanel.handleKey`** — all letter keys that match a prompt fire immediately with no command-mode gate. `Space` is not special. `Esc` hides the panel.
- **Auto-paste flow:** stream ends → 250ms pause (so user sees the full result) → `pasteOutput()` → `hide()` → 120ms delay (so previous app regains focus) → `CGEventPost` synthetic ⌘V. The two delays are load-bearing; shorter values send the event to the wrong app.
- **Clipboard restore:** after pasting, the prior clipboard string is restored after 1s. If this is racy on some apps, bump the delay — do not remove the restore.
- **File is named `App.swift`, not `main.swift`** — `@main` attribute is incompatible with top-level code, so the entry point must live in a non-`main.swift` file.
- **`release.sh` must strip xattrs before signing and use `/usr/bin/zip -qry`, not `ditto`** — see the release.sh troubleshooting table. Every rebuild collects new `com.apple.provenance` xattrs from the filesystem.
- **`UpdateChecker.startPolling` runs forever** in a detached `Task` — there is no cancellation path, and none is needed because it lives on the `shared` singleton for the lifetime of the process.

## Extending

- **Add a prompt:** edit `~/Library/Application Support/coshot/prompts.json`. Coshot re-reads on every summon (`OverlayController.show`). No rebuild.
- **Change the hotkey:** `AppDelegate.applicationDidFinishLaunching` → `hotkey.register(keyCode:modifiers:)`. Use `kVK_*` constants from `Carbon.HIToolbox`.
- **Add a model:** set `model` per prompt in `prompts.json`. Cerebras valid IDs include `llama3.1-8b`, `llama3.3-70b`, `qwen-3-32b`. Default is `llama3.1-8b` (fastest).
- **Swap providers:** replace `CerebrasClient.swift`. It's ~60 lines of OpenAI-compatible SSE, easy to retarget at Groq, OpenAI, Ollama, etc.
- **Change the update interval:** `UpdateChecker.pollInterval`. 60s is the floor without a GitHub auth token. Below that you'll hit rate limits.

## Things NOT to do

- Don't commit `.env.local`, `.build/`, `coshot.app/`, or `coshot.zip` — they're in `.gitignore` for a reason.
- Don't hardcode the API key in any Swift file. Keychain or env var only.
- Don't hardcode Apple signing secrets. They live in Railway `mac-setup` and are fetched at release time.
- Don't switch to Electron/Tauri. The whole point of this project is the sub-1.5s capture → paste loop that only native macOS APIs deliver.
- Don't replace `/usr/bin/zip -qry` in release.sh with `ditto -c -k --keepParent`. ditto packs `com.apple.provenance` xattrs as AppleDouble files inside the archive, which breaks the code-signature seal on install.
- Don't add a quickstart section to the README that bypasses Screen Recording / Accessibility approval. Users who skip those will hit TCC errors and think the app is broken.
- Don't poll GitHub faster than 60s without adding a `GITHUB_TOKEN` header. You'll hit the 60 req/hour IP rate limit and auto-updates will silently fail for everyone behind the same NAT.
