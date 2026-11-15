// SPDX-License-Identifier: MIT
import Foundation
import Dispatch

/// At most one pending phase update. Observer work never executes on an engine
/// measurement thread. The runner flushes only outside timed engine windows.
final class BenchmarkProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.benchlibre.progress", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let deliver: @Sendable (SuiteUpdate) -> Void
    private var pending: SuiteUpdate?
    private var scheduled = false

    init(deliver: @escaping @Sendable (SuiteUpdate) -> Void) {
        self.deliver = deliver
        queue.setSpecific(key: queueKey, value: true)
    }

    func enqueue(_ update: SuiteUpdate) {
        lock.lock()
        pending = update
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { queue.async { self.drain() } }
    }

    /// Call after producers have stopped, before a phase boundary. This waits
    /// for the observer closure itself, never for an asynchronously scheduled UI.
    func flush() {
        guard DispatchQueue.getSpecific(key: queueKey) == nil else { return }
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            deliver(next)
        }
    }
}
