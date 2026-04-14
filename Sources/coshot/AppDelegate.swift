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

        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 18, height: 18)
            // NOT a template — the Ara logo has color that we want to keep,
            // matching the Dock / app icon exactly.
            icon.isTemplate = false
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "⚡"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Capture (⌥Space)", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "Configure…", action: #selector(showConfig), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Set Cerebras API Key…", action: #selector(setKey), keyEquivalent: "")
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

    @objc func showConfig() { overlay.showConfig() }

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


    /// Click on the Dock icon → open the overlay in config mode (no capture,
    /// activates coshot normally so the user can edit prompts). The overlay
    /// in capture mode is only summoned by ⌥Space so it never steals focus
    /// from the user's target app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overlay.showConfig()
        return false
    }

    /// .regular apps must provide a main menu or macOS crashes on launch.
    /// Minimal app menu with Quit + the standard Services/Hide entries.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu(title: "coshot")
        appMenu.addItem(withTitle: "About coshot",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Check for Updates…",
                        action: #selector(checkForUpdates),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide coshot",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit coshot",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }
}
