// SPDX-License-Identifier: MIT
import Foundation
import Dispatch
import IOKit.ps

public struct ConditionSample: Codable, Sendable {
    public var elapsedSeconds: Double
    public var thermalState: String
    public var powerSource: String
    public var lowPowerMode: Bool

    public init(elapsedSeconds: Double, thermalState: String, powerSource: String, lowPowerMode: Bool) {
        self.elapsedSeconds = elapsedSeconds
        self.thermalState = thermalState
        self.powerSource = powerSource
        self.lowPowerMode = lowPowerMode
    }
}

/// A one-session, thread-safe record of conditions observed at the start,
/// approximately once per second, and at the end. Delayed or transient changes
/// between samples may be missed; this is not proof of an absence of throttling.
/// The first sample is retained if the bounded history needs to discard data.
public final class ConditionMonitor: @unchecked Sendable {
    public static let samplingIntervalSeconds = 1.0
    public static let maximumStoredSamples = 10_000

    struct Reading: Sendable {
        var thermalState: String
        var powerSource: String
        var lowPowerMode: Bool
    }

    private enum State { case idle, running, finished }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.benchlibre.conditions", qos: .utility)
    private let interval: TimeInterval
    private let limit: Int
    private let clock: @Sendable () -> UInt64
    private let read: @Sendable () -> Reading
    private let schedulesTimer: Bool
    private var state = State.idle
    private var startNanoseconds: UInt64 = 0
    private var samples: [ConditionSample] = []
    private var timer: DispatchSourceTimer?

    public convenience init() {
        self.init(interval: Self.samplingIntervalSeconds, maximumSamples: Self.maximumStoredSamples,
                  clock: { DispatchTime.now().uptimeNanoseconds }, read: { ConditionMonitor.systemReading() })
    }

    init(interval: TimeInterval, maximumSamples: Int, clock: @escaping @Sendable () -> UInt64,
         read: @escaping @Sendable () -> Reading, schedulesTimer: Bool = true) {
        precondition(interval.isFinite && interval > 0)
        precondition(maximumSamples >= 2)
        self.interval = interval
        self.limit = maximumSamples
        self.clock = clock
        self.read = read
        self.schedulesTimer = schedulesTimer
    }

    public var latest: ConditionSample? {
        lock.lock(); defer { lock.unlock() }
        return samples.last
    }

    /// Monotonic seconds in the same epoch as the observations. After finish(),
    /// the value remains fixed at the final observation's timestamp.
    public var elapsedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return state == .running ? elapsedLocked() : samples.last?.elapsedSeconds ?? 0
    }

    /// Repeated calls are harmless. A finished monitor is not restarted.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard state == .idle else { return }
        state = .running
        startNanoseconds = clock()
        appendLocked(elapsed: 0)
        guard schedulesTimer else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval,
                        leeway: .milliseconds(max(1, min(50, Int(interval * 100)))))
        source.setEventHandler { [weak self] in self?.sampleNow() }
        timer = source
        source.resume()
    }

    /// Returns a stable snapshot, including a final observation. A queued timer
    /// callback cannot append after the state has changed to finished.
    public func finish() -> [ConditionSample] {
        lock.lock()
        if state == .running {
            appendLocked(elapsed: elapsedLocked())
        }
        state = .finished
        let source = timer
        timer = nil
        let result = samples
        lock.unlock()
        source?.cancel()
        return result
    }

    // Used by the timer and deterministic tests; all state decisions are inside
    // the same lock as finish(), including the capture itself.
    func sampleNow() {
        lock.lock(); defer { lock.unlock() }
        guard state == .running else { return }
        appendLocked(elapsed: elapsedLocked())
    }

    private func elapsedLocked() -> Double {
        let instant = clock()
        let elapsed = instant >= startNanoseconds ? Double(instant - startNanoseconds) / 1_000_000_000 : 0
        return max(samples.last?.elapsedSeconds ?? 0, elapsed)
    }

    private func appendLocked(elapsed: Double) {
        let reading = read()
        let sample = ConditionSample(elapsedSeconds: elapsed, thermalState: reading.thermalState,
                                     powerSource: reading.powerSource, lowPowerMode: reading.lowPowerMode)
        if samples.count == limit { samples.remove(at: 1) }
        samples.append(sample)
    }

    private static func systemReading() -> Reading {
        let power: String
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() {
            let value = source as String
            power = value == "AC Power" ? "Secteur" : value == "Battery Power" ? "Batterie" : value
        } else {
            power = "Inconnue"
        }
        return Reading(thermalState: SystemInfo.thermalState, powerSource: power,
                       lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    deinit {
        timer?.cancel()
    }
}
