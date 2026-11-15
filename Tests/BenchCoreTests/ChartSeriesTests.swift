import XCTest
@testable import BenchCore

final class ChartSeriesTests: XCTestCase {
    func testExtremePositiveSamplesProduceFiniteOrderedCoordinates() {
        let coordinates = ChartSeries.normalized([.leastNonzeroMagnitude, .leastNormalMagnitude,
                                                   1, .greatestFiniteMagnitude])
        XCTAssertEqual(coordinates.count, 4)
        XCTAssertTrue(coordinates.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertEqual(coordinates, coordinates.sorted())
        XCTAssertLessThan(coordinates[0], coordinates[3])
    }

    func testInvalidSamplesAreRemovedAndConstantSeriesStaysCentered() {
        XCTAssertEqual(ChartSeries.normalized([.nan, .infinity, -.infinity, 0, -1, 2, 4]).count, 2)
        XCTAssertTrue(ChartSeries.normalized([.nan, .infinity, 0, -1]).isEmpty)
        XCTAssertTrue(ChartSeries.normalized([1]).isEmpty)
        let constant = ChartSeries.normalized([.greatestFiniteMagnitude, .greatestFiniteMagnitude])
        XCTAssertEqual(constant.count, 2)
        for coordinate in constant { XCTAssertEqual(coordinate, 0.5, accuracy: 1e-12) }
    }

    func testInputLimitPreventsTailFromChangingChartScale() {
        let bounded = Array(repeating: 2.0, count: ReportLimits.samplesPerPass)
        let coordinates = ChartSeries.normalized(bounded + [.greatestFiniteMagnitude, .nan])
        XCTAssertEqual(coordinates.count, ReportLimits.samplesPerPass)
        XCTAssertEqual(coordinates, ChartSeries.normalized(bounded))
    }
}
