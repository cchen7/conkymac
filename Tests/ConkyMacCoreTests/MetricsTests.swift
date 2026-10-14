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
        1   0.1  29120 /sbin/launchd
      407  13.1 627000 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
     3760   3.4 411000 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper (Renderer)
     3761   3.4 999999 /usr/libexec/tie
    garbage line
       12   0.0      0
    """
    let top = ProcessTable.parse(output, limit: 3)
    #expect(top.map(\.name) == ["WindowServer", "tie", "Google Chrome Helper (Renderer)"])
    #expect(top[0].pid == 407 && top[0].memoryBytes == 627000 * 1024)
    #expect(ProcessTable.parse("", limit: 5).isEmpty)
}
