import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// Handles the Screen Recording + Accessibility TCC flow automatically so the
/// user never has to hunt through System Settings themselves.
///
/// Launch flow:
/// 1. Fire the native system prompt via `CGRequestScreenCaptureAccess()`.
/// 2. Silently poll TCC in the background — don't show any coshot UI, because
///    `NSAlert.runModal()` sits at `.modalPanel` level and would cover Apple's
///    native Screen Recording dialog.
/// 3. On grant → auto-relaunch via detached bash helper.
/// 4. If 8 seconds pass and the user is still denied (they missed or dismissed
///    the native dialog), escalate to our NSAlert with "Open Settings" + poll.
@MainActor
enum PermissionGate {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    static var hasApiKey: Bool {
        if let k = Keychain.load(), !k.isEmpty { return true }
        if let k = ProcessInfo.processInfo.environment["COSHOT_CEREBRAS_KEY"], !k.isEmpty { return true }
        return false
    }

    /// Reentrancy guards — a single permission grant should trigger one
    /// relaunch, not a thundering herd of alerts.
    private static var isPolling = false
    private static var isAlertShown = false

    /// Called from AppDelegate on launch.
    static func ensureGranted() {
        if !hasAccessibility {
            _ = AXIsProcessTrustedWithOptions([
                "AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue
            ] as CFDictionary)
        }

        if !hasScreenRecording {
            _ = CGRequestScreenCaptureAccess()

            // Touch ScreenCaptureKit once so TCC registers coshot in the
            // Screen Recording settings list even if the user dismissed
            // the native dialog without clicking Allow. Without this call,
            // coshot can be missing from System Settings → Privacy &
            // Security → Screen Recording, giving nothing to toggle on.
            Task.detached {
                _ = try? await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
            }

            startSilentPoll(escalateAfter: 8.0)
        }
    }

    /// Called when `Capture.captureAndOCR()` throws a TCC error at runtime.
    /// Kicks off a silent background poll if one isn't already running. Does
    /// NOT show a modal — the overlay already shows a status message, and a
    /// modal interrupts the user's ⌥Space flow unexpectedly.
    static func reactToScreenRecordingDenied() {
        _ = CGRequestScreenCaptureAccess()
        startSilentPoll(escalateAfter: 12.0)
    }

    /// Silent background poll. No UI — the native TCC dialog is already up.
    /// On grant: auto-relaunch. On timeout: escalate to the fallback alert.
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
                relaunch()
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

    /// Last-resort coshot modal: the user didn't interact with the native
    /// Screen Recording dialog, so guide them to System Settings explicitly.
    /// Keeps polling in the background so we can auto-dismiss + relaunch
    /// without the user clicking anything on this alert once they approve.
    private static func showFallbackAlert() {
        if isAlertShown { return }
        if hasScreenRecording { relaunch(); return }
        isAlertShown = true
        defer { isAlertShown = false }

        let alert = NSAlert()
        alert.messageText = "coshot needs Screen Recording"
        alert.informativeText = """
        Toggle coshot on in System Settings → Privacy & Security → Screen Recording.

        coshot will relaunch automatically the moment you approve — you don't need to come back here and click anything.
        """
        alert.addButton(withTitle: "Open Settings")
        let dismissButton = alert.addButton(withTitle: "Dismiss")
        // Ensure Escape maps to Dismiss (a benign no-op), not some implicit
        // quit behaviour. Escape already targets the cancel button by default,
        // so making sure Dismiss IS the cancel button is what matters.
        dismissButton.keyEquivalent = "\u{1b}"  // explicit Escape

        // Auto-dismiss if permission is granted while the alert is visible.
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.4, repeating: 0.4)
        source.setEventHandler {
            if hasScreenRecording {
                source.cancel()
                NSApp.abortModal()
            }
        }
        source.resume()

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        source.cancel()

        if hasScreenRecording {
            relaunch()
            return
        }

        if response == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
            // Give them 2 minutes to approve after opening Settings before
            // escalating back to an alert.
            startSilentPoll(escalateAfter: 120.0)
            return
        }

        // Dismiss → keep polling silently in the background. Do NOT terminate.
        // The user can relaunch coshot's overlay any time with ⌥Space, and
        // the background poll will auto-relaunch the instant permission is granted.
        startSilentPoll(escalateAfter: 120.0)
    }

    /// Spawns a detached bash helper that waits for our PID to exit, then
    /// relaunches the .app. The helper survives `NSApp.terminate` because it's
    /// `posix_spawn`'d without a controlling TTY.
    private static func relaunch() {
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmp = FileManager.default.temporaryDirectory
        let scriptPath = tmp.appendingPathComponent("coshot-relaunch.sh")

        let script = """
        #!/bin/bash
        for i in {1..30}; do
          if ! kill -0 \(pid) 2>/dev/null; then break; fi
          sleep 0.2
        done
        /usr/bin/open "\(appPath)"
        """

        do {
            try script.write(to: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: scriptPath.path
            )
            let proc = Process()
            proc.launchPath = "/bin/bash"
            proc.arguments = [scriptPath.path]
            try proc.run()
        } catch {
            // Fall through to terminate even if relauncher setup failed.
        }

        NSApp.terminate(nil)
    }
}
