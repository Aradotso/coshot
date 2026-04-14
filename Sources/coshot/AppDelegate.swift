import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: OverlayController!
    private var hotkey: HotkeyMonitor!

    func applicationDidFinishLaunching(_ n: Notification) {
        overlay = OverlayController()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true  // auto-adapts to dark/light menu bar
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "⚡"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Show (⌥Space)", action: #selector(show), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Set Cerebras API Key…", action: #selector(setKey), keyEquivalent: "")
        menu.addItem(withTitle: "Open Prompts File", action: #selector(openPrompts), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "coshot v\(versionString)", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit coshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        hotkey = HotkeyMonitor { [weak self] in self?.overlay.toggle() }
        hotkey.register(keyCode: UInt32(kVK_Space), modifiers: [.option])

        // Poll every 60s for new releases. The loop runs forever in the background.
        UpdateChecker.shared.startPolling()

        // Pre-prompt for Screen Recording + Accessibility. Auto-relaunches
        // when Screen Recording is approved — no manual quit/relaunch dance.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            PermissionGate.ensureGranted()
        }
    }

    private var versionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    @objc func checkForUpdates() {
        UpdateChecker.shared.checkNow()
    }

    @objc func show() { overlay.toggle() }

    @objc func setKey() {
        let alert = NSAlert()
        alert.messageText = "Cerebras API Key"
        alert.informativeText = "Stored in macOS Keychain. Get a key at cloud.cerebras.ai."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.stringValue = Keychain.load() ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Keychain.save(input.stringValue)
        }
    }

    @objc func openPrompts() {
        let url = PromptLibrary.promptsFileURL
        // Ensure the file exists on disk so the user can edit it.
        _ = PromptLibrary.load()
        NSWorkspace.shared.open(url)
    }
}
