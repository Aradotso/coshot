import Foundation
import os

/// Shared os.Logger instances. Filter in Terminal with:
///
///     log stream --predicate 'subsystem == "dev.coshot.app"' --style compact
///     log show --predicate 'subsystem == "dev.coshot.app"' --last 2m --style compact
///
/// All coshot logs use `.public` privacy so the messages are visible in
/// production builds. (By default os_log redacts interpolated strings.)
enum Log {
    static let subsystem = "dev.coshot.app"

    static let app        = Logger(subsystem: subsystem, category: "app")
    static let listen     = Logger(subsystem: subsystem, category: "listen")
    static let fire       = Logger(subsystem: subsystem, category: "fire")
    static let capture    = Logger(subsystem: subsystem, category: "capture")
    static let llm        = Logger(subsystem: subsystem, category: "llm")
    static let paste      = Logger(subsystem: subsystem, category: "paste")
    static let permission = Logger(subsystem: subsystem, category: "permission")
    static let updater    = Logger(subsystem: subsystem, category: "updater")
}
