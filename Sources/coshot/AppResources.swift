import Foundation

/// Resolves packaged assets without relying on SwiftPM's generated
/// `Bundle.module` accessor, which can crash when the app is moved to a
/// different machine/path than the build host.
enum AppResources {
    private static let bundleName = "coshot_coshot.bundle"

    static var bundle: Bundle? {
        let candidates = candidateBundleURLs()
        for url in candidates {
            if let b = Bundle(url: url) { return b }
        }
        return nil
    }

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        bundle?.url(forResource: name, withExtension: ext)
    }

    private static func candidateBundleURLs() -> [URL] {
        var urls: [URL] = []
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

        // Normal .app launch path.
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(bundleName, isDirectory: true))
        }

        // Direct binary launch from inside an .app.
        urls.append(
            execURL.deletingLastPathComponent() // .../Contents/MacOS
                .deletingLastPathComponent() // .../Contents
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(bundleName, isDirectory: true)
        )

        // `swift run` / release binary layout: bundle next to executable.
        urls.append(execURL.deletingLastPathComponent().appendingPathComponent(bundleName, isDirectory: true))

        // De-duplicate while preserving order.
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}
