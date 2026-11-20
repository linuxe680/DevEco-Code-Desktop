import os

/// Unified logging. View with: `log stream --predicate 'subsystem == "com.local.deveco-codesktop"'`
enum Log {
    static let server = Logger(subsystem: "com.local.deveco-codesktop", category: "server")
    static let network = Logger(subsystem: "com.local.deveco-codesktop", category: "network")
    static let stream = Logger(subsystem: "com.local.deveco-codesktop", category: "stream")
    static let store = Logger(subsystem: "com.local.deveco-codesktop", category: "store")
}
