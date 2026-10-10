import os

/// Low-cardinality Instruments points of interest. Arguments deliberately carry
/// only item counts; symbols, account names and financial values stay out of logs.
enum PerformanceSignposts {
    private static let log = OSLog(subsystem: "com.terry.stockdeck", category: .pointsOfInterest)

    static func begin(_ name: StaticString, itemCount: Int) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id, "items=%{public}d", itemCount)
        return id
    }

    static func end(_ name: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}
