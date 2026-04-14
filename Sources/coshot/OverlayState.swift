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
}
