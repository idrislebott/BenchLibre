// SPDX-License-Identifier: MIT
import Foundation

/// A descriptive comparison with an earlier matching configuration, not an
/// absolute performance grade, a hardware identity check, or a significance test.
public enum PersonalComparison {
    /// OS, power and thermal observations may differ: callers must display
    /// those differences instead of silently attributing an observed change.
    public static func reference(for current: BenchmarkReport, in reports: [BenchmarkReport]) -> BenchmarkReport? {
        guard usableMetadata(current), current.results.allSatisfy(audited) else { return nil }
        let candidates = reports.filter { candidate in
            guard candidate.id != current.id, usableMetadata(candidate),
                  candidate.startedAt < current.startedAt,
                  candidate.endedAt <= current.startedAt,
                  candidate.formatVersion == current.formatVersion,
                  candidate.workloadVersion == current.workloadVersion,
                  sameHardware(candidate.hardware, current.hardware),
                  sameConfiguration(candidate.configuration, current.configuration),
                  Set(candidate.results.map(\.kind)) == Set(current.results.map(\.kind)) else { return false }
            return true
        }.sorted { left, right in
            if left.startedAt != right.startedAt { return left.startedAt > right.startedAt }
            return left.id.uuidString < right.id.uuidString
        }
        // Cheap metadata filtering and ordering precede any sample traversal.
        // Stop at the first audited candidate instead of validating all history.
        for candidate in candidates {
            let matches = current.results.allSatisfy { result in
                guard let previous = candidate.results.first(where: { $0.kind == result.kind }),
                      sameMetricMetadata(result, previous), audited(previous) else { return false }
                return change(current: result.value, reference: previous.value) != nil
            }
            if matches { return candidate }
        }
        return nil
    }

    /// Raw relative change. A negative latency change means less waiting;
    /// a positive throughput change means more work per second. No judgment
    /// about statistical significance or everyday application speed is implied.
    public static func percentChange(current: MetricResult, reference: MetricResult) -> Double? {
        guard sameMetricMetadata(current, reference),
              audited(current), audited(reference) else { return nil }
        return change(current: current.value, reference: reference.value)
    }

    /// Historical reports used Apple's localized OS description. Normalize only
    /// the known French build label, preserving every version/build character.
    /// Unknown descriptions remain exact comparisons; reports are not rewritten.
    public static func sameOperatingSystem(_ left: String, _ right: String) -> Bool {
        func normalized(_ value: String) -> String {
            let canonical = value.replacingOccurrences(of: "(assemblage ", with: "(Build ")
            var words = canonical.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard words.count >= 2, words[0] == "Version" else { return canonical }
            let numbers = words[1].split(separator: ".", omittingEmptySubsequences: false)
            if numbers.count == 3, numbers.last == "0",
               numbers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) {
                words[1] = numbers.dropLast().joined(separator: ".")
            }
            return words.joined(separator: " ")
        }
        return normalized(left) == normalized(right)
    }

    private static func change(current: Double, reference: Double) -> Double? {
        // Divide first to avoid overflowing a subtraction of very large inputs.
        // Reject underflow as well: two positive values must have a positive ratio.
        let ratio = current / reference
        guard ratio.isFinite, ratio > 0 else { return nil }
        let change = (ratio - 1) * 100
        return change.isFinite ? change : nil
    }

    private static func usableMetadata(_ report: BenchmarkReport) -> Bool {
        guard report.formatVersion == 2,
              !report.workloadVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              report.startedAt.timeIntervalSince1970.isFinite,
              report.endedAt.timeIntervalSince1970.isFinite,
              report.hardware.memoryBytes > 0, report.hardware.logicalCores > 0,
              !report.hardware.model.isEmpty, !report.hardware.chip.isEmpty,
              !report.hardware.gpu.isEmpty, !report.hardware.architecture.isEmpty,
              !report.results.isEmpty, report.results.count <= BenchmarkKind.allCases.count,
              Set(report.results.map(\.kind)).count == report.results.count,
              Set(report.results.map(\.kind)).isSubset(of: Set(report.configuration.enabled)) else { return false }
        do { try report.configuration.validate(); return true } catch { return false }
    }

    private static func audited(_ result: MetricResult) -> Bool {
        do { try BenchmarkRunner.validateResult(result, expected: result.kind); return true }
        catch { return false }
    }

    private static func sameMetricMetadata(_ left: MetricResult, _ right: MetricResult) -> Bool {
        left.kind == right.kind && left.unit == right.unit && left.workUnit == right.workUnit
            && left.timingSource == right.timingSource
    }

    private static func sameConfiguration(_ left: BenchmarkConfiguration, _ right: BenchmarkConfiguration) -> Bool {
        left.secondsPerTest == right.secondsPerTest && left.threads == right.threads
            && left.repetitions == right.repetitions && left.enabled == right.enabled
    }

    private static func sameHardware(_ left: HardwareSummary, _ right: HardwareSummary) -> Bool {
        left.model == right.model && left.chip == right.chip && left.gpu == right.gpu
            && left.memoryBytes == right.memoryBytes && left.logicalCores == right.logicalCores
            && left.architecture == right.architecture
    }
}
