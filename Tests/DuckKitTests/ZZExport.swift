import XCTest
@testable import DuckKit

/// Exports DuckKit's verified constants so the web simulator uses the same
/// numbers rather than a retyped copy of them.
final class ZZExport: XCTestCase {
    func testExport() throws {
        func arr(_ v: [Double]) -> String { "[" + v.map { String($0) }.joined(separator: ",") + "]" }
        var o = "{"
        o += "\"jointNames\":[" + DuckModel.jointNames.map { "\"\($0)\"" }.joined(separator: ",") + "],"
        o += "\"homePose\":" + arr(DuckModel.homePose) + ","
        o += "\"rangeLo\":" + arr(DuckModel.jointRanges.map(\.lower)) + ","
        o += "\"rangeHi\":" + arr(DuckModel.jointRanges.map(\.upper)) + ","
        o += "\"actionScale\":\(DuckModel.actionScale),"
        o += "\"mouthIndex\":\(DuckModel.mouthIndex),"
        o += "\"tickHz\":\(DuckModel.tickHz),"
        o += "\"standingThreshold\":\(DuckModel.standingThreshold),"
        o += "\"alphaHead\":\(DuckGait.Alphas.trained.head),"
        o += "\"alphaLegs\":\(DuckGait.Alphas.trained.legs)"
        o += "}"
        try o.write(to: URL(fileURLWithPath: "/home/craigm26/projects/duck-sounds/sim/duckkit-constants.json"),
                    atomically: true, encoding: .utf8)
        print("EXPORTED \(o.count) bytes")
    }
}
