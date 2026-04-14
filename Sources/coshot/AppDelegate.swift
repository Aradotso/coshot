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
        statusItem.button?.title = "⚡"

        let menu = NSMenu()
        menu.addItem(withTitle: "Show (⌥Space)", action: #selector(show), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Set Cerebras API Key…", action: #selector(setKey), keyEquivalent: "")
        menu.addItem(withTitle: "Open Prompts File", action: #selector(openPrompts), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit coshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        hotkey = HotkeyMonitor { [weak self] in self?.overlay.toggle() }
        hotkey.register(keyCode: UInt32(kVK_Space), modifiers: [.option])
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
