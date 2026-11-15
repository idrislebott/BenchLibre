// SPDX-License-Identifier: MIT
import Foundation

/// Dispersion between complete benchmark passes. These are not statistics of
/// the shorter, differently weighted samples collected inside one pass.
public struct MeasurementSummary: Codable, Sendable, Identifiable {
    public var kind: BenchmarkKind
    public var runCount: Int
    public var median: Double
    public var minimum: Double
    public var maximum: Double
    /// Sample standard deviation (variance denominator n−1), undefined for one pass.
    public var standardDeviation: Double?
    /// 100 × sample standard deviation / arithmetic mean.
    public var coefficientOfVariationPercent: Double?
    public var id: String { kind.rawValue }

    public init(kind: BenchmarkKind, runCount: Int, median: Double, minimum: Double,
                maximum: Double, standardDeviation: Double?, coefficientOfVariationPercent: Double?) {
        self.kind = kind
        self.runCount = runCount
        self.median = median
        self.minimum = minimum
        self.maximum = maximum
        self.standardDeviation = standardDeviation
        self.coefficientOfVariationPercent = coefficientOfVariationPercent
    }
}

public enum MeasurementStatistics {
    public static func summarize(kind: BenchmarkKind, values: [Double]) throws -> MeasurementSummary {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BenchmarkFailure.validationFailed("Les passages doivent contenir des mesures finies et strictement positives.")
        }
        let sorted = values.sorted()
        let count = sorted.count
        let midpoint = count / 2
        let median: Double
        if count.isMultiple(of: 2) {
            let lower = sorted[midpoint - 1]
            median = lower + (sorted[midpoint] - lower) / 2
        } else {
            median = sorted[midpoint]
        }

        var standardDeviation: Double?
        var variation: Double?
        if count > 1 {
            // Scaling before Welford's algorithm prevents squared deviations
            // from overflowing for large, but still finite, positive inputs.
            // A normalized CV also avoids division by a subnormal mean.
            let scale = sorted[count - 1]
            var mean = 0.0
            var m2 = 0.0
            for (index, value) in sorted.enumerated() {
                let normalized = value / scale
                let delta = normalized - mean
                mean += delta / Double(index + 1)
                m2 += delta * (normalized - mean)
            }
            let deviation = sqrt(max(0, m2 / Double(count - 1)))
            let scaledDeviation = deviation * scale
            let coefficient = deviation / mean * 100
            guard scaledDeviation.isFinite, coefficient.isFinite else {
                throw BenchmarkFailure.validationFailed("La dispersion des passages ne peut pas être représentée.")
            }
            standardDeviation = scaledDeviation
            variation = coefficient
        }

        return MeasurementSummary(kind: kind, runCount: count, median: median,
                                  minimum: sorted[0], maximum: sorted[count - 1],
                                  standardDeviation: standardDeviation,
                                  coefficientOfVariationPercent: variation)
    }
}
