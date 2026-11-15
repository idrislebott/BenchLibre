import Foundation

/// A bounded linear chart transform which stays finite even for hostile JSON values.
public enum ChartSeries {
    public static func normalized(_ values: [Double]) -> [Double] {
        let clean = values.prefix(ReportLimits.samplesPerPass).filter { $0.isFinite && $0 > 0 }
        guard clean.count > 1, let scale = clean.max() else { return [] }
        let scaled = clean.map { $0 / scale }
        guard let low = scaled.min(), let high = scaled.max() else { return [] }
        let spread = max(high - low, 0.12)
        let lower = (low + high - spread) * 0.5
        return scaled.map { min(1, max(0, 0.12 + 0.76 * ($0 - lower) / spread)) }
    }
}
