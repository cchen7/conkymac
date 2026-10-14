import Foundation

public struct ProcessSample: Codable, Sendable, Equatable {
    public let pid: Int32
    public let name: String
    /// Share of one core, like top: may exceed 100.
    public let cpuPercent: Double
    public let memoryBytes: Double
}

public struct ProcessSummary: Sendable, Equatable {
    public let byCPU: [ProcessSample]
    public let byMemory: [ProcessSample]
    public let total: Int
    /// ps state R; includes ps itself, as Conky's running_processes would.
    public let running: Int
}

/// Top processes from the setuid /bin/ps. Unprivileged libproc reads fail with EPERM
/// for about a third of processes here, including WindowServer and other root daemons.
/// %cpu is ps's decaying average; memory is resident size.
enum ProcessTable {
    /// posix_spawn + waitpid: Foundation's Process.waitUntilExit spins a run loop on this queue.
    /// ps gets a fixed C locale (others print "0,0") and no inherited descriptors, and is
    /// killed if it does not finish within `timeout` so a stall cannot block the sampler.
    static func read(limit: Int, timeout: Double = 1.5) -> ProcessSummary? {
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else { return nil }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        let arguments = ["/bin/ps", "-A", "-o", "pid=,%cpu=,rss=,state=,comm="]
        var argv = arguments.map { strdup($0) } + [nil]
        var environment = [strdup("LC_ALL=C"), nil]
        defer { (argv + environment).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, arguments[0], &actions, &attributes, &argv, &environment)
        close(pipe[1])
        guard spawned == 0 else { close(pipe[0]); return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date(timeIntervalSinceNow: timeout)
        var complete = false
        while true {
            var descriptor = pollfd(fd: pipe[0], events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break } // timeout or poll failure
            let count = Darwin.read(pipe[0], &buffer, buffer.count)
            if count > 0 { data.append(buffer, count: count); continue }
            if count < 0 && errno == EINTR { continue }
            complete = count == 0
            break
        }
        // Close first so a ps blocked on a full pipe gets EPIPE instead of waiting forever.
        close(pipe[0])
        if !complete { kill(pid, SIGKILL) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        guard complete, status == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self), limit: limit)
    }

    static func parse(_ output: String, limit: Int) -> ProcessSummary {
        var samples: [ProcessSample] = []
        var running = 0
        for line in output.split(separator: "\n") {
            var rest = line[...]
            func field() -> Substring? {
                rest = rest.drop { $0 == " " }
                guard let end = rest.firstIndex(of: " ") else { return nil }
                defer { rest = rest[end...] }
                return rest[..<end]
            }
            guard let pid = field().flatMap({ Int32($0) }), let cpu = field().flatMap({ Double($0) }),
                  let rss = field().flatMap({ Double($0) }), let state = field() else { continue }
            let command = String(rest.drop { $0 == " " })
            guard !command.isEmpty else { continue }
            samples.append(ProcessSample(pid: pid, name: (command as NSString).lastPathComponent,
                                         cpuPercent: cpu, memoryBytes: rss * 1024))
            if state.hasPrefix("R") { running += 1 }
        }
        let byCPU = samples.sorted { ($0.cpuPercent, $0.memoryBytes, $1.pid) > ($1.cpuPercent, $1.memoryBytes, $0.pid) }
        let byMemory = samples.sorted { ($0.memoryBytes, $0.cpuPercent, $1.pid) > ($1.memoryBytes, $1.cpuPercent, $0.pid) }
        return ProcessSummary(byCPU: Array(byCPU.prefix(limit)), byMemory: Array(byMemory.prefix(limit)),
                              total: samples.count, running: running)
    }
}
