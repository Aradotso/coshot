# MACAPP.md — Ara Mac App Playbook

A field guide for spinning up a new native macOS app on the **same company (Ara)** infrastructure as coshot: Developer ID signing, Apple notarization, GitHub Releases auto-update, ⌥-hotkey global intercept, Screen Recording + Accessibility + Keychain permissions, translucent SwiftUI overlay, Cerebras streaming, auto-paste.

This doc encodes every lesson learned while building coshot so the next app takes ~1 day instead of 3. Patterns are load-bearing — don't deviate without reading the "Gotchas" section.

---

## 0. Who to copy from

Start from **coshot** (`Aradotso/coshot`). All patterns below are live in that repo. Grep-hitting files are referenced inline, e.g. `Sources/coshot/PermissionGate.swift`.

Do **not** start from a fresh Xcode template — you'll lose the SPM simplicity, the build-app.sh wrapper pattern, and the release.sh that talks to Railway. Clone coshot, rip out the business logic, keep the scaffolding.

---

## 1. Stack at a glance

| Layer | Tech |
|---|---|
| Language | Swift 5.9+ |
| UI | SwiftUI (macOS 14+) + AppKit (NSPanel, NSStatusItem) |
| Build | Swift Package Manager (`executableTarget`) + a shell-script `.app` wrapper |
| Signing | Apple Developer ID Application, cert + p12 + app-specific password fetched from Railway `mac-setup` service at release time |
| Distribution | GitHub Releases (Aradotso org), signed+notarized `.zip` assets |
| Auto-update | Custom 60s poller against the GitHub Releases API (no Sparkle, no framework embedding) |
| LLM | Cerebras streaming SSE by default (`llama3.1-8b`, ~2200 tok/s). OpenAI-compatible so trivially retargetable. |
| Observability | `os.Logger` with a `dev.<app>.app` subsystem, filtered live via `log stream` |

---

## 2. File layout

```
<app>/
├── Package.swift                     SPM executable target
├── Info.plist                        Bundle metadata (no LSUIElement!)
├── build-app.sh                      Wraps SPM binary into a .app
├── release.sh                        Builds, signs, notarizes, ships to GitHub
├── AGENTS.md                         Instructions for AI agents
├── README.md                         User-facing docs
├── MACAPP.md                         This file
├── .gitignore                        .build/, .swiftpm/, coshot.app/, coshot.zip, .env.local
└── Sources/<app>/
    ├── App.swift                     @main entry + NSApplication bootstrap
    ├── AppDelegate.swift             Status bar, hotkey wiring, menu bar menu
    ├── HotkeyMonitor.swift           Carbon RegisterEventHotKey (⌥Space)
    ├── ListenMode.swift              CGEventTap for global letter-key intercept
    ├── PermissionGate.swift          TCC + silent polling + auto-relaunch
    ├── OverlayPanel.swift            NSPanel subclass + controller
    ├── OverlayView.swift             SwiftUI root + modal modes
    ├── CommandModeView.swift         BigKey tiles (single/double click)
    ├── OverlayState.swift            @Observable state
    ├── Capture.swift                 ScreenCaptureKit + Vision OCR
    ├── CerebrasClient.swift          Streaming SSE
    ├── PromptLibrary.swift           JSON-backed user config
    ├── Paster.swift                  CGEventPost ⌘V
    ├── Keychain.swift                SecItem wrapper
    ├── UpdateChecker.swift           GitHub Releases poller
    ├── MenuBarIcon.swift             Icon composer (with status dot)
    ├── Log.swift                     Shared os.Logger categories
    └── Resources/
        ├── prompts.default.json      Seeded config (if applicable)
        ├── AppIcon.icns              Dock + Finder icon
        ├── MenuBarIcon.png           18px status bar template
        └── MenuBarIcon@2x.png        36px retina
```

Not every app needs every file. Pick from this menu based on what your app does.

---

## 3. Package.swift — the executable target

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "myapp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "myapp",
            resources: [.process("Resources")]
        )
    ]
)
```

- **Target name must match the main file prefix** because SPM uses it to resolve `Bundle.module`.
- `.process("Resources")` auto-bundles PNGs, JSON, icons. They end up in `<target>_<target>.bundle`.
- **No dependencies.** coshot is zero-dep Swift. Adding Sparkle means framework embedding hell — the custom updater in this doc is 80 LOC and avoids it entirely.

---

## 4. App.swift — the entry point

The `@main` attribute is incompatible with top-level code in SPM, so **the entry file must not be named `main.swift`**.

```swift
// Sources/myapp/App.swift
import AppKit

@main
@MainActor
struct MyApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .regular: Dock icon, alt-tab, clean TCC registration.
        // .accessory: menu bar only, LSUIElement style.
        app.setActivationPolicy(.regular)
        app.run()
    }
}
```

**Pick `.regular` unless you have a reason not to.** `.accessory` (LSUIElement) causes:
- No Dock icon (confuses users)
- Missing from alt-tab (confuses users)
- Sometimes doesn't appear in Privacy & Security → Screen Recording until first SCShareableContent call
- Worse TCC registration — occasionally fails to show in Settings at all

If you truly want menu-bar-only, `.regular` + a hidden window still works and is less fragile than `.accessory`.

---

## 5. Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>myapp</string>
  <key>CFBundleExecutable</key><string>myapp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>dev.myapp.app</string>
  <key>CFBundleName</key><string>myapp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>myapp pastes generated text into the app you were last using.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

**Critical:**
- **No `LSUIElement`.** Leave it out. See the `.regular` discussion above.
- `CFBundleIconFile` points to `AppIcon` (without `.icns`). build-app.sh will copy `Resources/AppIcon.icns` into `Contents/Resources/`.
- Screen Recording and Accessibility **do not need Info.plist keys** on macOS 14+. TCC handles them at runtime.
- `NSAppleEventsUsageDescription` is for paste-back via CGEventPost. Required since Catalina-ish.

---

## 6. build-app.sh — wrap SPM binary into a .app

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "▶ building release binary…"
swift build -c release

BIN=".build/release/myapp"
APP="myapp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/myapp"
cp Info.plist "$APP/Contents/Info.plist"

# Copy the SPM resource bundle so Bundle.module resolves at runtime.
RBUNDLE=$(find .build -name "myapp_myapp.bundle" -type d -path "*release*" -print -quit || true)
if [ -n "${RBUNDLE:-}" ]; then
  rm -rf "$APP/Contents/Resources/myapp_myapp.bundle"
  cp -R "$RBUNDLE" "$APP/Contents/Resources/"
else
  echo "⚠ warning: resource bundle not found"
fi

# Copy .icns to top-level Resources for CFBundleIconFile resolution.
if [ -f Sources/myapp/Resources/AppIcon.icns ]; then
  cp Sources/myapp/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so TCC can track permissions during dev (release.sh replaces with Developer ID)
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ built $APP"
```

**Critical facts about SPM resource bundles:**
- The bundle name is `<target>_<target>.bundle` (e.g. `myapp_myapp.bundle`).
- It lives at `.build/arm64-apple-macosx/release/` — `-maxdepth 2` under `.build/release/` **misses it**. Use `find .build -name ... -path "*release*"`.
- `Bundle.module` looks for it at `Bundle.main.resourceURL` (= `.app/Contents/Resources/`), so you must copy it there, not into `MacOS/`.

---

## 7. PermissionGate.swift — TCC handling

This is the most subtle file in coshot. Read it before copying.

**Three permissions** you'll commonly need:
1. **Screen Recording** (ScreenCaptureKit) — requires **app restart** after granting
2. **Accessibility** (CGEventTap, CGEventPost) — takes effect on next process launch
3. **Input Monitoring** — sometimes needed for Carbon hotkeys in `LSUIElement` apps (not needed for `.regular`)

**Canonical pattern: silent poll, escalate after timeout.**

```swift
@MainActor
enum PermissionGate {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    private static var isPolling = false
    private static var isAlertShown = false

    /// Called from AppDelegate on launch.
    static func ensureGranted() {
        if !hasScreenRecording {
            _ = CGRequestScreenCaptureAccess()  // fires native dialog ONCE ever

            // Touch ScreenCaptureKit once so TCC registers the app in the
            // Screen Recording settings list even if the user dismissed
            // the native dialog without clicking Allow.
            Task.detached {
                _ = try? await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
            }

            startSilentPoll(escalateAfter: 8.0)
        }
    }

    private static func startSilentPoll(escalateAfter: TimeInterval) {
        if isPolling { return }
        isPolling = true
        let start = Date()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.4, repeating: 0.4)
        source.setEventHandler {
            if hasScreenRecording {
                source.cancel()
                isPolling = false
                relaunch()  // spawns helper, NSApp.terminate
                return
            }
            if Date().timeIntervalSince(start) >= escalateAfter {
                source.cancel()
                isPolling = false
                showFallbackAlert()
            }
        }
        source.resume()
    }
}
```

**Cardinal rules** (each learned the hard way):

1. **Never call `AXIsProcessTrustedWithOptions(prompt: true)` from a passive launch-time check.** Only from explicit user action (a "Grant" button click). Calling it every launch pops a duplicate "Accessibility Access" dialog each time the user relaunches, creating an unescapable loop.

2. **NSAlert's last-added button is the Cancel/Escape target.** If you add "Open Settings" then "Quit", Escape fires Quit and the user thinks the hotkey killed the app. Name the second button something benign like "Dismiss" and never call `NSApp.terminate` from the alert's cancel path.

3. **Use a GCD DispatchSource timer, not Timer, for polling during a modal.** `Timer.scheduledTimer` only fires in `.default` mode; during `NSAlert.runModal`, the run loop is in `.modalPanel` mode and your timer is frozen. `DispatchSource.makeTimerSource(queue: .main)` runs regardless.

4. **Screen Recording grants require an app restart** for the running process to see the change. Spawn a detached bash helper that waits for your PID to exit, then `/usr/bin/open "$APP"`. See `relaunch()` in `PermissionGate.swift`.

5. **tccutil reset before re-registering** when debugging TCC weirdness:
   ```bash
   tccutil reset ScreenCapture dev.myapp.app
   tccutil reset Accessibility dev.myapp.app
   ```

### Live permission status in config mode

Show it. Don't hide failures. coshot's config overlay has a `PermissionsPanel` that polls every 500ms (`DispatchSource` again) and displays three rows with green/red dots and "Grant" buttons. When the user toggles a permission in Settings, the dot flips to green within 500ms without them coming back to your app.

```swift
private func startConfigPolling() {
    configPollTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self = self else { return }
            self.state.hasScreenRecording = PermissionGate.hasScreenRecording
            self.state.hasAccessibility   = PermissionGate.hasAccessibility
            self.state.hasApiKey          = PermissionGate.hasApiKey
        }
    }
}
```

---

## 8. HotkeyMonitor.swift — global hotkey via Carbon

`NSEvent.addGlobalMonitorForEvents` **cannot consume** events — they leak to the frontmost app. Use Carbon's `RegisterEventHotKey` instead. Boilerplate:

```swift
import AppKit
import Carbon.HIToolbox

final class HotkeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) { self.callback = callback }

    func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return noErr }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { monitor.callback() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        var carbonMods: UInt32 = 0
        if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }

        let id = EventHotKeyID(signature: OSType(0x4D594150) /* 'MYAP' */, id: 1)
        RegisterEventHotKey(keyCode, carbonMods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// Usage:
hotkey = HotkeyMonitor { self.toggleListen() }
hotkey.register(keyCode: UInt32(kVK_Space), modifiers: [.option])
```

**No special permissions needed** for Carbon hotkeys in `.regular` apps. `LSUIElement` apps sometimes need Input Monitoring on certain macOS builds — another reason to use `.regular`.

---

## 9. ListenMode.swift — intercepting letter keys without stealing focus

**The problem:** You want `⌥Space A` to silently run a prompt and paste the result into the user's current text field. If you summon an NSPanel and `NSApp.activate`, focus is stolen and paste goes to the wrong app. If you don't activate, you can't receive key events normally.

**Solution:** `CGEventTap` at session level, armed only while "listening". When armed, intercept a/s/d/f/g keydown events and `return nil` to consume them. Non-armed mode → events pass through.

```swift
final class ListenModeTap {
    var onLetter: ((Character) -> Void)?
    var validLetters: Set<Character> = []  // refreshed from prompts.json each start()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Full a-z → Carbon virtual keycode map.
    private static let letterKeyCodes: [Int64: Character] = [
         0: "a",  1: "s",  2: "d",  3: "f",  4: "h",  5: "g",
         6: "z",  7: "x",  8: "c",  9: "v", 11: "b", 12: "q",
        13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k", 45: "n", 46: "m"
    ]

    var isActive: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let selfRef = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<ListenModeTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(event: event, type: type)
        }

        guard let machPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfRef
        ) else {
            Log.listen.error("CGEvent.tapCreate FAILED — Accessibility permission missing?")
            return
        }

        self.tap = machPort
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // Re-enable if the OS disabled the tap for taking too long.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let letter = Self.letterKeyCodes[keyCode],
              validLetters.contains(letter) else {
            return Unmanaged.passUnretained(event)  // pass through
        }

        DispatchQueue.main.async { [weak self] in self?.onLetter?(letter) }
        return nil  // consume — target app never sees this letter
    }
}
```

**Gotchas:**

- **Requires Accessibility permission.** `CGEvent.tapCreate` returns `nil` if denied. Guard against this and don't set your "listening" flag unless `tap` is non-nil — otherwise you show a green dot but intercept nothing.
- **`tap_disabled_by_timeout`:** if your callback ever takes longer than the OS's budget (~1s), the tap is disabled. Handle the timeout event type and re-enable it. Keep the callback fast — dispatch the heavy work to main async.
- **Consume selectively.** Coshot only swallows letters that are actually bound in `prompts.json`. Other letters pass through. Otherwise a user in sticky listen mode can't type normally.
- **Sticky vs one-shot:** coshot made listen mode sticky (⌥Space arms, another ⌥Space disarms). One-shot auto-disarm was confusing — users didn't know if they had to re-arm after each fire.

---

## 10. OverlayPanel.swift — NSPanel that doesn't steal focus

**The one mandatory trick** for floating UI that appears over fullscreen apps without activating your own app:

```swift
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

let p = KeyablePanel(
    contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
    styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
    backing: .buffered,
    defer: false
)
p.titlebarAppearsTransparent = true
p.titleVisibility = .hidden
p.standardWindowButton(.closeButton)?.isHidden = true
p.standardWindowButton(.miniaturizeButton)?.isHidden = true
p.standardWindowButton(.zoomButton)?.isHidden = true
p.isFloatingPanel = true
p.level = .floating
p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
p.isMovableByWindowBackground = true
p.backgroundColor = .clear
p.isOpaque = false
p.hasShadow = true
```

- **`.nonactivatingPanel`** is the key flag. Without it, showing the panel activates your app.
- **`.fullScreenAuxiliary`** lets the panel appear above other apps' fullscreen windows.
- **`.canJoinAllSpaces`** makes it follow the user across Spaces.
- **Level `.floating`** keeps it above regular app windows regardless of activation.

### Show without stealing focus

```swift
panel.orderFrontRegardless()  // shows visually, does NOT become key
```

vs.

```swift
NSApp.activate(ignoringOtherApps: true)
panel.makeKeyAndOrderFront(nil)  // becomes key, steals focus, activates app
```

Use `orderFrontRegardless` when you want a click-only overlay that preserves the target app's focus. Use `makeKeyAndOrderFront` for modal config overlays where you want the user's attention (triggered by Dock click, menu bar, etc.).

---

## 11. Capture.swift — ScreenCaptureKit + Vision OCR

```swift
import ScreenCaptureKit
import Vision

enum Capture {
    static func captureAndOCR() async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ... }

        // Exclude our own app's windows from the capture.
        let ourBundleID = Bundle.main.bundleIdentifier ?? ""
        let excludedApps = content.applications.filter { $0.bundleIdentifier == ourBundleID }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width  = Int(CGFloat(display.width)  * 2)  // Retina
        config.height = Int(CGFloat(display.height) * 2)
        config.capturesAudio = false
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)

        return try await runOCR(cgImage)
    }

    private static func runOCR(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { req, err in
                if let err = err { cont.resume(throwing: err); return }
                let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
                let text = obs.compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                cont.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) }
            catch { cont.resume(throwing: error) }
        }
    }
}
```

**Latency budget** on an M-series Mac (warm):
- `SCScreenshotManager.captureImage` → ~60-120ms
- Vision OCR → ~40-80ms

**Use `SCScreenshotManager.captureImage` for one-shot captures.** `SCStream` is for continuous streaming and is much slower to spin up per-capture.

**Always filter out your own app's windows.** Otherwise your overlay appears in the OCR and your LLM reads its own output.

---

## 12. CerebrasClient.swift — streaming SSE pattern

Cerebras is the fastest production LLM (~2200 tok/s on llama3.1-8b) and their API is OpenAI-compatible. Same pattern works for Groq, Together, OpenRouter, OpenAI itself.

```swift
struct CerebrasClient {
    let endpoint = URL(string: "https://api.cerebras.ai/v1/chat/completions")!

    func stream(model: String, system: String, user: String,
                onDelta: @escaping (String) -> Void) async throws {
        guard let apiKey = resolveKey() else { throw CerebrasError.missingKey }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CerebrasError.http(0, "No response")
        }
        if http.statusCode != 200 {
            var buffer = ""
            for try await line in bytes.lines {
                buffer += line + "\n"; if buffer.count > 400 { break }
            }
            throw CerebrasError.http(http.statusCode, buffer)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String,
                  !content.isEmpty else { continue }
            onDelta(content)
        }
    }

    private func resolveKey() -> String? {
        if let k = Keychain.load(), !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["MYAPP_CEREBRAS_KEY"],
           !k.isEmpty { return k }
        return nil
    }
}
```

- **`URLSession.shared.bytes(for:)`** (macOS 12+) gives you an async sequence of lines — no manual SSE parser needed.
- **`Task.checkCancellation()`** inside the loop so a second hotkey fire cancels the prior stream cleanly.
- **`text/event-stream` Accept header** is what Cerebras uses to gate streaming. Without it you get a non-streamed JSON response.

---

## 13. Paster.swift — synthetic ⌘V paste-back

```swift
enum Paster {
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let prior = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)

        // Restore the previous clipboard after the paste is consumed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let prior = prior else { return }
            pb.clearContents()
            pb.setString(prior, forType: .string)
        }
    }
}
```

- **Requires Accessibility permission.** Without it, `CGEventPost` silently no-ops.
- **`.combinedSessionState`** as the source stateID is required for modifier flags to propagate correctly.
- **Restore the clipboard after ~1s** so you don't wipe the user's previous copy. Some apps read the pasteboard asynchronously, so don't restore immediately.

**Focus rule:** call `Paster.paste` when the target app is frontmost. In coshot's listen-mode flow, we never activate our own app so the target stays frontmost automatically. If you do activate (e.g. from a menu bar click that opened a modal), you need to `NSRunningApplication` the previous app back before posting the event.

---

## 14. Keychain.swift — API key storage

```swift
import Foundation
import Security

enum Keychain {
    private static let service = "dev.myapp.cerebras"
    private static let account = "api-key"

    static func save(_ value: String) {
        let data = value.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

**Pre-seed from a shell** for dev convenience:
```bash
security add-generic-password -U -s dev.myapp.cerebras -a api-key -w 'csk-…'
```

The app reads it via `Keychain.load()` at runtime. No env var, no `.env`, no file-on-disk config.

---

## 15. UpdateChecker.swift — GitHub Releases poller (no Sparkle)

**Why not Sparkle?** Framework embedding in SPM-only apps requires hand-copying `Sparkle.framework` into `Contents/Frameworks`, per-component codesigning, EdDSA key generation + appcast signing, and hosting an appcast.xml. Total: ~3 hours of yak-shaving. The alternative is ~80 LOC of Swift that polls GitHub's Releases API, downloads the zip, and spawns a helper script that swaps the bundle.

**Trust model:** We don't sign the appcast. We rely on:
1. GitHub TLS for the download
2. Apple's notarization ticket stapled to the downloaded `.app`
3. Gatekeeper verifying the signature on every launch

A tampered zip on GitHub can't produce a valid Developer ID signature (that requires Ara's cert, which only Sven has). So the worst an attacker can do is serve a corrupt zip that fails to launch.

```swift
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    private let repo = "Aradotso/myapp"
    private let pollInterval: TimeInterval = 60
    private var dismissedVersion: String?
    private var checkInFlight = false
    private var installing = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func startPolling() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while true {
                await self?.check(interactive: false)
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 60) * 1_000_000_000))
            }
        }
    }

    private func check(interactive: Bool) async {
        guard !checkInFlight, !installing else { return }
        checkInFlight = true
        defer { checkInFlight = false }

        do {
            let release = try await fetchLatest()
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
            if Self.isNewer(latest, than: currentVersion) {
                if !interactive, dismissedVersion == latest { return }
                promptAndInstall(release: release, version: latest)
            } else if interactive {
                // show "up to date" alert
            }
        } catch { /* silent on poll */ }
    }

    private func performInstall(zipURL: URL, version: String) async {
        installing = true
        do {
            let tmp = FileManager.default.temporaryDirectory
            let dest = tmp.appendingPathComponent("myapp-update-\(version).zip")
            try? FileManager.default.removeItem(at: dest)
            let (downloaded, _) = try await URLSession.shared.download(from: zipURL)
            try FileManager.default.moveItem(at: downloaded, to: dest)

            let appPath = Bundle.main.bundlePath
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = """
            #!/bin/bash
            set -e
            for i in {1..60}; do
              if ! kill -0 \(pid) 2>/dev/null; then break; fi
              sleep 0.2
            done
            TMP=$(mktemp -d -t myapp-update)
            /usr/bin/unzip -q "\(dest.path)" -d "$TMP"
            rm -rf "\(appPath)"
            /bin/mv "$TMP/myapp.app" "\(appPath)"
            rm -rf "$TMP" "\(dest.path)"
            /usr/bin/xattr -dr com.apple.quarantine "\(appPath)" 2>/dev/null || true
            /usr/bin/open "\(appPath)"
            """
            let scriptPath = tmp.appendingPathComponent("myapp-update.sh")
            try script.write(to: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: scriptPath.path)

            let proc = Process()
            proc.launchPath = "/bin/bash"
            proc.arguments = [scriptPath.path]
            try proc.run()
            NSApp.terminate(nil)
        } catch { ... }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").compactMap { Int($0) }
        let bv = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
```

- **60s poll interval** = 60 req/hour per IP, right at GitHub's unauthenticated rate limit. Don't go below 60s without adding a token.
- **Detached bash helper** survives `NSApp.terminate` because `Process()` uses `posix_spawn` without a controlling TTY.
- **`xattr -dr com.apple.quarantine`** is critical: the downloaded `.app` has the quarantine bit from GitHub's HTTPS download; stripping it prevents Gatekeeper from warning on first launch of the new version.
- **Dismissal is session-only.** If the user clicks "Later", store the version string in memory and don't re-prompt for that version. On relaunch, the flag resets. This is better than persisting "dismissed forever" — updates matter.

---

## 16. release.sh — the full signing + notarization pipeline

**Apple Developer credentials live in Railway.** No one checks them into the repo, no one keeps them on their laptop.

### Railway setup (one time, per machine)

```bash
cd ~/lab/myapp
railway link --project 5b03413d-9ace-4617-beb5-18b26ce5f339 \
             --environment prd \
             --service mac-setup
```

This links the current directory to the Ara Backend / prd / mac-setup service. After this, `railway variables --kv` in that dir returns the signing secrets non-interactively.

### The secrets

In Railway's `mac-setup` service, these are set:

| Variable | What it is |
|---|---|
| `APPLE_CODESIGN_DEVELOPER_ID_IDENTITY` | `"Developer ID Application: SVEINUNG MYHRE (6N57FMKAZW)"` |
| `APPLE_CODESIGN_P12_CERTIFICATE_B64` | base64-encoded .p12 of the cert + private key |
| `APPLE_CODESIGN_P12_CERTIFICATE_PASSWORD` | p12 password |
| `APPLE_DEVELOPER_ACCOUNT_EMAIL` | `s-myhre@outlook.com` |
| `APPLE_DEVELOPER_APP_SPECIFIC_PASSWORD` | app-specific password for notarytool |
| `APPLE_DEVELOPER_TEAM_ID` | `6N57FMKAZW` |

All are Ara team credentials — every new Ara Mac app uses the same Developer ID.

### release.sh (full)

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

GH_REPO="Aradotso/myapp"

# ------- version bump -------
CURRENT=$(plutil -extract CFBundleShortVersionString raw Info.plist)
if [ $# -ge 1 ]; then
  VERSION="$1"
else
  IFS='.' read -r MAJ MIN PATCH <<<"$CURRENT"
  VERSION="$MAJ.$MIN.$((PATCH + 1))"
fi
echo "▶ $CURRENT → $VERSION"

# ------- fetch Apple secrets from Railway -------
RAILWAY_KV=$(railway variables --kv 2>/dev/null | grep "^APPLE_" || true)
[ -z "$RAILWAY_KV" ] && { echo "✗ railway link missing"; exit 1; }
while IFS='=' read -r key value; do export "$key=$value"; done <<<"$RAILWAY_KV"

: "${APPLE_CODESIGN_DEVELOPER_ID_IDENTITY:?missing}"
: "${APPLE_CODESIGN_P12_CERTIFICATE_B64:?missing}"
: "${APPLE_CODESIGN_P12_CERTIFICATE_PASSWORD:?missing}"
: "${APPLE_DEVELOPER_ACCOUNT_EMAIL:?missing}"
: "${APPLE_DEVELOPER_APP_SPECIFIC_PASSWORD:?missing}"
: "${APPLE_DEVELOPER_TEAM_ID:?missing}"

# ------- import cert into login keychain (idempotent) -------
if ! security find-identity -v -p codesigning 2>/dev/null \
     | grep -q "$APPLE_CODESIGN_DEVELOPER_ID_IDENTITY"; then
  P12_FILE=$(mktemp -t myapp-cert).p12
  trap 'rm -f "$P12_FILE"' EXIT
  echo "$APPLE_CODESIGN_P12_CERTIFICATE_B64" | base64 -d > "$P12_FILE"
  security import "$P12_FILE" \
    -P "$APPLE_CODESIGN_P12_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign
fi

# ------- build + wrap -------
plutil -replace CFBundleShortVersionString -string "$VERSION" Info.plist
plutil -replace CFBundleVersion -string "$VERSION" Info.plist
swift build -c release
./build-app.sh >/dev/null

# ------- sanitize bundle BEFORE signing -------
# macOS 14+ writes com.apple.provenance xattrs on every file. ditto packs
# those as AppleDouble ._* entries inside the zip, which extract as real
# files on install and break the code-signature seal (→ "myapp is damaged").
/usr/bin/xattr -cr myapp.app
/usr/bin/dot_clean -fm myapp.app 2>/dev/null || true
/usr/bin/find myapp.app -name '._*' -delete 2>/dev/null || true

# ------- sign with Developer ID + hardened runtime -------
codesign --force --deep --timestamp --options runtime \
  --sign "$APPLE_CODESIGN_DEVELOPER_ID_IDENTITY" \
  myapp.app

codesign --verify --verbose=2 myapp.app
spctl --assess --verbose=2 --type execute myapp.app || true

# ------- zip with /usr/bin/zip, NOT ditto -------
rm -f myapp.zip
/usr/bin/zip -qry myapp.zip myapp.app

# ------- notarize + staple -------
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "⚠ SKIP_NOTARIZE=1 — shipping signed-only"
else
  xcrun notarytool submit myapp.zip \
    --apple-id "$APPLE_DEVELOPER_ACCOUNT_EMAIL" \
    --team-id "$APPLE_DEVELOPER_TEAM_ID" \
    --password "$APPLE_DEVELOPER_APP_SPECIFIC_PASSWORD" \
    --wait

  xcrun stapler staple myapp.app
  xcrun stapler validate myapp.app

  rm myapp.zip
  /usr/bin/zip -qry myapp.zip myapp.app
fi

# ------- git tag + GitHub Release -------
git add Info.plist
git -c user.email="release@myapp.dev" -c user.name="myapp release" \
  commit -m "v$VERSION" --allow-empty >/dev/null
git tag -f "v$VERSION"
git push origin main --tags >/dev/null 2>&1

gh release delete "v$VERSION" --repo "$GH_REPO" --yes >/dev/null 2>&1 || true
gh release create "v$VERSION" myapp.zip \
  --repo "$GH_REPO" \
  --title "myapp v$VERSION" \
  --notes "signed + notarized"

echo "✓ shipped myapp v$VERSION"
```

**Critical gotchas** (every one was a debugging session in coshot):

1. **AppleDouble `._*` files break code signatures.** macOS 14+ Sonoma auto-writes a `com.apple.provenance` xattr on every file. When you `ditto -c -k` a bundle with xattrs, ditto packs them as AppleDouble entries inside the zip. When the user unzips on install, those extract as real `._*` files alongside the originals, and the code-signature manifest no longer matches → Gatekeeper says **"myapp is damaged and can't be opened."** Fix: `xattr -cr` the bundle before signing, and zip with `/usr/bin/zip -qry` instead of ditto.

2. **Don't create an ephemeral keychain for signing.** I tried this and hit `security: SecKeychainItemImport: Unknown format in import` — a path/format mismatch in the `security create-keychain` / `security import` flow. The login keychain works fine, is idempotent (`find-identity` check skips re-import on subsequent runs), and persists Sven's cert between release runs on the same machine.

3. **Notarization can fail with HTTP 403 "A required agreement is missing or has expired"** when Apple ships a new Developer Program License Agreement. Sven has to log into developer.apple.com, accept it, then **open Xcode once** to force a credential cache refresh. Wait 10-15 min for propagation. This happens roughly every 2-3 months; it's not a bug.

4. **`gh release create` can race with tag push.** If you hit "release not found" on first run, it means gh tried to create the release before GitHub had indexed the new tag. Add a `sleep 1` or use `|| gh release upload ... --clobber` as a fallback.

5. **Use `gh release download`, not `curl`, in install scripts.** curl hitting the GitHub asset URL sometimes gets a 9-byte empty response due to a redirect quirk. `gh release download --pattern coshot.zip` handles the redirect chain properly.

6. **TCC permissions persist across releases _only_ if the Developer ID signature is stable.** Every Ara app signed with `SVEINUNG MYHRE (6N57FMKAZW)` inherits the same TCC entry on the user's machine if the bundle ID is different. Same bundle ID + same team ID = permissions persist forever across releases.

---

## 17. AppDelegate.swift — wiring everything together

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: OverlayController!
    private var hotkey: HotkeyMonitor!
    private let listenTap = ListenModeTap()
    private var listening = false

    func applicationDidFinishLaunching(_ n: Notification) {
        overlay = OverlayController()

        installMainMenu()  // .regular apps need a main menu or crash
        MenuBarIcon.load()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.compose(listening: false)

        let menu = NSMenu()
        menu.addItem(withTitle: "Configure…", action: #selector(showConfig), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Set API Key…", action: #selector(setKey), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "myapp v\(versionString)", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit myapp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        listenTap.onLetter = { [weak self] letter in self?.handleLetter(letter) }
        hotkey = HotkeyMonitor { [weak self] in self?.toggleListen() }
        hotkey.register(keyCode: UInt32(kVK_Space), modifiers: [.option])

        UpdateChecker.shared.startPolling()

        Log.app.info("launch v\(self.versionString) ax=\(PermissionGate.hasAccessibility) sc=\(PermissionGate.hasScreenRecording)")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            PermissionGate.ensureGranted()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overlay.showConfig()
        return false
    }
}
```

**`.regular` apps MUST provide a main menu** or macOS raises an NSInternalInconsistencyException at launch. Minimal menu:

```swift
private func installMainMenu() {
    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)

    let appMenu = NSMenu(title: "myapp")
    appMenu.addItem(withTitle: "About myapp",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Quit myapp",
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
    appItem.submenu = appMenu

    NSApp.mainMenu = mainMenu
}
```

---

## 18. MenuBarIcon.swift — live status in the status bar

The menu bar icon is the canonical place to show transient app state (listening, streaming, error). Compose at runtime:

```swift
enum MenuBarIcon {
    static var base: NSImage?

    static func load() {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return }
        img.size = NSSize(width: 18, height: 18)
        base = img
    }

    static func compose(listening: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let composite = NSImage(size: size)
        composite.lockFocus()
        defer { composite.unlockFocus() }

        base?.draw(in: NSRect(origin: .zero, size: size))

        if listening {
            let dotDiameter: CGFloat = 7
            let dotRect = NSRect(
                x: size.width - dotDiameter - 0.5,
                y: 0.5,
                width: dotDiameter, height: dotDiameter)
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let ring = NSBezierPath(ovalIn: dotRect)
            ring.lineWidth = 0.6
            ring.stroke()
        }
        return composite
    }
}
```

- Generate `MenuBarIcon.png` + `@2x.png` via `sips -z 18 18 source.png --out MenuBarIcon.png` from your full-res app icon.
- Set `isTemplate = false` to keep colors (Ara logo). Set `isTemplate = true` if you want the system to auto-tint for light/dark menu bars (monochrome glyph style).
- **Call `composite.lockFocus()` / `unlockFocus()`** — NSImage drawing must happen inside these calls.

---

## 19. Log.swift — os.Logger with a subsystem

Always instrument. Always use `os.Logger`, not `NSLog` (NSLog goes to a verbose subsystem that's hard to filter).

```swift
import Foundation
import os

enum Log {
    static let subsystem = "dev.myapp.app"

    static let app     = Logger(subsystem: subsystem, category: "app")
    static let listen  = Logger(subsystem: subsystem, category: "listen")
    static let fire    = Logger(subsystem: subsystem, category: "fire")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let llm     = Logger(subsystem: subsystem, category: "llm")
    static let paste   = Logger(subsystem: subsystem, category: "paste")
}
```

Usage:
```swift
Log.fire.info("t+\(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms → Capture")
```

**Always use `privacy: .public`** for debug logs. By default, os_log redacts interpolated strings as `<private>` in production builds — you'll stare at a log full of redactions and not know what went wrong.

Stream live during development:
```bash
log stream --predicate 'subsystem == "dev.myapp.app"' --style compact --level debug
```

Read recent history:
```bash
log show --predicate 'subsystem == "dev.myapp.app"' --last 2m --style compact
```

---

## 20. Design tokens (Ara style)

From `~/lab/ara/app.ara.so/src/index.css` and the ara.so globals:

| Token | Value |
|---|---|
| Corner radius | **3-6px** (Ara uses 3px; coshot uses 4px for inner, 6px for outer containers) |
| Font sans | **Inter + system-ui** (in SwiftUI: `.system(.body, design: .default)` → SF Pro on macOS) |
| Font mono | **JetBrains Mono / SF Mono** (in SwiftUI: `.system(size: 11, design: .monospaced)`) |
| Dark bg | **`Color(white: 0.07)`** (not `.ultraThinMaterial` — flat > glass for Ara) |
| Border | **`.white.opacity(0.08)`** hairline |
| Active bg | **`Color(white: 0.18)`** |
| Hover bg | **`Color(white: 0.11)`** |
| Text primary | **`.white.opacity(0.92)`** |
| Text secondary | **`.white.opacity(0.65)`** |
| Text tertiary | **`.white.opacity(0.42)`** |
| Text muted | **`.white.opacity(0.35)`** |
| Accent primary (button) | **white fill, black text** (like Ara's accent buttons) |
| Accent secondary (ghost) | **transparent, white stroke** |
| Status dots | **squares, not circles** (7×7 rectangles) |

**Typography rules:**
- Labels and hints: **lowercase monospace** (`.system(size: 10, design: .monospaced)` + `.textCase(.lowercase)`).
- Headings: semibold, not bold. `.system(size: 17, weight: .semibold)`.
- Body: default weight, 13-14px.
- Button labels: 11px semibold monospace, lowercase.

**Art from `~/lab/ara/ara.so/public/art/`:** 11 PNG pieces, 1472px wide landscape or 1470×1848 portrait. Copy into `Sources/<app>/Resources/` and reference via `Bundle.module`. In coshot, `art-10.png` is used as a 132px-tall banner at the top of config mode with a dark gradient overlay and a "coshot / ara" wordmark in the bottom-left.

---

## 21. Spinning up a new Ara Mac app — the checklist

1. **Create the repo:**
   ```bash
   gh repo create Aradotso/<name> --public --description "..."
   cd ~/lab && git clone git@github.com:Aradotso/<name>.git
   ```

2. **Clone coshot as a starting point** and rename:
   ```bash
   cp -R ~/lab/coshot/* ~/lab/<name>/
   cd ~/lab/<name>
   # Rename target in Package.swift, Info.plist, build-app.sh, release.sh
   # Update CFBundleIdentifier from dev.coshot.app to dev.<name>.app
   ```

3. **Rip out coshot business logic:**
   - `CerebrasClient.swift` stays (just retarget)
   - `Capture.swift` stays
   - `Paster.swift` stays
   - `PermissionGate.swift` stays verbatim
   - `OverlayPanel.swift` / `OverlayView.swift` / `CommandModeView.swift` → replace with your own UI
   - `PromptLibrary.swift` / `Resources/prompts.default.json` → replace with your own config

4. **Keep these files unchanged:**
   - `App.swift`
   - `AppDelegate.swift` (modify menu items but keep structure)
   - `HotkeyMonitor.swift`
   - `ListenMode.swift`
   - `Keychain.swift` (change service ID)
   - `UpdateChecker.swift` (change repo)
   - `MenuBarIcon.swift`
   - `Log.swift` (change subsystem)
   - `build-app.sh` (change binary name)
   - `release.sh` (change GH_REPO)
   - `Info.plist`

5. **Link Railway to the same `mac-setup` service:**
   ```bash
   cd ~/lab/<name>
   railway link --project 5b03413d-9ace-4617-beb5-18b26ce5f339 \
                --environment prd \
                --service mac-setup
   ```

6. **Grab assets:**
   ```bash
   cp ~/lab/ara/app.ara.so/src-tauri/icons/icon.icns Sources/<name>/Resources/AppIcon.icns
   cp ~/lab/ara/ara.so/public/art/art-10.png Sources/<name>/Resources/AraArt.png
   sips -z 18 18 ~/lab/ara/app.ara.so/src-tauri/icons/icon.png --out Sources/<name>/Resources/MenuBarIcon.png
   sips -z 36 36 ~/lab/ara/app.ara.so/src-tauri/icons/icon.png --out Sources/<name>/Resources/MenuBarIcon@2x.png
   ```

7. **First ship:**
   ```bash
   ./release.sh 0.1.0
   ```
   This signs, notarizes, pushes the tag, and creates the first GitHub Release. ~60-90 seconds.

8. **Install locally:**
   ```bash
   gh release download v0.1.0 --repo Aradotso/<name> --pattern "<name>.zip" --output /tmp/<name>.zip
   unzip -o /tmp/<name>.zip -d /Applications/
   open /Applications/<name>.app
   ```

9. **Share with teammates:**
   ```
   curl -L https://github.com/Aradotso/<name>/releases/latest/download/<name>.zip -o /tmp/<name>.zip && unzip -o /tmp/<name>.zip -d /Applications/ && open /Applications/<name>.app
   ```

From this point on, every `./release.sh` automatically:
- Bumps version
- Builds + signs + notarizes
- Pushes tag + release
- Teammates' running apps detect the new version within 60 seconds and prompt to install

Total time from `./release.sh` to teammate seeing the update prompt: **~90 seconds**.

---

## 22. Gotchas I already hit (so you don't have to)

| Symptom | Cause | Fix |
|---|---|---|
| "myapp is damaged and can't be opened" | ditto packed AppleDouble `._*` files into the zip; signature seal broke | `xattr -cr` + use `/usr/bin/zip -qry` instead of ditto |
| App doesn't appear in Screen Recording Settings | `.accessory` activation policy + no SCShareableContent call | Switch to `.regular` + touch `SCShareableContent.current` on launch |
| `⌥Space` opens the overlay but keys don't register | Panel isn't becoming key because `NSApp.activate` wasn't called, OR the CGEventTap failed silently because AX is denied | Check `listenTap.isActive` after `start()`; only set the "listening" flag if it returned non-nil |
| Accessibility dialog pops every launch even after granting | `AXIsProcessTrustedWithOptions(prompt: true)` fires on every launch from a passive check | Only call with `prompt: true` from explicit user action. Use `AXIsProcessTrusted()` for status checks. |
| Escape on permission alert quits the app | `NSAlert` second button is the Cancel/Escape target; "Quit coshot" was sitting there | Name the cancel button "Dismiss", never call `NSApp.terminate` from the alert path |
| Notarization fails with HTTP 403 "agreement missing" | Apple posted a new Developer Program License Agreement | Sven logs into developer.apple.com, accepts, opens Xcode once, waits 10-15 min |
| `swift run` works but `./build-app.sh && open myapp.app` doesn't get Screen Recording permission | Permissions are tied to the `.app` bundle identity, not the raw binary path | Always wrap into a `.app` for any capture-path testing |
| `open` of coshot from Terminal doesn't activate it | The `.app` is in a cached stale state in LaunchServices | `lsregister -f /Applications/coshot.app` to force re-register |
| Dock icon shows `.app` name instead of `CFBundleDisplayName` | `CFBundleDisplayName` only applies once the app is in `/Applications` and LaunchServices re-scans | Same `lsregister -f` fix |
| `@main` attribute conflict with top-level code | File named `main.swift` forces top-level code mode | Name the entry file `App.swift` (anything but `main.swift`) |
| Release.sh tail command truncates `gh release create` output | Normal bash pipe behavior | Use `|| gh release upload --clobber` fallback and verify via `gh release view` |
| Polling timer doesn't fire during an NSAlert | `Timer.scheduledTimer` uses `.default` run loop mode; modal is in `.modalPanel` | Use `DispatchSource.makeTimerSource(queue: .main)` — GCD timers bypass run loop modes |
| `.regular` activation policy doesn't take effect | `setActivationPolicy(.regular)` call was removed/reverted in a previous edit | Grep for `setActivationPolicy` every time the Dock icon is missing; verify the edit actually stuck |

---

## 23. Glossary of Ara-specific values

Paste these into new apps verbatim:

```
Railway project: Ara Backend
Railway project ID: 5b03413d-9ace-4617-beb5-18b26ce5f339
Railway environment: prd
Railway service: mac-setup
Apple Team ID: 6N57FMKAZW
Apple Team Name: SVEINUNG MYHRE
Apple ID: s-myhre@outlook.com
Signing Identity: "Developer ID Application: SVEINUNG MYHRE (6N57FMKAZW)"
GitHub Org: Aradotso
```

**Never commit these to a repo.** They're in Railway for a reason. Fetch at release time only.

---

## 24. What this playbook deliberately leaves out

- **Xcode projects.** SPM is simpler, reproducible, CI-friendly, and avoids `.xcodeproj` merge conflicts. Use Xcode only as an editor, not a project manager.
- **Storyboards / XIBs.** SwiftUI + NSHostingView handles all UI.
- **Sandboxing.** Ara Mac apps are Developer ID signed, not sandboxed (which is App Store only). This is why we can use CGEventTap, CGEventPost, SCShareableContent freely.
- **App Store distribution.** If you ever need this, you'll need to sandbox, which breaks half the patterns in this doc. Don't — ship via GitHub Releases.
- **Sparkle.** See section 15.
- **Electron/Tauri.** The whole point of this stack is native performance (<1.5s capture → paste) and ~460KB binary sizes. Electron is 150MB and slow.
- **Menu bar-only (LSUIElement) apps.** Use `.regular` + a hidden window if you really want a menu-bar-only presence. LSUIElement has more edge cases than it's worth.

---

## 25. Further reading in this repo

- `AGENTS.md` — the three-step user setup (AI-agent focused)
- `README.md` — user-facing quickstart
- `release.sh` — the actual pipeline, all ~140 lines
- `build-app.sh` — the wrapping script
- `Sources/coshot/PermissionGate.swift` — silent-poll pattern with auto-relaunch
- `Sources/coshot/ListenMode.swift` — CGEventTap with letter-key intercept
- `Sources/coshot/UpdateChecker.swift` — GitHub Releases poller
- `Sources/coshot/OverlayPanel.swift` — nonactivating NSPanel controller
- `Sources/coshot/OverlayView.swift` — Ara design tokens in SwiftUI

When in doubt, grep coshot. Every pattern in this doc is live in that repo.
