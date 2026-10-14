import Foundation

public struct Capacity: Codable, Sendable {
    public let used: Double
    public let total: Double
    public let sampledAt: Date
    public var fraction: Double { total > 0 ? min(1, max(0, used / total)) : 0 }
}

public struct Battery: Codable, Sendable {
    public let fraction: Double?
    public let state: String
    public let sampledAt: Date
}

public struct Network: Codable, Sendable {
    public let interface: String
    public let uploadBytesPerSecond: Double?
    public let downloadBytesPerSecond: Double?
    public let sessionUploadBytes: Double
    public let sessionDownloadBytes: Double
}

/// Immutable, app-wide input. nil means unavailable or waiting for a baseline.
/// Rates use monotonic time; sampledAt is wall time for display and diagnostics.
public struct Snapshot: Codable, Sendable {
    public let sequence: UInt64
    public let sampledAt: Date
    public let systemVersion: String
    public let uptime: Double?
    public let cpuFraction: Double?
    /// Per logical core, in host_processor_info order; nil until a baseline exists.
    public let coreFractions: [Double]?
    public let temperatureCelsius: Double?
    public let frequency: CPUFrequency?
    public let memory: Capacity?
    public let storage: Capacity?
    public let battery: Battery?
    public let network: Network?
    public let processes: [ProcessSample]?
    public let issues: [String]
    public let collectionMilliseconds: Double

    public static let fixture = Snapshot(
        sequence: 1, sampledAt: Date(timeIntervalSince1970: 1778077020), systemVersion: "macOS 14.0", uptime: 29_321,
        cpuFraction: 0.14,
        coreFractions: [0.31, 0.22, 0.18, 0.12, 0.09, 0.07, 0.15, 0.04, 0.11, 0.06, 0.20, 0.03, 0.08, 0.13, 0.05, 0.10],
        temperatureCelsius: 47, frequency: CPUFrequency(efficiencyMHz: 2_571, performanceMHz: 3_610),
        memory: Capacity(used: 23 * pow(1024, 3), total: 64 * pow(1024, 3), sampledAt: Date(timeIntervalSince1970: 1778077020)),
        storage: Capacity(used: 412 * pow(1024, 3), total: 994 * pow(1024, 3), sampledAt: Date(timeIntervalSince1970: 1778077020)),
        battery: Battery(fraction: 0.86, state: "On battery", sampledAt: Date(timeIntervalSince1970: 1778077020)),
        network: Network(interface: "en0", uploadBytesPerSecond: 18_432, downloadBytesPerSecond: 293_601,
                         sessionUploadBytes: 5_987_369, sessionDownloadBytes: 510_656_512),
        processes: [
            ProcessSample(pid: 407, name: "WindowServer", cpuPercent: 12.4, memoryBytes: 612 * pow(1024, 2)),
            ProcessSample(pid: 3735, name: "Google Chrome", cpuPercent: 7.1, memoryBytes: 1.4 * pow(1024, 3)),
            ProcessSample(pid: 3027, name: "Surge", cpuPercent: 6.0, memoryBytes: 188 * pow(1024, 2)),
            ProcessSample(pid: 3760, name: "Google Chrome Helper (Renderer)", cpuPercent: 3.4, memoryBytes: 402 * pow(1024, 2)),
            ProcessSample(pid: 682, name: "Finder", cpuPercent: 2.0, memoryBytes: 96 * pow(1024, 2))
        ],
        issues: [], collectionMilliseconds: 0
    )
}

public struct CPUTicks: Sendable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }

    public func fraction(since previous: CPUTicks) -> Double? {
        let deltas = [user &- previous.user, system &- previous.system,
                      idle &- previous.idle, nice &- previous.nice]
        // Small wrapping deltas are valid. A huge backwards jump means reset.
        guard deltas.allSatisfy({ $0 <= UInt32(Int32.max) }) else { return nil }
        let total = deltas.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { return nil }
        return Double(total - UInt64(deltas[2])) / Double(total)
    }
}

public struct NetworkCounter: Sendable {
    public let interface: String
    public let received: UInt64
    public let sent: UInt64
    public let time: Double
    public init(interface: String, received: UInt64, sent: UInt64, time: Double) {
        self.interface = interface; self.received = received; self.sent = sent; self.time = time
    }
}

public struct NetworkTracker {
    private var previous: NetworkCounter?
    private var upload: Double = 0
    private var download: Double = 0
    public init() {}

    public mutating func resetBaseline() { previous = nil }

    public mutating func update(_ current: NetworkCounter?) -> Network? {
        guard let current else {
            previous = nil
            return nil
        }
        defer { previous = current }
        let elapsed = current.time - (previous?.time ?? current.time)
        guard let old = previous, old.interface == current.interface, elapsed > 0, elapsed <= 5,
              let sentDelta = Self.delta(current.sent, since: old.sent, elapsed: elapsed),
              let receivedDelta = Self.delta(current.received, since: old.received, elapsed: elapsed) else {
            return Network(interface: current.interface, uploadBytesPerSecond: nil,
                           downloadBytesPerSecond: nil, sessionUploadBytes: upload, sessionDownloadBytes: download)
        }
        let sent = Double(sentDelta)
        let received = Double(receivedDelta)
        upload += sent; download += received
        return Network(interface: current.interface, uploadBytesPerSecond: sent / (current.time - old.time),
                       downloadBytesPerSecond: received / (current.time - old.time),
                       sessionUploadBytes: upload, sessionDownloadBytes: download)
    }

    /// Unprivileged readers may get byte counters truncated to 32 bits (seen on macOS 27).
    /// A wrap is accepted only if it implies <= 10 Gbit/s; anything else is a reset, which
    /// costs one interval instead of adding phantom traffic to the session totals.
    static func delta(_ current: UInt64, since old: UInt64, elapsed: Double) -> UInt64? {
        if current >= old { return current - old }
        guard old <= UInt64(UInt32.max) else { return nil }
        let wrapped = UInt64(UInt32.max) + 1 - old + current
        return Double(wrapped) <= min(Double(Int32.max), 1.25e9 * elapsed) ? wrapped : nil
    }
}

/// Fixed memory, ordered oldest-to-newest only when the renderer requests it.
public struct History {
    private var storage: [Double?]
    private var cursor = 0
    public private(set) var count = 0
    public init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }
    public mutating func append(_ value: Double?) {
        storage[cursor] = value.map { min(1, max(0, $0)) }
        cursor = (cursor + 1) % storage.count
        count = min(count + 1, storage.count)
    }
    public var values: [Double?] {
        let start = count == storage.count ? cursor : 0
        return (0..<count).map { storage[(start + $0) % storage.count] }
    }
}
