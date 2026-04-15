import Foundation
import Observation

@Observable
final class OverlayState {
    var ocrText: String? = nil
    var output: String = ""
    var status: String = "Idle"
    var lastKey: String = ""
    var prompts: [Prompt] = []
    var isStreaming: Bool = false
    var editingPromptIndex: Int? = nil
    var capturingShortcutForPromptIndex: Int? = nil
    var isConfigMode: Bool = false

    /// Live permission status, refreshed by OverlayController while the
    /// config overlay is visible. Powers the Permissions panel.
    var hasScreenRecording: Bool = false
    var hasAccessibility: Bool = false
    var hasApiKey: Bool = false
}
