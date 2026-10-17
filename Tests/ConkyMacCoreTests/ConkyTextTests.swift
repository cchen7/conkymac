import Foundation
import Testing
@testable import ConkyMacCore

private let fixtureValues = ConkyValues(snapshot: .fixture, utc: true)
private let settings = ConkySettings()

private func lines(_ text: String, values: ConkyValues = fixtureValues, settings: ConkySettings = settings,
                   report: (String) -> Void = { _ in }) -> [ConkyLine] {
    ConkyText.lines(ConkyTextParser.parse(text), values: values, settings: settings, report: report)
}
private func kinds(_ line: ConkyLine) -> [ConkyItem.Kind] { line.map(\.kind) }

@Test func parserHandlesConkyGrammar() {
    #expect(ConkyTextParser.parse("a$$b ${Color Red} $alignr} $HOME") == [
        .text("a$b "), .object(name: "color", argument: "Red"), .text(" "), .object(name: "alignr", argument: ""),
        .text("} "), .object(name: "home", argument: ""),
    ])
    // Braces nest, so awk's braces inside an argument and nested variables survive.
    #expect(ConkyTextParser.parse("${exec awk '{print $2}'}|${if_match ${cpu} > 5}") == [
        .object(name: "exec", argument: "awk '{print $2}'"), .text("|"),
        .object(name: "if_match", argument: "${cpu} > 5"),
    ])
    #expect(ConkyTextParser.parse("one\ntwo") == [.text("one"), .newline, .text("two")])
    // Backslash-newline joins lines; # starts a comment (its newline goes too); \# is literal.
    #expect(ConkyTextParser.parse("a\\\nb # note\nc \\#d") == [.text("ab "), .text("c #d")] .joinedText)
    #expect(ConkyTextParser.parse("x ${broken") == [.text("x ${broken")])
    #expect(ConkyTextParser.parse("end $") == [.text("end $")])
    #expect(ConkyTextParser.parse("a # kept", comments: false) == [.text("a # kept")])
}

private extension Array where Element == ConkyNode {
    /// Merges adjacent text nodes so expectations do not depend on where buffers were flushed.
    var joinedText: [ConkyNode] {
        reduce(into: []) { result, node in
            if case .text(let new) = node, case .text(let old)? = result.last { result[result.count - 1] = .text(old + new) }
            else { result.append(node) }
        }
    }
}

@Test func colorsParseHexAndX11Names() {
    #expect(ConkyColor.parse("#ff8000") == ConkyColor(red: 1, green: 128.0 / 255, blue: 0))
    #expect(ConkyColor.parse("f80") == ConkyColor(red: 1, green: 136.0 / 255, blue: 0))
    // 4 and 8 digits put alpha first.
    #expect(ConkyColor.parse("#8f00")?.alpha == 136.0 / 255)
    #expect(ConkyColor.parse("80ff0000") == ConkyColor(red: 1, green: 0, blue: 0, alpha: 128.0 / 255))
    // X11 gray is 190, not CSS's 128, and X11 green is pure #00ff00.
    #expect(ConkyColor.parse("Gray") == ConkyColor(red: 190.0 / 255, green: 190.0 / 255, blue: 190.0 / 255))
    #expect(ConkyColor.parse("green")?.green == 1 && ConkyColor.parse("green")?.red == 0)
    #expect(ConkyColor.parse("not a colour") == nil && ConkyColor.parse("#12") == nil)
}

@Test func humanReadableMatchesConky() {
    #expect(ConkyFormat.humanReadable(0) == "0B" && ConkyFormat.humanReadable(512) == "512B" && ConkyFormat.humanReadable(999) == "999B")
    #expect(ConkyFormat.humanReadable(1500) == "1.46KiB")
    #expect(ConkyFormat.humanReadable(1000) == "0.98KiB")
    #expect(ConkyFormat.humanReadable(422_576_128) == "403MiB")
    #expect(ConkyFormat.humanReadable(25_100_000_000) == "23.4GiB")
    #expect(ConkyFormat.humanReadable(5.12 * 1024 * 1024) == "5.12MiB")
    #expect(ConkyFormat.humanReadable(1_048_000, short: true) == "1.00M") // 1_048_000 / 1024 = 1023.4 KiB, then / 1024
    #expect(ConkyFormat.humanReadable(422_576_128, short: true) == "403M")
    #expect(ConkyFormat.humanReadable(1500, enabled: false) == "1500")
    #expect(ConkyFormat.humanReadable(.nan) == "0B")
}

@Test func uptimeFormatsMatchConky() {
    #expect(ConkyFormat.uptime(3 * 86400 + 3700, short: false) == "3d 1h 1m")
    #expect(ConkyFormat.uptime(3 * 86400 + 3700, short: true) == "3d 1h")
    #expect(ConkyFormat.uptime(8 * 3600 + 8 * 60 + 41, short: false) == "8h 8m 41s")
    #expect(ConkyFormat.uptime(8 * 3600 + 8 * 60 + 41, short: true) == "8h 8m")
    #expect(ConkyFormat.uptime(125, short: true) == "2m 5s")
}

@Test func layoutTracksStyleAndSpecials() {
    var configured = ConkySettings(config: ["color1": "#1793d1", "default_color": "gray", "uppercase": "false"])
    configured.colors[2] = "red"
    let result = lines("${color1}${goto 35}OS : ${color}${font Mono:size=9}x${font} ${alignr}${voffset -10}$hr\n\n${cpubar cpu1 4,100}", settings: configured)
    #expect(result.count == 3)
    let first = result[0]
    #expect(kinds(first) == [.goto(35), .text("OS : "), .text("x"), .text(" "), .alignRight(1), .voffset(-10), .rule(height: 1, width: 0, stipple: nil)])
    #expect(first[0].style.color == ConkyColor.parse("#1793d1"))
    #expect(first[1].style.color == ConkyColor.parse("#1793d1") && first[1].style.font == nil)
    #expect(first[2].style.color == ConkyColor.parse("gray") && first[2].style.font == "Mono:size=9")
    #expect(first[3].style.font == nil)
    #expect(result[1].isEmpty) // a blank line keeps its height
    // cpu1 is the first core: fixture 0.31 -> bar fraction, 4,100 -> height 4, width 100.
    #expect(kinds(result[2]) == [.bar(fraction: 0.31, height: 4, width: 100)])
}

@Test func layoutResolvesConditionsAndTrailingNewlines() {
    let text = "${if_match ${cpu cpu0} > 50}hot${else}cool${endif}|${if_up en0}up${endif}|${if_match 1 < 2}a${if_match 5 == 6}b${else}c${endif}${endif}\n"
    let result = lines(text)
    #expect(result.count == 1) // the trailing newline adds no extra line
    #expect(kinds(result[0]) == [.text("cool|up|ac")])
    var idle = fixtureValues
    idle.network = nil
    #expect(kinds(lines("${if_up en0}up${else}down${endif}", values: idle)[0]) == [.text("down")])
    #expect(kinds(lines("${if_match abc == abc}same${endif}${if_match 2 >= 10}num${else}str${endif}")[0]) == [.text("samestr")])
}

@Test func commandsAndFilesAreNeverRun() {
    var reported: [String] = []
    let result = lines("a${exec echo pwned > /tmp/conkymac-should-not-exist}${execi 5 id}b${cat /etc/passwd}${lua x}${if_existing /etc/passwd}hidden${endif}c${nope 1}",
                       report: { reported.append($0) })
    #expect(kinds(result[0]) == [.text("abc")])
    #expect(!FileManager.default.fileExists(atPath: "/tmp/conkymac-should-not-exist"))
    #expect(reported.count == 6)
    #expect(reported.contains { $0.hasPrefix("exec ") } && reported.contains { $0.hasPrefix("nope 1") })
    // Environment variables are not expanded either.
    #expect(kinds(lines("[$HOME]")[0]) == [.text("[]")])
}

@Test func variablesFormatLikeConky() {
    func text(_ source: String, _ values: ConkyValues = fixtureValues, _ configured: ConkySettings = settings) -> String {
        ConkyTemplate.evaluate(source, values: values, settings: configured)
    }
    #expect(text("$mem/$memmax $memperc% $swap/$swapmax $swapperc%") == "23.0GiB/64.0GiB 36% 512MiB/2.00GiB 25%")
    #expect(text("${fs_used /}/${fs_size /} ${fs_used_perc /}%") == "412GiB/994GiB 41%")
    #expect(text("$kernel on $machine ($sysname) $nodename_short") == "23.0.0 on arm64 (Darwin) macbook")
    #expect(text("$loadavg|${loadavg 2}") == "1.25 1.41 1.51|1.41")
    #expect(text("$processes $running_processes $uptime_short") == "612 3 8h 8m")
    #expect(text("${downspeed en0} ${upspeed wlan0} ${totaldown} ${totalup}") == "287KiB 18.0KiB 487MiB 5.71MiB")
    // freq follows the core's cluster: cores 1-4 are E, the rest P.
    #expect(text("${freq 1} ${freq_g 1} ${freq 5} ${freq_g 5} ${freq_g 99}") == "2571 2.57 3610 3.61 3.61")
    #expect(text("$acpitemp") == "47")
    var short = ConkySettings(config: ["short_units": "true", "top_name_width": "10"])
    #expect(text("$mem", fixtureValues, short) == "23.0G")
    short.formatHumanReadable = false
    #expect(text("${totalup}", fixtureValues, short) == "5987369")
}

@Test func topColumnsFollowConky() {
    func text(_ source: String, _ configured: ConkySettings = settings) -> String {
        ConkyTemplate.evaluate(source, values: fixtureValues, settings: configured)
    }
    // name: left-aligned, padded or cut to top_name_width + 1 = 16.
    #expect(text("[${top name 1}]") == "[WindowServer    ]")
    #expect(text("[${top name 4}]") == "[Google Chrome He]")
    #expect(text("${top cpu 1}|${top pid 2}|${top_mem mem_res 1}|${top_mem name 2}") == " 12.40|   3735|1.40GiB|Xcode           ")
    #expect(text("[${top name 9}]") == "[                ]") // past the end of the list
    #expect(text("${top name 0}${top bogus 1}") == "")
    #expect(text("[${top name 1}]", ConkySettings(config: ["top_name_width": "4"])) == "[Windo]")
}

@Test func settingsReadConfigAndClamp() {
    let configured = ConkySettings(config: ["font": "Roboto Mono:size=7", "draw_shades": "false", "minimum_width": "220",
                                            "maximum_width": "99999", "top_name_width": "-3", "default_bar_height": "0", "draw_outline": "yes"])
    #expect(configured.font == "Roboto Mono:size=7" && !configured.drawShades && configured.drawOutline)
    #expect(configured.minimumWidth == 220 && configured.maximumWidth == 4096 && configured.topNameWidth == 0 && configured.defaultBarHeight == 1)
    #expect(ConkySettings().drawShades && ConkySettings().textInset == 5) // Conky's defaults: shades on, 3 + 1 + 1 margins
}
