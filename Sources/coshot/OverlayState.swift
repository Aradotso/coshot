import Foundation
import Observation

@Observable
final class OverlayState {
    var ocrText: String? = nil
    var output: String = ""
    var status: String = "Idle"
    var commandMode: Bool = false
    var lastKey: String = ""
}
