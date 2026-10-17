import Foundation

/// `conky.config` values that change what the text says or how it is laid out. Values arrive as
/// strings (numbers and booleans are stringified by the bridge); anything else keeps Conky's default.
public struct ConkySettings: Sendable {
    public var font = "6x10"
    public var defaultColor = "white"
    public var colors: [Int: String] = [:]
    public var uppercase = false
    public var shortUnits = false
    public var formatHumanReadable = true
    public var topNameWidth = 15
    public var minimumWidth = 5.0
    public var minimumHeight = 0.0
    public var maximumWidth = 0.0
    public var drawShades = true
    public var drawOutline = false
    public var shadeColor = "black"
    public var outlineColor = "black"
    public var drawGraphBorders = true
    public var borderInnerMargin = 3.0
    public var borderOuterMargin = 1.0
    public var borderWidth = 1.0
    public var defaultBarHeight = 6.0
    public var defaultGraphHeight = 25.0

    public init() {}

    public init(config: [String: String]) {
        func number(_ key: String) -> Double? { config[key].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
        func flag(_ key: String) -> Bool? { config[key].flatMap { ["true", "yes", "1"].contains($0.lowercased()) ? true : (["false", "no", "0"].contains($0.lowercased()) ? false : nil) } }
        if let value = config["font"], !value.isEmpty { font = value }
        if let value = config["default_color"] ?? config["default_colour"], !value.isEmpty { defaultColor = value }
        for index in 0...9 { if let value = config["color\(index)"] ?? config["colour\(index)"] { colors[index] = value } }
        uppercase = flag("uppercase") ?? uppercase
        shortUnits = flag("short_units") ?? shortUnits
        formatHumanReadable = flag("format_human_readable") ?? formatHumanReadable
        // Clamp in Double space first: Int(1e300) would trap on a hostile theme.
        topNameWidth = number("top_name_width").map { Int(max(0, min(255, $0))) } ?? topNameWidth
        minimumWidth = number("minimum_width").map { max(0, min(4096, $0)) } ?? minimumWidth
        minimumHeight = number("minimum_height").map { max(0, min(4096, $0)) } ?? minimumHeight
        maximumWidth = number("maximum_width").map { max(0, min(4096, $0)) } ?? maximumWidth
        drawShades = flag("draw_shades") ?? drawShades
        drawOutline = flag("draw_outline") ?? drawOutline
        if let value = config["default_shade_color"] ?? config["default_shade_colour"] { shadeColor = value }
        if let value = config["default_outline_color"] ?? config["default_outline_colour"] { outlineColor = value }
        drawGraphBorders = flag("draw_graph_borders") ?? drawGraphBorders
        borderInnerMargin = number("border_inner_margin").map { max(0, min(100, $0)) } ?? borderInnerMargin
        borderOuterMargin = number("border_outer_margin").map { max(0, min(100, $0)) } ?? borderOuterMargin
        borderWidth = number("border_width").map { max(0, min(100, $0)) } ?? borderWidth
        defaultBarHeight = number("default_bar_height").map { max(1, min(512, $0)) } ?? defaultBarHeight
        defaultGraphHeight = number("default_graph_height").map { max(1, min(512, $0)) } ?? defaultGraphHeight
    }

    /// Conky always adds the border margins to the text origin, even when no border is drawn.
    public var textInset: Double { borderInnerMargin + borderOuterMargin + borderWidth }
}

public struct ConkyColor: Sendable, Equatable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// "#rgb", "#argb", "#rrggbb", "#aarrggbb" (the # is optional; 4 and 8 digits put alpha first,
    /// as in Conky) or an X11 colour name from a built-in subset.
    public static func parse(_ specification: String) -> ConkyColor? {
        let text = specification.trimmingCharacters(in: .whitespaces)
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) {
            var nibbles = digits.compactMap { $0.hexDigitValue }.map(Double.init)
            if digits.count <= 4 { nibbles = nibbles.flatMap { [$0, $0] } }
            let bytes = stride(from: 0, to: nibbles.count, by: 2).map { (nibbles[$0] * 16 + nibbles[$0 + 1]) / 255 }
            return bytes.count == 4 ? ConkyColor(red: bytes[1], green: bytes[2], blue: bytes[3], alpha: bytes[0])
                                    : ConkyColor(red: bytes[0], green: bytes[1], blue: bytes[2])
        }
        return names[text.lowercased().replacingOccurrences(of: " ", with: "")].map {
            ConkyColor(red: Double($0.0) / 255, green: Double($0.1) / 255, blue: Double($0.2) / 255)
        }
    }

    /// X11 rgb.txt values (gray, green, maroon and purple differ from CSS). A subset of common names.
    private static let names: [String: (Int, Int, Int)] = [
        "white": (255, 255, 255), "black": (0, 0, 0), "gray": (190, 190, 190), "grey": (190, 190, 190),
        "darkgray": (169, 169, 169), "darkgrey": (169, 169, 169), "lightgray": (211, 211, 211), "lightgrey": (211, 211, 211),
        "dimgray": (105, 105, 105), "dimgrey": (105, 105, 105), "slategray": (112, 128, 144), "slategrey": (112, 128, 144),
        "red": (255, 0, 0), "green": (0, 255, 0), "blue": (0, 0, 255), "yellow": (255, 255, 0), "cyan": (0, 255, 255),
        "magenta": (255, 0, 255), "orange": (255, 165, 0), "pink": (255, 192, 203), "purple": (160, 32, 240),
        "brown": (165, 42, 42), "gold": (255, 215, 0), "navy": (0, 0, 128), "maroon": (176, 48, 96),
        "violet": (238, 130, 238), "tomato": (255, 99, 71), "coral": (255, 127, 80), "salmon": (250, 128, 114),
        "khaki": (240, 230, 140), "tan": (210, 180, 140), "orchid": (218, 112, 214), "plum": (221, 160, 221),
        "turquoise": (64, 224, 208), "lavender": (230, 230, 250), "beige": (245, 245, 220), "ivory": (255, 255, 240),
        "wheat": (245, 222, 179), "chocolate": (210, 105, 30), "firebrick": (178, 34, 34), "sienna": (160, 82, 45),
        "darkgreen": (0, 100, 0), "darkblue": (0, 0, 139), "darkred": (139, 0, 0), "darkorange": (255, 140, 0),
        "lightblue": (173, 216, 230), "lightgreen": (144, 238, 144), "lightyellow": (255, 255, 224),
        "skyblue": (135, 206, 235), "steelblue": (70, 130, 180), "royalblue": (65, 105, 225),
        "midnightblue": (25, 25, 112), "forestgreen": (34, 139, 34), "seagreen": (46, 139, 87),
        "springgreen": (0, 255, 127), "limegreen": (50, 205, 50), "chartreuse": (127, 255, 0),
        "aquamarine": (127, 255, 212), "goldenrod": (218, 165, 32), "hotpink": (255, 105, 180),
        "deeppink": (255, 20, 147), "orangered": (255, 69, 0),
    ]
}

public enum ConkyNode: Equatable, Sendable {
    case text(String)
    case newline
    case object(name: String, argument: String)
}

/// Splits `conky.text` into text, line breaks and `$name` / `${name args}` objects.
/// Grammar from core.cc: `$$` is a literal `$`; braces nest (so `${if_match ${cpu} > 5}` and awk's
/// `'{print $2}'` survive); a stray `}` is text; names are lower-cased; a backslash before a
/// newline joins lines; a bare `#` starts a comment (`\#` is a literal `#`). Environment
/// variables are not expanded.
public enum ConkyTextParser {
    public static func parse(_ text: String, comments: Bool = true) -> [ConkyNode] {
        let characters = Array(text.replacingOccurrences(of: "\\\n", with: ""))
        var nodes: [ConkyNode] = []
        var buffer = ""
        func flush() { if !buffer.isEmpty { nodes.append(.text(buffer)); buffer = "" } }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\n":
                flush(); nodes.append(.newline); index += 1
            case "\\" where comments && index + 1 < characters.count && characters[index + 1] == "#":
                buffer.append("#"); index += 2
            case "#" where comments:
                while index < characters.count && characters[index] != "\n" { index += 1 }
                index += 1 // the comment's newline goes with it
            case "$":
                guard index + 1 < characters.count else { buffer.append("$"); index += 1; continue }
                let next = characters[index + 1]
                if next == "$" {
                    buffer.append("$"); index += 2
                } else if next == "{" {
                    var depth = 1, end = index + 2
                    while end < characters.count && depth > 0 {
                        if characters[end] == "{" { depth += 1 } else if characters[end] == "}" { depth -= 1 }
                        end += 1
                    }
                    guard depth == 0 else { buffer += String(characters[index...]); index = characters.count; continue }
                    flush()
                    nodes.append(object(String(characters[(index + 2)..<(end - 1)])))
                    index = end
                } else if next.isASCII && (next.isLetter || next.isNumber || next == "_") {
                    var end = index + 1
                    while end < characters.count, characters[end].isASCII, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { end += 1 }
                    flush()
                    nodes.append(.object(name: String(characters[(index + 1)..<end]).lowercased(), argument: ""))
                    index = end
                } else {
                    buffer.append("$"); index += 1
                }
            default:
                buffer.append(character); index += 1
            }
        }
        flush()
        return nodes
    }

    private static func object(_ body: String) -> ConkyNode {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        let name = String(trimmed.prefix { !$0.isWhitespace })
        return .object(name: name.lowercased(), argument: trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespaces))
    }
}

public struct ConkyStyle: Sendable, Equatable {
    public var color: ConkyColor
    /// The raw `${font ...}` specification; nil selects the `font` setting.
    public var font: String?
}

/// One laid-out piece of a line. Positions are resolved by the renderer, which owns font metrics.
public struct ConkyItem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text(String)
        case goto(Double)
        case offset(Double)
        case voffset(Double)
        case alignRight(Double)
        case alignCenter(Double)
        case tab(width: Double, start: Double)
        /// `${hr}` and `${stippled_hr}`; width 0 fills the line, `stipple` is the gap length.
        case rule(height: Double, width: Double, stipple: Double?)
        /// Width 0 fills the rest of the line.
        case bar(fraction: Double, height: Double, width: Double)
        /// Graphs are not drawn yet; the space is reserved.
        case graph(height: Double, width: Double)
    }
    public var kind: Kind
    public var style: ConkyStyle
}

public typealias ConkyLine = [ConkyItem]

public enum ConkyText {
    /// Names that only position or style text; they print nothing in `conky_parse`.
    static func isLayoutObject(_ name: String) -> Bool {
        layoutNames.contains(name) || name.hasPrefix("color") || name.hasPrefix("#") || name.hasSuffix("bar") || name.hasSuffix("graph")
            || name.hasPrefix("if_") || name == "else" || name == "endif"
    }
    private static let layoutNames: Set<String> = ["font", "goto", "offset", "voffset", "alignr", "alignc", "tab", "hr", "stippled_hr"]

    /// Commands that run programs or touch files and are never executed (themes are untrusted).
    public static let blockedCommands: Set<String> = [
        "exec", "execi", "execp", "execpi", "execbar", "execibar", "execgauge", "execigauge", "execgraph", "execigraph",
        "texeci", "texecpi", "lua", "lua_parse", "lua_bar", "lua_gauge", "lua_graph", "include", "eval", "cat", "head", "tail",
        "catp", "curl", "rss", "weather", "read_tcp", "read_udp", "image", "stdin", "pre_exec", "if_existing", "if_running",
    ]

    /// Lays `nodes` out as lines of items. Conditionals (`if_match`, `if_up`, `else`, `endif`) are
    /// resolved here; `report` gets every object that is unknown, unsupported or blocked.
    public static func lines(_ nodes: [ConkyNode], values: ConkyValues, settings: ConkySettings,
                             report: (String) -> Void = { _ in }) -> [ConkyLine] {
        let fallback = ConkyColor.parse(settings.defaultColor) ?? ConkyColor(red: 1, green: 1, blue: 1)
        func color(_ specification: String) -> ConkyColor { ConkyColor.parse(specification) ?? fallback }
        var style = ConkyStyle(color: fallback, font: nil)
        var lines: [ConkyLine] = []
        var line: ConkyLine = []
        struct Branch { var parentActive: Bool; var condition: Bool; var inElse = false }
        var branches: [Branch] = []
        var active: Bool { branches.last.map { $0.parentActive && ($0.inElse ? !$0.condition : $0.condition) } ?? true }

        func add(_ kind: ConkyItem.Kind) { line.append(ConkyItem(kind: kind, style: style)) }
        func number(_ text: String?) -> Double? { text.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
        /// `H,W`, `H` or `,W` anywhere among the arguments; the rest are names (cpu0, mount points).
        func size(_ tokens: [String]) -> (height: Double?, width: Double?, rest: [String]) {
            var height: Double?, width: Double?, rest: [String] = []
            for token in tokens {
                let parts = token.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                if parts.count <= 2, !token.isEmpty, parts.allSatisfy({ $0.isEmpty || number($0) != nil }), token.first != "/" {
                    if parts.count == 1 { height = number(parts[0]) } else { height = number(parts[0]); width = number(parts[1]) }
                } else { rest.append(token) }
            }
            return (height, width, rest)
        }

        for node in nodes {
            switch node {
            case .newline:
                if active { lines.append(line); line = [] }
            case .text(let text):
                guard active else { continue }
                let shown = settings.uppercase ? text.uppercased() : text
                if case .text(let previous)? = line.last?.kind, line.last?.style == style {
                    line[line.count - 1].kind = .text(previous + shown)
                } else { add(.text(shown)) }
            case .object(let name, let argument):
                let tokens = argument.split(whereSeparator: \.isWhitespace).map(String.init)
                switch name {
                case "if_match", "if_up", "if_existing", "if_running":
                    let parent = active
                    branches.append(Branch(parentActive: parent, condition: parent && evaluateCondition(name, argument, values, settings, report)))
                    continue
                case "else": if !branches.isEmpty { branches[branches.count - 1].inElse = true }; continue
                case "endif": if !branches.isEmpty { branches.removeLast() }; continue
                default: break
                }
                guard active else { continue }
                switch name {
                case "color": style.color = argument.isEmpty ? fallback : color(argument)
                case _ where name.hasPrefix("#"): style.color = color(name)
                case _ where name.hasPrefix("color") && name.count == 6 && name.last?.isNumber == true:
                    let slot = Int(String(name.last!)) ?? 0
                    style.color = settings.colors[slot].map(color) ?? fallback
                case "font": style.font = argument.isEmpty ? nil : argument
                case "goto": if let x = number(tokens.first), x >= 0 { add(.goto(x)) }
                case "offset": add(.offset(number(tokens.first) ?? 1))
                case "voffset": add(.voffset(number(tokens.first) ?? 0))
                case "alignr": add(.alignRight(number(tokens.first) ?? 1))
                case "alignc": add(.alignCenter(number(tokens.first) ?? 0))
                case "tab":
                    let values = tokens.compactMap { number($0) }
                    add(values.count >= 2 ? .tab(width: max(1, values[0]), start: values[1]) : .tab(width: 10, start: values.first ?? 10))
                case "hr":
                    let values = tokens.compactMap { number($0) }
                    add(.rule(height: max(1, values.first ?? 1), width: values.count > 1 ? values[1] : 0, stipple: nil))
                case "stippled_hr":
                    let values = tokens.compactMap { number($0) }
                    add(.rule(height: max(1, values.count > 1 ? values[1] : 1), width: values.count > 2 ? values[2] : 0,
                              stipple: max(1, values.first ?? 1)))
                case "cpubar", "membar", "swapbar", "fs_bar", "battery_bar":
                    let parsed = size(tokens)
                    let fraction: Double?
                    switch name {
                    case "cpubar":
                        let core = parsed.rest.first.flatMap { $0.hasPrefix("cpu") ? Int($0.dropFirst(3)) : nil } ?? 0
                        fraction = core > 0 ? values.cores.flatMap { core <= $0.count ? $0[core - 1] : nil } ?? values.cpu : values.cpu
                    case "membar": fraction = values.memory
                    case "swapbar": fraction = values.swapBytes.map { $0.total > 0 ? $0.used / $0.total : 0 }
                    case "fs_bar": fraction = values.storage
                    default: fraction = values.battery
                    }
                    add(.bar(fraction: min(1, max(0, fraction ?? 0)), height: parsed.height ?? settings.defaultBarHeight, width: parsed.width ?? 0))
                case _ where name.hasSuffix("graph") && !blockedCommands.contains(name):
                    let parsed = size(tokens)
                    add(.graph(height: parsed.height ?? settings.defaultGraphHeight, width: parsed.width ?? 0))
                    report("\(name) (graphs are not drawn yet)")
                default:
                    if let value = ConkyVariables.value(name, argument, values, settings) {
                        let shown = settings.uppercase ? value.uppercased() : value
                        if case .text(let previous)? = line.last?.kind, line.last?.style == style {
                            line[line.count - 1].kind = .text(previous + shown)
                        } else if !shown.isEmpty { add(.text(shown)) }
                    } else {
                        report(blockedCommands.contains(name) ? "\(name) (commands and file access are not run)" : (argument.isEmpty ? name : "\(name) \(argument)"))
                    }
                }
            }
        }
        // n newlines make n lines; a trailing newline adds no empty line.
        if !line.isEmpty || lines.isEmpty { lines.append(line) }
        return lines
    }

    private static func evaluateCondition(_ name: String, _ argument: String, _ values: ConkyValues,
                                          _ settings: ConkySettings, _ report: (String) -> Void) -> Bool {
        switch name {
        case "if_up": return values.network != nil
        case "if_match":
            let expression = ConkyTemplate.evaluate(argument, values: values, settings: settings)
            for symbol in ["<=", ">=", "==", "!=", "<", ">", "="] {
                guard let range = expression.range(of: symbol) else { continue }
                let left = expression[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = expression[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let order: Int
                if let a = Double(left), let b = Double(right) { order = a < b ? -1 : (a > b ? 1 : 0) }
                else { order = left < right ? -1 : (left > right ? 1 : 0) }
                switch symbol {
                case "<": return order < 0
                case ">": return order > 0
                case "<=": return order <= 0
                case ">=": return order >= 0
                case "!=": return order != 0
                default: return order == 0
                }
            }
            report("if_match \(argument) (no comparison operator)")
            return false
        default:
            report("\(name) (file and process checks are not run)")
            return false
        }
    }
}

/// A Conky `font` / `${font ...}` value: a fontconfig pattern such as `Roboto Mono:size=7:bold`,
/// `DejaVu Sans-9` or an X11 fixed font like `6x10`. Sizes in points become pixels the way Xft
/// does at 96 dpi (7 pt = 9.3 px); `pixelsize=` is taken as is.
public struct ConkyFontSpec: Equatable, Sendable {
    public var family: String
    public var pixelSize: Double
    public var bold = false
    public var italic = false

    public init(_ specification: String, defaultPoints: Double = 12) {
        let parts = specification.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var head = parts.first ?? ""
        var points: Double? = defaultPoints
        var pixels: Double?
        var fixedFamily: String?
        let fixed = head.split(separator: "x").compactMap { Int($0) }
        if fixed.count == 2, head.allSatisfy({ $0.isNumber || $0 == "x" }) {
            // X11 bitmap fonts (6x10 is Conky's default): a monospace face with that cell height.
            fixedFamily = "monospace"; pixels = Double(fixed[1]); points = nil
        } else if let dash = head.lastIndex(of: "-"), let size = Double(head[head.index(after: dash)...]) {
            points = size; head = String(head[..<dash])
        }
        family = fixedFamily ?? (head.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
        for property in parts.dropFirst() {
            let pair = property.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            // "Mono::bold" and "Mono:=x" have empty properties: no key, nothing to apply.
            guard let key = pair.first, !key.isEmpty else { continue }
            switch (key, pair.count > 1 ? pair[1] : nil) {
            case ("bold", nil): bold = true
            case ("italic", nil), ("oblique", nil): italic = true
            case ("size", let value?): points = Double(value) ?? points; pixels = nil
            case ("pixelsize", let value?): pixels = Double(value); points = nil
            case ("weight", let value?): bold = ["bold", "demibold", "semibold", "extrabold", "black", "heavy", "200", "180", "210"].contains(value)
            case ("slant", let value?): italic = ["italic", "oblique", "100", "110"].contains(value)
            case ("style", let value?): bold = value.contains("bold"); italic = value.contains("italic") || value.contains("oblique")
            default: break
            }
        }
        let size = pixels ?? (points ?? defaultPoints) * 96 / 72
        pixelSize = size.isFinite ? min(200, max(1, size)) : defaultPoints * 96 / 72
    }
}
