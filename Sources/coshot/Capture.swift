import AppKit
import ScreenCaptureKit
import Vision

enum CaptureError: LocalizedError {
    case noDisplay
    case noText

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available"
        case .noText:    return "No text recognised"
        }
    }
}

enum Capture {
    /// Captures the main display (excluding coshot's own windows) and runs Vision OCR.
    /// Target latency on an M-series Mac: ~60-120ms for capture + ~40-80ms for OCR.
    static func captureAndOCR() async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let ourBundleID = Bundle.main.bundleIdentifier ?? "dev.coshot.app"
        let excludedApps = content.applications.filter { $0.bundleIdentifier == ourBundleID }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.width  = Int(CGFloat(display.width)  * 2)  // Retina
        config.height = Int(CGFloat(display.height) * 2)
        config.capturesAudio = false
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        return try await runOCR(cgImage)
    }

    private static func runOCR(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { req, err in
                if let err = err {
                    cont.resume(throwing: err); return
                }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                cont.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
