import os

/// Loggers centralisés, filtrables via :
///   log stream --predicate 'subsystem == "com.cletetour.sillage"'
///   log show --last 5m --predicate 'subsystem == "com.cletetour.sillage"'
enum Log {
    static let app = Logger(subsystem: "com.cletetour.sillage", category: "app")
    static let mic = Logger(subsystem: "com.cletetour.sillage", category: "mic")
    static let system = Logger(subsystem: "com.cletetour.sillage", category: "system")
}
