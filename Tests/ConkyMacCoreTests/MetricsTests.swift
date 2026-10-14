import Foundation
import Testing
@testable import ConkyMacCore

@Test func cpuUsesWholeMachineDelta() {
    let old = CPUTicks(user: 10, system: 10, idle: 80, nice: 0)
    let new = CPUTicks(user: 30, system: 20, idle: 150, nice: 0)
    #expect(new.fraction(since: old) == 0.3)
    #expect(new.fraction(since: new) == nil)
    #expect(old.fraction(since: new) == nil)
}

@Test func cpuHandlesTickWrap() {
    let old = CPUTicks(user: UInt32.max - 9, system: 0, idle: 100, nice: 0)
    let new = CPUTicks(user: 10, system: 0, idle: 180, nice: 0)
    #expect(new.fraction(since: old) == 0.2)
}

@Test func networkBaselinesAndMonotonicTime() {
    var tracker = NetworkTracker()
    #expect(tracker.update(.init(interface: "en0", received: 100, sent: 200, time: 10))?.downloadBytesPerSecond == nil)
    let next = tracker.update(.init(interface: "en0", received: 1100, sent: 600, time: 12))
    #expect(next?.downloadBytesPerSecond == 500)
    #expect(next?.uploadBytesPerSecond == 200)
    #expect(next?.sessionDownloadBytes == 1000)
    #expect(tracker.update(.init(interface: "en1", received: 9999, sent: 9999, time: 13))?.downloadBytesPerSecond == nil)
    #expect(tracker.update(.init(interface: "en1", received: 2, sent: 2, time: 14))?.downloadBytesPerSecond == nil)
    #expect(tracker.update(.init(interface: "en1", received: 100, sent: 100, time: 30))?.downloadBytesPerSecond == nil)
    #expect(tracker.update(nil) == nil)
    #expect(tracker.update(.init(interface: "en1", received: 200, sent: 200, time: 31))?.downloadBytesPerSecond == nil)
    #expect(tracker.update(.init(interface: "en1", received: 400, sent: 300, time: 32))?.sessionDownloadBytes == 1200)
    tracker.resetBaseline()
    let resumed = tracker.update(.init(interface: "en1", received: 900, sent: 800, time: 33))
    #expect(resumed?.downloadBytesPerSecond == nil)
    #expect(resumed?.sessionDownloadBytes == 1200)
}

@Test func networkHandles32BitCounterWrap() {
    var tracker = NetworkTracker()
    let top = UInt64(UInt32.max)
    _ = tracker.update(.init(interface: "en0", received: top - 1023, sent: 10, time: 1))
    let wrapped = tracker.update(.init(interface: "en0", received: 1024, sent: 20, time: 2))
    #expect(wrapped?.downloadBytesPerSecond == 2048)
    #expect(wrapped?.sessionDownloadBytes == 2048)
    // Huge backwards jumps and 64-bit regressions remain resets, not wraps.
    #expect(tracker.update(.init(interface: "en0", received: 0, sent: 0, time: 3))?.downloadBytesPerSecond == nil)
    _ = tracker.update(.init(interface: "en0", received: top / 4, sent: 0, time: 4))
    #expect(tracker.update(.init(interface: "en0", received: 5, sent: 0, time: 5))?.downloadBytesPerSecond == nil)
    // A reset from above 2 GiB looks like a wrap; the rate cap rejects it.
    _ = tracker.update(.init(interface: "en0", received: top - (3 << 29), sent: 0, time: 5.5))
    #expect(tracker.update(.init(interface: "en0", received: 0, sent: 0, time: 6))?.downloadBytesPerSecond == nil)
    #expect(tracker.update(.init(interface: "en0", received: 0, sent: 0, time: 6.5))?.downloadBytesPerSecond == 0)
    _ = tracker.update(.init(interface: "en0", received: top + 100, sent: 0, time: 7))
    #expect(tracker.update(.init(interface: "en0", received: top + 50, sent: 0, time: 7.5))?.downloadBytesPerSecond == nil)
}

@Test func historyKeepsGapsAndEvictsOldest() {
    var history = History(capacity: 3)
    history.append(0.1); history.append(nil); history.append(0.8); history.append(0.2)
    #expect(history.count == 3)
    #expect(history.values == [nil, 0.8, 0.2])
    for _ in 0..<10000 { history.append(0.5) }
    #expect(history.count == 3)
    #expect(history.values == [0.5, 0.5, 0.5])
}

@Test func processTableParsesAndRanks() {
    let output = """
        1   0.1  29120 Ss   /sbin/launchd
      407  13.1 627000 Rs   /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
     3760   3.4 411000 S    /Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper (Renderer)
     3761   3.4 999999 R+   /usr/libexec/tie
    garbage line
       12   0.0      0 S
    """
    let summary = ProcessTable.parse(output, limit: 3)
    #expect(summary.byCPU.map(\.name) == ["WindowServer", "tie", "Google Chrome Helper (Renderer)"])
    #expect(summary.byCPU[0].pid == 407 && summary.byCPU[0].memoryBytes == 627000 * 1024)
    #expect(summary.byMemory.map(\.name) == ["tie", "WindowServer", "Google Chrome Helper (Renderer)"])
    #expect(summary.total == 4 && summary.running == 2)
    #expect(ProcessTable.parse("", limit: 5).byCPU.isEmpty)
}

@Test func processTableKillsStalledPs() {
    // A zero budget expires before ps can finish: the child is killed and reaped, not trusted.
    #expect(ProcessTable.read(limit: 5, timeout: 0) == nil)
    #expect(ProcessTable.read(limit: 5)?.byCPU.isEmpty == false)
}

@Test func dvfsTableDecodesUnits() {
    func entries(_ values: [UInt32]) -> Data {
        Data(values.flatMap { value in withUnsafeBytes(of: value.littleEndian, Array.init) + [0x20, 0x03, 0, 0] })
    }
    // M4+: kHz, with a zero padding entry dropped.
    #expect(SensorMath.dvfsTable(entries([1_020_000, 2_592_000, 0])) == [1020, 2592])
    // M1-M3: Hz.
    #expect(SensorMath.dvfsTable(entries([600_000_000, 3_228_000_000])) == [600, 3228])
    #expect(SensorMath.dvfsTable(Data([1, 2, 3])).isEmpty)
    // An inner zero stays in place so later frequencies keep their state index.
    #expect(SensorMath.dvfsTable(entries([1_020_000, 0, 2_592_000, 0])) == [1020, 0, 2592])
}

@Test func clusterFrequencyWeightsActiveResidency() {
    let table: [Double] = [1000, 2000, 3000]
    let states: [(name: String, residency: Int64)] = [("DOWN", 50), ("IDLE", 900), ("V0P6", 10), ("V1P0", 0), ("V2P0", 30)]
    let result = SensorMath.cluster(states: states, table: table)
    #expect(result?.megahertz == 2500 && result?.active == 40)
    // A state list that no longer lines up with the table is rejected, not guessed.
    #expect(SensorMath.cluster(states: Array(states.dropLast()), table: table) == nil)
    let idle = SensorMath.cluster(states: [("IDLE", 1000), ("V0P6", 0), ("V1P0", 0), ("V2P0", 0)], table: table)
    #expect(idle?.active == 0)
    #expect(SensorMath.merge([(4000, 30), (1000, 10)]) == 3250)
    #expect(SensorMath.merge([(0, 0)]) == nil)
}

@Test func temperatureKeysAndHottest() {
    #expect(["Tpx8", "TpxD", "Tex0", "Tex3"].allSatisfy(SensorMath.isCPUTemperatureKey))
    #expect(!["Tp01", "Te05", "Tp1i", "Tp2X", "Tg1U"].contains(where: SensorMath.isCPUTemperatureKey))
    #expect(SensorMath.isGPUTemperatureKey("Tg1U") && !SensorMath.isGPUTemperatureKey("Tpx8"))
    #expect(SensorMath.hottest([40, 46.4, 43.1, -4, 130]) == 46.4)
    #expect(SensorMath.hottest([1.5, 0]) == nil)
}

@Test func clusterLoadAveragesByKind() {
    let kinds: [Int: Character] = [0: "E", 1: "E", 2: "P", 3: "P", 4: "P"]
    let load = ClusterLoad.from([0.2, 0.4, 0.1, 0.2, 0.3], kinds: kinds)
    #expect(abs((load?.efficiency ?? 0) - 0.3) < 1e-9 && abs((load?.performance ?? 0) - 0.2) < 1e-9)
    #expect(ClusterLoad.from([0.5], kinds: [:]) == nil)
}

@Test func hiddenPanelsPauseDisplayOnlySampling() {
    let collector = SystemCollector()
    collector.detailsWanted = false
    let hidden = collector.sample()
    #expect(hidden.processes == nil && hidden.temperatureCelsius == nil)
    #expect(!hidden.issues.contains { $0.hasPrefix("Processes") || $0.hasPrefix("Temperature") })
    #expect(hidden.memory != nil) // continuous metrics keep sampling
    collector.detailsWanted = true
    // Becoming visible refreshes immediately instead of waiting for the next 5 s slot.
    #expect(collector.sample().processes?.isEmpty == false)
}
