import OSLog

/// OSLog handles for the FSKit appex. Subsystem `dev.msl.fskit` is the shared
/// grep target for `log stream --predicate 'subsystem == "dev.msl.fskit"'`.
enum MSLFSKitLog {
    static let subsystem = "dev.msl.fskit"
    static let probe = Logger(subsystem: subsystem, category: "probe")
    static let volume = Logger(subsystem: subsystem, category: "volume")
}
