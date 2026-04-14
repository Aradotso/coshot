import AppKit
import Foundation

/// Minimal auto-updater: polls the GitHub Releases API once per minute,
/// compares versions, downloads the zip asset, and swaps the running .app
/// bundle on quit.
///
/// Security: we don't sign the appcast ourselves — the downloaded .app is
/// already signed with Ara's Developer ID and notarized by Apple. Gatekeeper
/// verifies the signature on every launch, so a tampered zip would refuse to
/// run. GitHub TLS + Apple's notarization ticket is the trust chain.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "Aradotso/coshot"

    /// How often to poll the GitHub releases API while the app is running.
    /// 60s = 60 requests/hour per IP — under the unauthenticated rate limit.
    /// The user sees a "new version" dialog within a minute of `./release.sh`.
    private let pollInterval: TimeInterval = 60

    /// In-memory "don't re-prompt this session" guard. Clicking "Later" sets
    /// this to the latest version so the poll loop doesn't spam every minute.
    /// Reset to nil on next app launch (this is a plain instance variable).
    private var dismissedVersion: String?

    /// Prevents overlapping checks (one in flight + another fired by the loop).
    private var checkInFlight = false

    /// Prevents overlapping installs.
    private var installing = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Called once from AppDelegate on launch. Spawns a background loop that
    /// polls forever at `pollInterval`. First check fires immediately.
    func startPolling() {
        Task { @MainActor [weak self] in
            // Small initial delay so the status bar finishes setup.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while true {
                await self?.check(interactive: false)
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 60) * 1_000_000_000))
            }
        }
    }

    /// Called from the ⚡ menu bar "Check for Updates…" item.
    /// Shows an alert even when the app is already up to date, and bypasses
    /// the dismissedVersion guard (the user is explicitly asking).
    func checkNow() {
        dismissedVersion = nil
        Task { await check(interactive: true) }
    }

    private func check(interactive: Bool) async {
        guard !checkInFlight, !installing else { return }
        checkInFlight = true
        defer { checkInFlight = false }

        do {
            let release = try await fetchLatest()
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v "))

            if Self.isNewer(latest, than: currentVersion) {
                // Respect "Later" click for non-interactive (polled) checks.
                if !interactive, dismissedVersion == latest { return }
                promptAndInstall(release: release, latestVersion: latest)
            } else if interactive {
                showAlert(
                    title: "You're up to date",
                    body: "coshot \(currentVersion) is the latest version."
                )
            }
        } catch {
            if interactive {
                showAlert(title: "Update check failed", body: error.localizedDescription)
            }
        }
    }

    private func fetchLatest() async throws -> GHRelease {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("coshot-updater", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(GHRelease.self, from: data)
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

    private func promptAndInstall(release: GHRelease, latestVersion: String) {
        guard let zip = release.assets.first(where: { $0.name == "coshot.zip" }) else { return }

        let alert = NSAlert()
        alert.messageText = "coshot v\(latestVersion) is available"
        alert.informativeText = "You're on v\(currentVersion). Install now and relaunch?"
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            Task { await performInstall(zipURL: zip.browserDownloadURL, version: latestVersion) }
        } else {
            // Suppress further polls for this version until the app restarts.
            dismissedVersion = latestVersion
        }
    }

    private func performInstall(zipURL: URL, version: String) async {
        installing = true
        defer { installing = false }
        do {
            // 1. Download the zip
            let tmp = FileManager.default.temporaryDirectory
            let dest = tmp.appendingPathComponent("coshot-update-\(version).zip")
            try? FileManager.default.removeItem(at: dest)
            let (downloaded, _) = try await URLSession.shared.download(from: zipURL)
            try FileManager.default.moveItem(at: downloaded, to: dest)

            // 2. Write a helper script that waits for us to quit, swaps the bundle, relaunches
            let appPath = Bundle.main.bundlePath       // e.g. /Applications/coshot.app
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = """
            #!/bin/bash
            set -e
            # Wait for the parent coshot process to exit
            for i in {1..60}; do
              if ! kill -0 \(pid) 2>/dev/null; then break; fi
              sleep 0.2
            done

            TMP=$(mktemp -d -t coshot-update)
            /usr/bin/unzip -q "\(dest.path)" -d "$TMP"

            rm -rf "\(appPath)"
            /bin/mv "$TMP/coshot.app" "\(appPath)"
            rm -rf "$TMP" "\(dest.path)"

            # Clear any quarantine bit set by the download
            /usr/bin/xattr -dr com.apple.quarantine "\(appPath)" 2>/dev/null || true

            /usr/bin/open "\(appPath)"
            """
            let scriptPath = tmp.appendingPathComponent("coshot-update.sh")
            try script.write(to: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: scriptPath.path
            )

            // 3. Launch the helper detached so it survives our exit
            let proc = Process()
            proc.launchPath = "/bin/bash"
            proc.arguments = [scriptPath.path]
            try proc.run()

            // 4. Quit so the helper can replace our bundle on disk
            NSApp.terminate(nil)
        } catch {
            showAlert(title: "Update failed", body: error.localizedDescription)
        }
    }

    private func showAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - GitHub Releases JSON

private struct GHRelease: Codable {
    let tagName: String
    let assets: [GHAsset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GHAsset: Codable {
    let name: String
    let browserDownloadURL: URL
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
