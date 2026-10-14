import Foundation

/// The unchecked boundary is limited to this class: all mutable state and
/// synchronous system calls belong exclusively to queue. No work inherits MainActor.
public final class SamplingService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ConkyMac.sampling", qos: .utility)
    private let interface: String?
    private var timer: DispatchSourceTimer?
    private var collector: SystemCollector?

    public init(interface: String? = nil) { self.interface = interface }

    public func start(deliver: @escaping @Sendable (Snapshot) -> Void) {
        queue.async { [self] in
            timer?.cancel()
            if collector == nil { collector = SystemCollector(interface: interface) }
            guard let activeCollector = collector else { return }
            activeCollector.resetBaselines()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
            source.setEventHandler { deliver(activeCollector.sample()) }
            timer = source
            source.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }
}
