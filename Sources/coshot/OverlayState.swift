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
    /// When non-nil, the overlay switches to an inline text editor for that
    /// prompt's system template. `nil` = normal key grid view.
    var editingPromptIndex: Int? = nil
    /// True when the panel was opened by Dock click or menu bar, not by
    /// the ⌥Space hotkey. In this mode we don't run capture and we're OK
    /// with coshot stealing focus (the user clicked our icon, they meant it).
    var isConfigMode: Bool = false
}
