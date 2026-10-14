import Foundation
import Testing
@testable import ConkyMacCore

private let values = ConkyValues(date: Date(timeIntervalSince1970: 1778077020), utc: true, cpu: 0.144, cores: [0.5, 0.25],
                                 memory: 0.359, storage: 0.4145, battery: 0.86, uptime: 29_321, updates: 7)

@Test func templateEvaluatesKnownVariables() {
    #expect(ConkyTemplate.evaluate("${time %H:%M:%S}", values: values) == "14:17:00")
    #expect(ConkyTemplate.evaluate("${time}", values: values) == "2026-05-06 14:17:00")
    #expect(ConkyTemplate.evaluate("${cpu}|${cpu cpu0}|${cpu cpu1}|${cpu cpu2}", values: values) == "14|14|50|25")
    #expect(ConkyTemplate.evaluate("${memperc} ${fs_used_perc /} ${fs_used_perc} ${battery_percent BAT0}", values: values) == "36 41 41 86")
    #expect(ConkyTemplate.evaluate("${updates} ${uptime}", values: values) == "7 8h 8m 41s")
    #expect(ConkyTemplate.evaluate("CPU $cpu% $$5", values: values) == "CPU 14% $5")
}

@Test func templateFallsBackWhenDataIsMissing() {
    var partial = ConkyValues(date: values.date, utc: true, cpu: 0.3, uptime: 3 * 86400 + 3700)
    #expect(ConkyTemplate.evaluate("${cpu cpu3}", values: partial) == "30")
    partial.cores = [0.1]
    #expect(ConkyTemplate.evaluate("${cpu cpu1} ${cpu cpu2}", values: partial) == "10 30")
    #expect(ConkyTemplate.evaluate("${memperc}/${battery_percent}/${uptime}", values: partial) == "0/0/3d 1h 1m")
    #expect(ConkyTemplate.evaluate("${memperc}${uptime}", values: ConkyValues(date: values.date)) == "0")
}

@Test func templateReportsUnknownVariables() {
    var reported: [String] = []
    let result = ConkyTemplate.evaluate("a ${nope 1} b ${fs_used_perc /home} c $missing ${broken", values: values) { reported.append($0) }
    #expect(result == "a  b  c  ${broken")
    #expect(reported == ["nope 1", "fs_used_perc /home", "missing"])
    #expect(ConkyTemplate.evaluate("plain text", values: values) == "plain text")
    #expect(ConkyTemplate.evaluate("end $", values: values) == "end $")
}
