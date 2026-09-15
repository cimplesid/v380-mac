import os

/// Diagnostic log (Console.app, subsystem com.openv380.mac). Messages are marked public so they are readable;
/// never pass passwords, device IDs, or session tickets here.
enum Diag {
    private static let logger = Logger(subsystem: "com.openv380.mac", category: "app")

    static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}
