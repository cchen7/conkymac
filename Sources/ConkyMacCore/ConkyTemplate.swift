import Darwin
import Foundation

/// Inputs for Conky template variables. Fractions are 0...1; nil means unavailable.
public struct ConkyValues: Sendable {
    public var date: Date
    public var utc: Bool
    public var cpu: Double?
    /// Per-core load, index 0 = Conky's cpu1. nil falls back to the total.
    public var cores: [Double]?
    public var memory: Double?
    public var storage: Double?
    public var battery: Double?
    public var uptime: Double?
    public var updates: Int

    public init(date: Date, utc: Bool = false, cpu: Double? = nil, cores: [Double]? = nil, memory: Double? = nil,
                storage: Double? = nil, battery: Double? = nil, uptime: Double? = nil, updates: Int = 0) {
        self.date = date; self.utc = utc; self.cpu = cpu; self.cores = cores; self.memory = memory
        self.storage = storage; self.battery = battery; self.uptime = uptime; self.updates = updates
    }
}

/// The subset of Conky's template language that Lua themes pass to conky_parse.
/// Unavailable numeric readings print "0", as Conky does; unknown variables print "".
public enum ConkyTemplate {
    public static func evaluate(_ template: String, values: ConkyValues, unknown: (String) -> Void = { _ in }) -> String {
        guard template.contains("$") else { return template }
        var output = ""
        var index = template.startIndex
        let end = template.endIndex
        while index < end {
            let character = template[index]
            index = template.index(after: index)
            guard character == "$", index < end else { output.append(character); continue }
            let body: Substring
            if template[index] == "$" {
                output.append("$"); index = template.index(after: index); continue
            } else if template[index] == "{" {
                guard let close = template[index...].firstIndex(of: "}") else { output += template[template.index(before: index)...]; break }
                body = template[template.index(after: index)..<close]
                index = template.index(after: close)
            } else {
                let name = template[index...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                guard !name.isEmpty else { output.append("$"); continue }
                body = name
                index = name.endIndex
            }
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            let name = String(trimmed.prefix { !$0.isWhitespace })
            let argument = trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            if let value = variable(name, argument, values) { output += value } else { unknown(argument.isEmpty ? name : "\(name) \(argument)") }
        }
        return output
    }

    private static func variable(_ name: String, _ argument: String, _ values: ConkyValues) -> String? {
        switch name {
        case "time": return strftime(argument.isEmpty ? "%F %T" : argument, date: values.date, utc: values.utc)
        case "cpu":
            guard argument.hasPrefix("cpu"), let core = Int(argument.dropFirst(3)), core > 0 else { return percent(values.cpu) }
            guard let cores = values.cores, core <= cores.count else { return percent(values.cpu) }
            return percent(cores[core - 1])
        case "memperc": return percent(values.memory)
        case "fs_used_perc": return argument.isEmpty || argument == "/" ? percent(values.storage) : nil
        case "battery_percent": return percent(values.battery)
        case "updates": return String(values.updates)
        case "uptime":
            guard let uptime = values.uptime else { return "" }
            let seconds = Int(uptime)
            let (days, hours, minutes) = (seconds / 86400, seconds / 3600 % 24, seconds / 60 % 60)
            return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m \(seconds % 60)s"
        default: return nil
        }
    }

    private static func percent(_ value: Double?) -> String {
        String(Int((min(1, max(0, value ?? 0)) * 100).rounded()))
    }

    private static func strftime(_ format: String, date: Date, utc: Bool) -> String {
        var time = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        if utc { gmtime_r(&time, &parts) } else { localtime_r(&time, &parts) }
        var buffer = [CChar](repeating: 0, count: 512)
        let count = Darwin.strftime(&buffer, buffer.count, format, &parts)
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
