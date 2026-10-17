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
        var values = stride(from: 0, to: bytes.count - 7, by: 8).map { offset in
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
        }
        // Only trailing padding is dropped; an inner zero must keep later states aligned.
        while values.last == 0 { values.removeLast() }
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

    /// Chip generation from the CPU brand string ("Apple M4 Max" -> 4); nil if unparsable.
    static func generation(of brand: String) -> Int? {
        guard let range = brand.range(of: "Apple M") else { return nil }
        return Int(brand[range.upperBound...].prefix { $0.isNumber })
    }

    /// CPU temperature keys for one chip, as exelban/stats lists them per generation
    /// (Modules/CPU/readers.swift). M4 adds the Tpx*/Tex* cluster sensors, whose maximum matched the
    /// maximum of all ~67 per-core keys idle, under load and cooling on M4 Max (measured; M4 Max is
    /// the only chip checked on hardware). One list per chip, because a key means different things
    /// on different generations and any reading in 10...120 would raise the hottest value.
    /// An unparsable or newer chip tries the M5 list plus Tpx/Tex; `--sensors` shows what it finds.
    static func cpuTemperatureKeys(forChip brand: String) -> (prefixes: [String], names: Set<String>) {
        let m5 = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a",
                  "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        switch generation(of: brand) {
        case 1: return ([], ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"])
        case 2: return ([], ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"])
        case 3: return ([], ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                             "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"])
        case 4: return (["Tpx", "Tex"], ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"])
        case 5: return ([], Set(m5))
        default: return (["Tpx", "Tex"], Set(m5))
        }
    }

    static func isCPUTemperatureKey(_ name: String, chip: String) -> Bool {
        let keys = cpuTemperatureKeys(forChip: chip)
        return keys.names.contains(name) || keys.prefixes.contains { name.hasPrefix($0) }
    }

    /// IOReport "CPU Complex Performance States" channels and the pmgr tables that describe them.
    /// M5 splits P cores into PCPU ("super", voltage-states5) and MCPU ("performance",
    /// voltage-states22); earlier chips have only PCPU on voltage-states5. Stats' only fallback is
    /// MCPU -> voltage-states5 (M6). A table is used only if its length matches the channel's states,
    /// so a wrong guess shows N/A rather than a plausible number.
    static func clusterChannel(_ name: String) -> (efficiency: Bool, tables: [String])? {
        if name.hasPrefix("ECPU") { return (true, ["voltage-states1-sram"]) }
        if name.hasPrefix("PCPU") { return (false, ["voltage-states5-sram"]) }
        if name.hasPrefix("MCPU") { return (false, ["voltage-states22-sram", "voltage-states5-sram"]) }
        return nil
    }

    /// First candidate table whose length fits the channel's states.
    static func resolve(states: [(name: String, residency: Int64)], tables: [String: [Double]], candidates: [String])
        -> (table: String, megahertz: Double, active: Double)? {
        for key in candidates {
            if let table = tables[key], let cluster = cluster(states: states, table: table) {
                return (key, cluster.megahertz, cluster.active)
            }
        }
        return nil
    }

    /// Device-tree cluster-type to the two kinds the panel shows. M5 reports E, M ("performance")
    /// and P ("super"); both M and P count as performance.
    static func coreKind(clusterType: String) -> Character? {
        switch clusterType { case "E": "E"; case "P", "M": "P"; default: nil }
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
    private let dvfsTables: [String: [Double]]
    private let chip: String
    private(set) var frequencyIssue: String?

    init() {
        var brand = [CChar](repeating: 0, count: 128)
        var brandSize = brand.count
        sysctlbyname("machdep.cpu.brand_string", &brand, &brandSize, nil, 0)
        chip = String(decoding: brand.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service != 0 {
            if IOServiceOpen(service, mach_task_self_, 0, &smc) != kIOReturnSuccess { smc = 0 }
            IOObjectRelease(service)
        }
        // pmgr holds the tables; newer chips also expose a pmgr-child node.
        var tables: [String: [Double]] = [:]
        for node in ["pmgr", "pmgr-child"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching(node), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dictionary = properties?.takeRetainedValue() as? [String: Any] else { continue }
                // Every voltage-states* table is kept so --sensors can show unknown numbering; as in
                // Stats, a later node (pmgr-child) overrides an earlier one.
                for (key, value) in dictionary where key.hasPrefix("voltage-states") {
                    let table = (value as? Data).map(SensorMath.dvfsTable) ?? []
                    if !table.isEmpty { tables[key] = table }
                }
            }
        }
        dvfsTables = tables
        if let channels = IOReportCopyChannelsInGroup("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0),
           let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels) {
            var out: Unmanaged<CFMutableDictionary>?
            // Lives as long as the collector, which lives as long as the app.
            subscription = IOReportCreateSubscription(nil, mutable, &out, 0, nil)
            subscribed = out?.takeRetainedValue()
        }
        if subscription == nil { frequencyIssue = "Frequency: IOReport subscription unavailable" }
        else if dvfsTables.isEmpty { frequencyIssue = "Frequency: pmgr DVFS tables unavailable" }
    }

    deinit { if smc != 0 { IOServiceClose(smc) } }

    func resetBaseline() { previous = nil }

    /// Plain-text dump for checking a chip this app has not been verified on: chip, core types,
    /// DVFS tables, IOReport channel states, SMC temperature keys and what was selected.
    func diagnostics() -> String {
        var lines: [String] = []
        lines.append("chip: \(chip) (generation \(SensorMath.generation(of: chip).map(String.init) ?? "unknown")), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let types = SystemCollector.readRawCoreTypes()
        let counts = Dictionary(grouping: types.values, by: { $0 }).mapValues(\.count)
        lines.append("cores: \(types.count) logical; cluster-type counts \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        for (key, table) in dvfsTables.sorted(by: { $0.key < $1.key }) {
            lines.append("dvfs \(key): \(table.count) states, \(Int(table.first ?? 0))...\(Int(table.last ?? 0)) MHz")
        }
        if dvfsTables.isEmpty { lines.append("dvfs: no voltage-states tables found in pmgr/pmgr-child") }
        if let subscription, let subscribed, let sample = IOReportCreateSamples(subscription, subscribed, nil),
           let channels = (sample as NSDictionary)["IOReportChannels"] as? [CFDictionary] {
            for channel in channels {
                let name = IOReportChannelGetChannelName(channel) as String? ?? "?"
                let states = (0..<IOReportStateGetCount(channel)).map { IOReportStateGetNameForIndex(channel, $0) as String? ?? "?" }
                let match = SensorMath.clusterChannel(name).map { kind in
                    SensorMath.resolve(states: states.map { ($0, 1) }, tables: dvfsTables, candidates: kind.tables)?.table ?? "NO TABLE MATCH"
                } ?? "ignored"
                lines.append("ioreport \(name): \(states.count) states [\(states.joined(separator: " "))] -> \(match)")
            }
        } else {
            lines.append("ioreport: CPU Complex Performance States unavailable")
        }
        if smc == 0 {
            lines.append("smc: AppleSMC could not be opened")
        } else if let count = readBytes(Self.fourCC("#KEY")), count.bytes.count >= 4 {
            let total = count.bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            lines.append("smc: \(total) keys; temperature-like keys (T*, float) with value; * = CPU choice, g = GPU choice")
            let float = Self.fourCC("flt ")
            var shown: [String] = []
            for index in 0..<min(total, 10_000) {
                var input = SMCKeyData()
                input.data8 = 8
                input.data32 = index
                guard let key = call(input)?.key else { continue }
                let name = Self.name(key)
                guard name.hasPrefix("T"), let value = readBytes(key), value.info.dataType == float, value.info.dataSize == 4 else { continue }
                let reading = Double(value.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
                let mark = SensorMath.isCPUTemperatureKey(name, chip: chip) ? "*" : (SensorMath.isGPUTemperatureKey(name) ? "g" : "")
                shown.append("\(name)\(mark)=\(String(format: "%.1f", reading))")
            }
            lines.append(shown.joined(separator: " "))
        } else {
            lines.append("smc: key count unreadable")
        }
        let temperatures = self.temperatures()
        lines.append("result: cpu \(temperatures.cpu.map { String(format: "%.1f C", $0) } ?? "N/A"), gpu \(temperatures.gpu.map { String(format: "%.1f C", $0) } ?? "N/A")")
        lines.append("frequency issue: \(frequencyIssue ?? "none")")
        return lines.joined(separator: "\n")
    }

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
            guard let name = IOReportChannelGetChannelName(channel) as String?, let kind = SensorMath.clusterChannel(name) else { continue }
            let states = (0..<IOReportStateGetCount(channel)).map {
                (name: IOReportStateGetNameForIndex(channel, $0) as String? ?? "", residency: IOReportStateGetResidency(channel, $0))
            }
            guard let match = SensorMath.resolve(states: states, tables: dvfsTables, candidates: kind.tables) else {
                let tables = dvfsTables.map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ")
                frequencyIssue = "Frequency: \(name) has \(states.count) states, no DVFS table matches (\(tables))"
                return nil
            }
            let cluster = (megahertz: match.megahertz, active: match.active)
            if kind.efficiency { efficiency.append(cluster) } else { performance.append(cluster) }
        }
        guard !efficiency.isEmpty || !performance.isEmpty else { return nil }
        return CPUFrequency(efficiencyMHz: SensorMath.merge(efficiency), performanceMHz: SensorMath.merge(performance))
    }

    func temperatures() -> (cpu: Double?, gpu: Double?) {
        guard smc != 0 else { return (nil, nil) }
        if temperatureKeys == nil {
            // An empty result may be a transient SMC failure: keep retrying instead of caching it.
            let keys = discoverTemperatureKeys()
            if !keys.cpu.isEmpty || !keys.gpu.isEmpty { temperatureKeys = keys }
        }
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
            let cpu = SensorMath.isCPUTemperatureKey(name, chip: chip)
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
