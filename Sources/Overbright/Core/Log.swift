import Foundation
import OSLog

enum Log {
    static let engine = Logger(subsystem: "app.overbright", category: "engine")
    static let overlay = Logger(subsystem: "app.overbright", category: "overlay")
    static let system = Logger(subsystem: "app.overbright", category: "system")
    static let ui = Logger(subsystem: "app.overbright", category: "ui")
}

/// Fixed-size ring buffer used for the median filter on headroom samples.
struct SampleWindow {
    private var storage: [Double]
    private var index = 0
    private var filled = 0

    init(capacity: Int, initial: Double) {
        storage = Array(repeating: initial, count: max(1, capacity))
        filled = storage.count
    }

    mutating func push(_ value: Double) {
        storage[index] = value
        index = (index + 1) % storage.count
        filled = min(filled + 1, storage.count)
    }

    /// Median rejects single-sample spikes without the lag of an average.
    var median: Double {
        let slice = Array(storage.prefix(filled)).sorted()
        guard !slice.isEmpty else { return 1.0 }
        return slice[slice.count / 2]
    }

    var maximum: Double { storage.prefix(filled).max() ?? 1.0 }
    var minimum: Double { storage.prefix(filled).min() ?? 1.0 }

    mutating func reset(to value: Double) {
        for i in storage.indices { storage[i] = value }
        filled = storage.count
        index = 0
    }
}
