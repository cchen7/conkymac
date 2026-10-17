import Darwin
import Foundation

/// Inputs for Conky template variables. Fractions are 0...1; nil means unavailable.
public struct ConkyValues: Sendable {
    public var date: Date
    public var utc: Bool
    public var cpu: Double?
    /// Per-core load, index 0 = Conky's cpu1. nil falls back to the total.
    public var cores: [Double]?
    /// Fractions used by `${memperc}`, `${fs_used_perc}` and the bars.
    public var memory: Double?
    public var storage: Double?
    public var battery: Double?
    public var uptime: Double?
    public var updates: Int
    // Byte counts, strings and lists for `conky.text`.
    public var memoryBytes: (used: Double, total: Double)?
    public var swapBytes: (used: Double, total: Double)?
    public var storageBytes: (used: Double, total: Double)?
    public var batteryState: String?
    public var loadAverage: [Double]?
    public var host: HostIdentity?
    public var network: Network?
    public var processesByCPU: [ProcessSample] = []
    public var processesByMemory: [ProcessSample] = []
    public var processCount: Int?
    public var runningProcessCount: Int?
    public var temperature: Double?
    public var frequency: CPUFrequency?
    public var coreKinds: String?

    public init(date: Date, utc: Bool = false, cpu: Double? = nil, cores: [Double]? = nil, memory: Double? = nil,
                storage: Double? = nil, battery: Double? = nil, uptime: Double? = nil, updates: Int = 0) {
        self.date = date; self.utc = utc; self.cpu = cpu; self.cores = cores; self.memory = memory
        self.storage = storage; self.battery = battery; self.uptime = uptime; self.updates = updates
    }

    public init(snapshot: Snapshot?, date: Date? = nil, utc: Bool = false, updates: Int = 0) {
        self.init(date: date ?? snapshot?.sampledAt ?? Date(), utc: utc, cpu: snapshot?.cpuFraction,
                  cores: snapshot?.coreFractions, memory: snapshot?.memory?.fraction, storage: snapshot?.storage?.fraction,
                  battery: snapshot?.battery?.fraction, uptime: snapshot?.uptime, updates: updates)
        guard let snapshot else { return }
        memoryBytes = snapshot.memory.map { ($0.used, $0.total) }
        swapBytes = snapshot.swap.map { ($0.used, $0.total) }
        storageBytes = snapshot.storage.map { ($0.used, $0.total) }
        batteryState = snapshot.battery?.state
        loadAverage = snapshot.loadAverage
        host = snapshot.host
        network = snapshot.network
        processesByCPU = snapshot.processes ?? []
        processesByMemory = snapshot.processesByMemory ?? []
        processCount = snapshot.processCount
        runningProcessCount = snapshot.runningProcessCount
        temperature = snapshot.temperatureCelsius
        frequency = snapshot.frequency
        coreKinds = snapshot.coreKinds
    }
}

/// Number formatting as Conky prints it (`human_readable` in conky.cc, `format_seconds*` in common.cc).
public enum ConkyFormat {
    /// <1000 B prints as "512B"; otherwise divides by 1024 and keeps three significant digits:
    /// "1.46KiB", "23.4GiB", "403MiB". `short` keeps only the unit's first letter.
    public static func humanReadable(_ value: Double, short: Bool = false, enabled: Bool = true) -> String {
        guard value.isFinite else { return "0B" }
        var number = Int64(max(-9.2e18, min(9.2e18, value)))
        guard enabled else { return String(number) }
        let suffixes = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        func unit(_ index: Int) -> String { short ? String(suffixes[index].prefix(1)) : suffixes[index] }
        if abs(number) < 1000 { return "\(number)\(unit(0))" }
        var index = 0
        while abs(number / 1024) >= 1000 && index < 4 { number /= 1024; index += 1 }
        index += 1
        let scaled = Double(number) / 1024
        let precision = scaled < 9.995 ? 2 : (scaled < 99.95 ? 1 : 0)
        return String(format: "%.\(precision)f", scaled) + unit(index)
    }

    public static func uptime(_ seconds: Double, short: Bool) -> String {
        let total = seconds.isFinite ? Int(max(0, min(1e12, seconds))) : 0
        let (days, hours, minutes, rest) = (total / 86400, total / 3600 % 24, total / 60 % 60, total % 60)
        if short {
            if days > 0 { return "\(days)d \(hours)h" }
            return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m \(rest)s"
        }
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m \(rest)s"
    }

    static func percent(_ value: Double?) -> String {
        String(Int((min(1, max(0, value ?? 0)) * 100).rounded()))
    }

    static func strftime(_ format: String, date: Date, utc: Bool, zoneOffset: Int? = nil) -> String {
        var time = time_t(date.timeIntervalSince1970.rounded(.down))
        if let zoneOffset { time += time_t(zoneOffset) }
        var parts = tm()
        if utc || zoneOffset != nil { gmtime_r(&time, &parts) } else { localtime_r(&time, &parts) }
        var buffer = [CChar](repeating: 0, count: 512)
        let count = Darwin.strftime(&buffer, buffer.count, format, &parts)
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The value-producing variables of Conky's template language, shared by `conky_parse` and
/// `conky.text`. Returns nil for names it does not know. Commands that run programs or read
/// files (exec*, lua*, cat, head, tail, include, curl, ...) are deliberately not implemented.
enum ConkyVariables {
    static func value(_ name: String, _ argument: String, _ values: ConkyValues, _ settings: ConkySettings) -> String? {
        let tokens = argument.split(whereSeparator: \.isWhitespace).map(String.init)
        func bytes(_ amount: Double?) -> String {
            ConkyFormat.humanReadable(amount ?? 0, short: settings.shortUnits, enabled: settings.formatHumanReadable)
        }
        switch name {
        case "time": return ConkyFormat.strftime(argument.isEmpty ? "%F %T" : argument, date: values.date, utc: values.utc)
        case "tztime":
            guard let zoneName = tokens.first, let zone = TimeZone(identifier: zoneName) else { return "" }
            let format = String(argument.dropFirst(zoneName.count)).trimmingCharacters(in: .whitespaces)
            let offset = zone.secondsFromGMT(for: values.date)
            return ConkyFormat.strftime(format.isEmpty ? "%F %T" : format, date: values.date, utc: values.utc, zoneOffset: offset)
        case "cpu":
            guard argument.hasPrefix("cpu"), let core = Int(argument.dropFirst(3)), core > 0 else { return ConkyFormat.percent(values.cpu) }
            guard let cores = values.cores, core <= cores.count else { return ConkyFormat.percent(values.cpu) }
            return ConkyFormat.percent(cores[core - 1])
        case "memperc": return ConkyFormat.percent(values.memory)
        case "swapperc":
            return ConkyFormat.percent(values.swapBytes.flatMap { $0.total > 0 ? $0.used / $0.total : 0 })
        case "fs_used_perc": return argument.isEmpty || argument == "/" ? ConkyFormat.percent(values.storage) : nil
        case "battery_percent": return ConkyFormat.percent(values.battery)
        case "battery_short":
            let letter = switch values.batteryState { case "Charging": "C"; case "AC power": "F"; case "On battery": "D"; default: "U" }
            return "\(letter) \(ConkyFormat.percent(values.battery))%"
        case "updates": return String(values.updates)
        case "uptime": return values.uptime.map { ConkyFormat.uptime($0, short: false) } ?? ""
        case "uptime_short": return values.uptime.map { ConkyFormat.uptime($0, short: true) } ?? ""
        case "mem": return bytes(values.memoryBytes?.used)
        case "memmax": return bytes(values.memoryBytes?.total)
        case "memfree", "memeasyfree": return bytes(values.memoryBytes.map { $0.total - $0.used })
        case "swap": return bytes(values.swapBytes?.used)
        case "swapmax": return bytes(values.swapBytes?.total)
        case "swapfree": return bytes(values.swapBytes.map { $0.total - $0.used })
        case "fs_used", "fs_size", "fs_free":
            guard argument.isEmpty || argument == "/" else { return nil }
            guard let disk = values.storageBytes else { return bytes(0) }
            return bytes(name == "fs_used" ? disk.used : (name == "fs_size" ? disk.total : disk.total - disk.used))
        // The interface argument is ignored: Linux names (wlan0, eth0) do not exist here, so the
        // active interface stands in for whichever one the theme asks about.
        case "downspeed": return bytes(values.network?.downloadBytesPerSecond)
        case "upspeed": return bytes(values.network?.uploadBytesPerSecond)
        case "totaldown": return bytes(values.network?.sessionDownloadBytes)
        case "totalup": return bytes(values.network?.sessionUploadBytes)
        case "downspeedf": return String(format: "%.1f", (values.network?.downloadBytesPerSecond ?? 0) / 1024)
        case "upspeedf": return String(format: "%.1f", (values.network?.uploadBytesPerSecond ?? 0) / 1024)
        case "loadavg":
            guard let load = values.loadAverage, load.count == 3 else { return "0.00" }
            if let which = tokens.first.flatMap(Int.init), (1...3).contains(which) { return String(format: "%.2f", load[which - 1]) }
            return String(format: "%.2f %.2f %.2f", load[0], load[1], load[2])
        case "kernel": return values.host?.release ?? ""
        case "machine": return values.host?.machine ?? ""
        case "sysname": return values.host?.sysname ?? ""
        case "nodename": return values.host?.nodename ?? ""
        case "nodename_short": return values.host?.nodename.split(separator: ".").first.map(String.init) ?? ""
        case "processes": return values.processCount.map(String.init) ?? "0"
        case "running_processes": return values.runningProcessCount.map(String.init) ?? "0"
        case "freq", "freq_g":
            let core = tokens.first.flatMap(Int.init) ?? 1
            let kinds = values.coreKinds.map(Array.init) ?? []
            let efficiency = core >= 1 && core <= kinds.count ? kinds[core - 1] == "E" : false
            let megahertz = (efficiency ? values.frequency?.efficiencyMHz : values.frequency?.performanceMHz) ?? 0
            return name == "freq" ? String(format: "%.0f", megahertz) : String(format: "%.2f", megahertz / 1000)
        case "acpitemp": return values.temperature.map { String(Int(max(-273, min(1000, $0.rounded())))) } ?? "0"
        case "top", "top_mem": return top(byMemory: name == "top_mem", tokens, values, settings)
        default: return nil
        }
    }

    /// `${top type N}`: columns as in data/top.cc (name padded/cut to top_name_width+1, cpu %6.2f,
    /// pid %7i). mem is the share of RAM; vsize and user are not collected, so they are unknown.
    private static func top(byMemory: Bool, _ tokens: [String], _ values: ConkyValues, _ settings: ConkySettings) -> String? {
        guard tokens.count >= 2, let rank = Int(tokens[1]), (1...10).contains(rank) else { return nil }
        let list = byMemory ? values.processesByMemory : values.processesByCPU
        guard rank <= list.count else {
            return ["name": String(repeating: " ", count: settings.topNameWidth + 1)][tokens[0]] ?? ""
        }
        let process = list[rank - 1]
        switch tokens[0] {
        case "name":
            let width = settings.topNameWidth + 1
            let cut = String(process.name.prefix(width))
            return cut + String(repeating: " ", count: max(0, width - cut.count))
        case "cpu": return String(format: "%6.2f", process.cpuPercent)
        case "pid": return String(format: "%7d", process.pid)
        case "mem":
            let total = values.memoryBytes?.total ?? 0
            return String(format: "%6.2f", total > 0 ? process.memoryBytes / total * 100 : 0)
        case "mem_res": return ConkyFormat.humanReadable(process.memoryBytes, short: settings.shortUnits, enabled: settings.formatHumanReadable)
        default: return nil
        }
    }
}

/// The subset of Conky's template language that Lua themes pass to conky_parse.
/// Unavailable numeric readings print "0", as Conky does; unknown variables print "".
/// Layout objects (colors, fonts, goto, ...) have no meaning here and print nothing.
public enum ConkyTemplate {
    public static func evaluate(_ template: String, values: ConkyValues, settings: ConkySettings = ConkySettings(),
                                unknown: (String) -> Void = { _ in }) -> String {
        guard template.contains("$") else { return template }
        var output = ""
        for node in ConkyTextParser.parse(template, comments: false) {
            switch node {
            case .text(let text): output += text
            case .newline: output += "\n"
            case .object(let name, let argument):
                if let value = ConkyVariables.value(name, argument, values, settings) { output += value }
                else if !ConkyText.isLayoutObject(name) { unknown(argument.isEmpty ? name : "\(name) \(argument)") }
            }
        }
        return output
    }
}
