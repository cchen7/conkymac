import CSystemPrivate
import Foundation
import IOKit

public struct CPUFrequency: Codable, Sendable, Equatable {
    /// nil when the cluster spent the whole interval idle.
    public let efficiencyMHz: Double?
    public let performanceMHz: Double?
}

/// Pure sensor arithmetic, kept apart from the private-API reads for tests.
enum SensorMath {
    /// pmgr `voltage-states*-sram`: 8-byte entries, little-endian u32 frequency then voltage.
    /// M4 and later report kHz, earlier chips Hz; returns MHz.
    static func dvfsTable(_ data: Data) -> [Double] {
        let bytes = [UInt8](data)
        let values = stride(from: 0, to: bytes.count - 7, by: 8).map { offset in
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
        }.filter { $0 > 0 }
        let divisor: Double = (values.max() ?? 0) > 100_000_000 ? 1_000_000 : 1_000
        return values.map { Double($0) / divisor }
    }

    /// Residency-weighted frequency over active states. nil when the states do not line up
    /// with the table, so a renamed or reordered table never yields a plausible wrong number.
    static func cluster(states: [(name: String, residency: Int64)], table: [Double]) -> (megahertz: Double, active: Double)? {
        guard let first = states.firstIndex(where: { !["IDLE", "DOWN", "OFF"].contains($0.name) }),
              states.count - first == table.count, !table.isEmpty else { return nil }
        let active = states[first...].reduce(0.0) { $0 + Double(max(0, $1.residency)) }
        guard active > 0 else { return (0, 0) }
        let weighted = zip(states[first...], table).reduce(0.0) { $0 + Double(max(0, $1.0.residency)) * $1.1 }
        return (weighted / active, active)
    }

    /// Clusters of one kind (e.g. two P clusters) merge by active residency.
    static func merge(_ clusters: [(megahertz: Double, active: Double)]) -> Double? {
        let active = clusters.reduce(0.0) { $0 + $1.active }
        return active > 0 ? clusters.reduce(0.0) { $0 + $1.megahertz * $1.active } / active : nil
    }

    /// CPU cluster sensors (16 keys on M4 Max). Their maximum matched the maximum of all
    /// ~67 per-core Tp0*/Te0* keys idle, under load and cooling, at a quarter of the reads.
    static func isCPUTemperatureKey(_ name: String) -> Bool {
        name.hasPrefix("Tpx") || name.hasPrefix("Tex")
    }

    /// GPU die sensors (44 on M4 Max, several pairs offset by a constant); hottest, like CPU.
    static func isGPUTemperatureKey(_ name: String) -> Bool { name.hasPrefix("Tg") }

    /// Hottest plausible core. P-core sensors read a floor of 40 °C when idle, which would
    /// drag an average down; the maximum follows whichever cluster is actually working.
    static func hottest(_ readings: [Double]) -> Double? {
        readings.filter { (10...120).contains($0) }.max()
    }
}

/// Read-only SMC temperatures and IOReport cluster residency. Private interfaces, verified
/// only on M4 Max / macOS 27; key and property names change between chip generations.
final class SensorCollector {
    private var smc: io_connect_t = 0
    private var temperatureKeys: (cpu: [UInt32], gpu: [UInt32])?
    private var subscription: IOReportSubscriptionRef?
    private var subscribed: CFMutableDictionary?
    private var previous: CFDictionary?
    private let efficiencyTable: [Double]
    private let performanceTable: [Double]
    private(set) var frequencyIssue: String?

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service != 0 {
            if IOServiceOpen(service, mach_task_self_, 0, &smc) != kIOReturnSuccess { smc = 0 }
            IOObjectRelease(service)
        }
        let pmgr = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        func table(_ name: String) -> [Double] {
            guard pmgr != 0, let value = IORegistryEntryCreateCFProperty(pmgr, name as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(), let data = value as? Data else { return [] }
            return SensorMath.dvfsTable(data)
        }
        efficiencyTable = table("voltage-states1-sram")
        performanceTable = table("voltage-states5-sram")
        if pmgr != 0 { IOObjectRelease(pmgr) }
        if let channels = IOReportCopyChannelsInGroup("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0),
           let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels) {
            var out: Unmanaged<CFMutableDictionary>?
            // Lives as long as the collector, which lives as long as the app.
            subscription = IOReportCreateSubscription(nil, mutable, &out, 0, nil)
            subscribed = out?.takeRetainedValue()
        }
        if subscription == nil { frequencyIssue = "Frequency: IOReport subscription unavailable" }
        else if efficiencyTable.isEmpty || performanceTable.isEmpty { frequencyIssue = "Frequency: pmgr DVFS tables unavailable" }
    }

    deinit { if smc != 0 { IOServiceClose(smc) } }

    func resetBaseline() { previous = nil }

    /// Delta since the previous call, so the 1 Hz sampler needs no extra sleep. nil on the first call.
    func frequency() -> CPUFrequency? {
        guard frequencyIssue == nil, let subscription, let subscribed,
              let current = IOReportCreateSamples(subscription, subscribed, nil) else { return nil }
        defer { previous = current }
        guard let previous, let delta = IOReportCreateSamplesDelta(previous, current, nil),
              let channels = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }
        var efficiency: [(megahertz: Double, active: Double)] = []
        var performance: [(megahertz: Double, active: Double)] = []
        for channel in channels {
            guard let name = IOReportChannelGetChannelName(channel) as String? else { continue }
            let isEfficiency = name.hasPrefix("ECPU")
            guard isEfficiency || name.hasPrefix("PCPU") else { continue }
            let states = (0..<IOReportStateGetCount(channel)).map {
                (name: IOReportStateGetNameForIndex(channel, $0) as String? ?? "", residency: IOReportStateGetResidency(channel, $0))
            }
            guard let cluster = SensorMath.cluster(states: states, table: isEfficiency ? efficiencyTable : performanceTable) else {
                frequencyIssue = "Frequency: \(name) states do not match the DVFS table"
                return nil
            }
            if isEfficiency { efficiency.append(cluster) } else { performance.append(cluster) }
        }
        guard !efficiency.isEmpty || !performance.isEmpty else { return nil }
        return CPUFrequency(efficiencyMHz: SensorMath.merge(efficiency), performanceMHz: SensorMath.merge(performance))
    }

    func temperatures() -> (cpu: Double?, gpu: Double?) {
        guard smc != 0 else { return (nil, nil) }
        if temperatureKeys == nil { temperatureKeys = discoverTemperatureKeys() }
        return (SensorMath.hottest(temperatureKeys?.cpu.compactMap(readFloat) ?? []),
                SensorMath.hottest(temperatureKeys?.gpu.compactMap(readFloat) ?? []))
    }

    private func call(_ input: SMCKeyData) -> SMCKeyData? {
        var input = input
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.size
        guard IOConnectCallStructMethod(smc, 2, &input, MemoryLayout<SMCKeyData>.size, &output, &size) == kIOReturnSuccess,
              output.result == 0 else { return nil }
        return output
    }

    private static func fourCC(_ string: String) -> UInt32 { string.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func name(_ key: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: key >> $0) }, as: UTF8.self)
    }

    private func readBytes(_ key: UInt32) -> (info: SMCKeyInfo, bytes: [UInt8])? {
        var input = SMCKeyData()
        input.key = key
        input.data8 = 9 // key info
        guard let info = call(input)?.keyInfo else { return nil }
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5 // read bytes
        guard let output = call(input) else { return nil }
        return (info, withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(info.dataSize, 32)))) })
    }

    /// Enumerates the SMC key table once (about 3,500 keys, ~30 ms here).
    private func discoverTemperatureKeys() -> (cpu: [UInt32], gpu: [UInt32]) {
        guard let count = readBytes(Self.fourCC("#KEY")), count.bytes.count >= 4 else { return ([], []) }
        let total = count.bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let float = Self.fourCC("flt ")
        var keys: (cpu: [UInt32], gpu: [UInt32]) = ([], [])
        for index in 0..<min(total, 10_000) {
            var input = SMCKeyData()
            input.data8 = 8 // key at index
            input.data32 = index
            guard let key = call(input)?.key else { continue }
            let name = Self.name(key)
            let cpu = SensorMath.isCPUTemperatureKey(name)
            guard cpu || SensorMath.isGPUTemperatureKey(name),
                  let value = readBytes(key), value.info.dataType == float, value.info.dataSize == 4 else { continue }
            if cpu { keys.cpu.append(key) } else { keys.gpu.append(key) }
        }
        return keys
    }

    /// Discovery already checked type and size, so one SMC call per key instead of two.
    private func readFloat(_ key: UInt32) -> Double? {
        var input = SMCKeyData()
        input.key = key
        input.keyInfo.dataSize = 4
        input.data8 = 5 // read bytes
        guard let output = call(input) else { return nil }
        return Double(withUnsafeBytes(of: output.bytes) { $0.loadUnaligned(as: Float32.self) })
    }
}
