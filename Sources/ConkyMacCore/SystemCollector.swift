import Darwin
import Foundation
import IOKit.ps
import SystemConfiguration

/// Owned by one sampling queue (or one synchronous CLI loop), never by the UI.
public final class SystemCollector {
    private let host = mach_host_self()
    private let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
    private let systemVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }()
    private let requestedInterface: String?
    private let bootDate: Date?
    private var previousCPU: CPUTicks?
    private var previousTime: Double?
    private var networkTracker = NetworkTracker()
    private var sequence: UInt64 = 0
    private var storage: Capacity?
    private var battery: Battery?
    private var slowIssues: [String] = []
    private var nextSlowSample: Double = 0

    public init(interface: String? = nil) {
        requestedInterface = interface
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        bootDate = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0
            ? Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000) : nil
    }
    deinit { mach_port_deallocate(mach_task_self_, host) }

    public func sample() -> Snapshot {
        let started = Self.continuousSeconds()
        let now = Date()
        sequence += 1
        var issues: [String] = []
        if bootDate == nil { issues.append("Uptime: kern.boottime unavailable") }
        let ticks = readCPU()
        var cpu: Double?
        if let ticks, let old = previousCPU, let time = previousTime, started - time <= 5 {
            cpu = ticks.fraction(since: old)
        }
        previousCPU = ticks; previousTime = started
        if ticks == nil { issues.append("CPU: host_statistics unavailable") }
        let memory = readMemory(at: now)
        if memory == nil { issues.append("Memory: host_statistics64 unavailable") }
        let network = networkTracker.update(readNetwork(at: started))
        if network == nil { issues.append("Network: interface/counters unavailable") }
        if started >= nextSlowSample {
            slowIssues = []
            storage = readStorage(at: now)
            battery = readBattery(at: now)
            if storage == nil { slowIssues.append("Storage: filesystem statistics unavailable") }
            if battery == nil { slowIssues.append("Battery: IOPowerSources unavailable") }
            nextSlowSample = started + 30
        }
        issues += slowIssues
        return Snapshot(sequence: sequence, sampledAt: now, systemVersion: systemVersion,
                        uptime: bootDate.map { max(0, now.timeIntervalSince($0)) }, cpuFraction: cpu,
                        memory: memory, storage: storage, battery: battery, network: network,
                        issues: issues, collectionMilliseconds: (Self.continuousSeconds() - started) * 1000)
    }

    public func resetBaselines() {
        previousCPU = nil; previousTime = nil
        networkTracker.resetBaseline()
        nextSlowSample = 0
    }

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private static func continuousSeconds() -> Double {
        Double(mach_continuous_time()) * secondsPerTick
    }

    private func readCPU() -> CPUTicks? {
        var value = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: value.cpu_ticks.0, system: value.cpu_ticks.1,
                        idle: value.cpu_ticks.2, nice: value.cpu_ticks.3)
    }

    private func readMemory(at date: Date) -> Capacity? {
        var value = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Stats RAM formula; see THIRD_PARTY_NOTICES.md. This is not total-free.
        let pages = Double(value.active_count) + Double(value.inactive_count) + Double(value.speculative_count)
            + Double(value.wire_count) + Double(value.compressor_page_count)
            - Double(value.purgeable_count) - Double(value.external_page_count)
        return Capacity(used: min(totalMemory, max(0, pages * Double(getpagesize()))), total: totalMemory, sampledAt: date)
    }

    private func readStorage(at date: Date) -> Capacity? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/System/Volumes/Data"),
              let total = attributes[.systemSize] as? NSNumber,
              let free = attributes[.systemFreeSize] as? NSNumber, total.doubleValue > 0 else { return nil }
        return Capacity(used: max(0, total.doubleValue - free.doubleValue), total: total.doubleValue, sampledAt: date)
    }

    private func readBattery(at date: Date) -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Double
            let maximum = description[kIOPSMaxCapacityKey] as? Double
            let fraction = current.flatMap { c in maximum.flatMap { $0 > 0 ? min(1, max(0, c / $0)) : nil } }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let ac = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return Battery(fraction: fraction, state: charging ? "Charging" : (ac ? "AC power" : "On battery"), sampledAt: date)
        }
        return Battery(fraction: nil, state: "No battery", sampledAt: date)
    }

    private func primaryInterface() -> String? {
        if let requestedInterface { return requestedInterface }
        for family in ["IPv4", "IPv6"] {
            if let state = SCDynamicStoreCopyValue(nil, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
               let name = state["PrimaryInterface"] as? String { return name }
        }
        return nil
    }

    private func readNetwork(at time: Double) -> NetworkCounter? {
        guard let name = primaryInterface() else { return nil }
        let index = if_nametoindex(name)
        guard index != 0 else { return nil }
        // if_data64 fields, but macOS 27 reports them to us truncated to 32 bits and 1 KiB steps.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0, size < 16 * 1024 * 1024 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { bytes in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length >= MemoryLayout<if_msghdr>.size, offset + length <= size else { return nil }
                if Int32(header.ifm_type) == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let info = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(info.ifm_index) == index, info.ifm_flags & IFF_UP != 0 {
                        return NetworkCounter(interface: name, received: info.ifm_data.ifi_ibytes,
                                              sent: info.ifm_data.ifi_obytes, time: time)
                    }
                }
                offset += length
            }
            return nil
        }
    }
}
