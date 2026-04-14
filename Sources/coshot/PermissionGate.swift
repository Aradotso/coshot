import AppKit
import ApplicationServices
import CoreGraphics

/// Handles the Screen Recording + Accessibility TCC flow automatically so the
/// user never has to hunt through System Settings themselves.
///
/// On launch, `ensureGranted()` triggers the native system prompts and — if
/// Screen Recording is denied — shows a coshot alert that polls the TCC
/// status and auto-relaunches the app the instant the user approves.
@MainActor
enum PermissionGate {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Called from AppDelegate on launch. If permissions are already granted,
    /// returns immediately. Otherwise fires the native prompts and, if Screen
    /// Recording is still denied, blocks on a gate alert until the user
    /// approves (auto-relaunch) or quits.
    static func ensureGranted() {
        // Accessibility: triggers a non-blocking system prompt the first time.
        // Takes effect immediately on grant — no relaunch required.
        if !hasAccessibility {
            _ = AXIsProcessTrustedWithOptions([
                "AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue
            ] as CFDictionary)
        }

        // Screen Recording: gating. If denied, block on the gate until approved.
        if !hasScreenRecording {
            _ = CGRequestScreenCaptureAccess()
            showGateAlert()
        }
    }

    /// Called when `Capture.captureAndOCR()` throws a TCC error at runtime.
    /// Re-triggers the system prompt (no-op if hard-denied) and shows the gate.
    static func reactToScreenRecordingDenied() {
        _ = CGRequestScreenCaptureAccess()
        showGateAlert()
    }

    /// Blocking modal that auto-dismisses when permission is granted.
    /// On grant: spawns a detached relauncher and calls NSApp.terminate.
    /// On Open Settings: opens the pane and recurses.
    /// On Quit: terminates the app.
    private static func showGateAlert() {
        // Already granted (maybe user approved between check + prompt display)?
        if hasScreenRecording {
            relaunch()
            return
        }

        let alert = NSAlert()
        alert.messageText = "coshot needs Screen Recording"
        alert.informativeText = """
        coshot captures your screen and runs OCR locally to answer questions about what you're looking at.

        A system dialog should have just appeared asking for Screen Recording access. If you don't see it, click Open Settings and toggle coshot on.

        coshot will relaunch automatically the moment you approve — you don't need to do anything here.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit coshot")

        // GCD timer on main queue polls TCC and auto-dismisses the modal.
        // GCD fires during modal panels (unlike RunLoop scheduledTimer default mode).
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.4, repeating: 0.4)
        source.setEventHandler {
            if CGPreflightScreenCaptureAccess() {
                source.cancel()
                NSApp.abortModal()
            }
        }
        source.resume()

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        source.cancel()

        // Polling hit → granted → relaunch
        if hasScreenRecording {
            relaunch()
            return
        }

        // User clicked Open Settings → open the pane and loop back to the gate
        if response == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
            showGateAlert()
            return
        }

        // User clicked Quit
        NSApp.terminate(nil)
    }

    /// Spawns a detached bash helper that waits for our PID to exit, then
    /// relaunches the .app. The helper survives NSApp.terminate because it's
    /// posix_spawn'd without a controlling TTY.
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
            // Fall through to terminate even if relauncher failed — better to
            // quit than to hang in a broken state.
        }

        NSApp.terminate(nil)
    }
}
