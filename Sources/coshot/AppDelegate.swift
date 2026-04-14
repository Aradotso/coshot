import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: OverlayController!
    private var hotkey: HotkeyMonitor!
    private let listenTap = ListenModeTap()
    private var listening = false
    private var listenTimeoutTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ n: Notification) {
        overlay = OverlayController()

        installMainMenu()

        MenuBarIcon.load()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.compose(listening: false)

        let menu = NSMenu()
        menu.addItem(withTitle: "Configure…", action: #selector(showConfig), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Set Cerebras API Key…", action: #selector(setKey), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "coshot v\(versionString)", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit coshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // ⌥Space arms listen mode — DOES NOT open the overlay. The next
        // A/S/D/F/G is captured by the CGEventTap and runs end-to-end.
        listenTap.onLetter = { [weak self] letter in
            self?.handleListenedLetter(letter)
        }
        hotkey = HotkeyMonitor { [weak self] in self?.toggleListenMode() }
        hotkey.register(keyCode: UInt32(kVK_Space), modifiers: [.option])

        UpdateChecker.shared.startPolling()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            PermissionGate.ensureGranted()
        }
    }

    // MARK: - Listen mode

    private func toggleListenMode() {
        Log.listen.info("⌥Space pressed, currently listening=\(self.listening, privacy: .public)")
        if listening { stopListening() } else { startListening() }
    }

    private func startListening() {
        Log.listen.info("startListening — ax_granted=\(PermissionGate.hasAccessibility, privacy: .public) sc_granted=\(PermissionGate.hasScreenRecording, privacy: .public)")
        listening = true
        listenTap.start()
        Log.listen.info("after tap.start() isActive=\(self.listenTap.isActive, privacy: .public)")
        updateMenuBarIcon()

        listenTimeoutTask?.cancel()
        listenTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self = self, !Task.isCancelled, self.listening else { return }
            Log.listen.info("auto-disarm after 10s timeout")
            self.stopListening()
        }
    }

    private func stopListening() {
        Log.listen.info("stopListening")
        listening = false
        listenTap.stop()
        listenTimeoutTask?.cancel()
        listenTimeoutTask = nil
        updateMenuBarIcon()
    }

    private func handleListenedLetter(_ letter: Character) {
        Log.listen.info("handleListenedLetter \(String(letter), privacy: .public)")
        stopListening()
        overlay.fireListenedPrompt(letter)
    }

    private func updateMenuBarIcon() {
        statusItem.button?.image = MenuBarIcon.compose(listening: listening)
    }

    // MARK: - Misc

    private var versionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    @objc func checkForUpdates() {
        UpdateChecker.shared.checkNow()
    }

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

    /// Click on the Dock icon → open the overlay in config mode (the only
    /// place the overlay is shown now; ⌥Space is for listen mode).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overlay.showConfig()
        return false
    }

    /// .regular apps must provide a main menu or macOS crashes on launch.
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
