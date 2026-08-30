import XCTest
@testable import DuckKit

final class ZZReachProbe: XCTestCase {
    func testMouthReachAndLever() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["DUCKKIT_PROBE"] == nil)
        let home = DuckModel.homePose
        let poses = DuckKinematics.bodyPoses(jointAngles: home)
        let sites = DuckKinematics.sitePositions(jointAngles: home)
        let mouth = sites["mouth_tip"]!
        let neck = poses["neck"]!.position          // the neck_pitch joint's body
        print("PROBE home mouth tip: (\(r(mouth.x)), \(r(mouth.y)), \(r(mouth.z)))")
        print("PROBE neck joint at:  (\(r(neck.x)), \(r(neck.y)), \(r(neck.z)))")
        let lever = ((mouth - neck).x * (mouth - neck).x
                   + (mouth - neck).z * (mouth - neck).z).squareRoot()
        print("PROBE neck->mouth lever (in the sagittal plane): \(r(lever)) m")
        print("PROBE straight-line neck->mouth: \(r((mouth - neck).length)) m")

        // How high the mouth is through a ground pick, so a grasp can be timed
        // at a height rather than only at the bottom.
        let clips = try DuckIntentClip.bundled()
        let clip = try XCTUnwrap(clips["ground_pick"])
        let rest = poses["trunk_base"]!.position
        var rows: [(Double, Double)] = []
        for (i, frame) in clip.frames.enumerated() {
            var angles = frame
            angles.insert(DuckModel.mouthTarget(open: 1), at: DuckModel.mouthIndex)
            let local = DuckKinematics.sitePositions(jointAngles: angles)["mouth_tip"]! - rest
            let root = clip.roots[i]
            let q = root.quaternion
            let world = DuckVector(root.x, root.y, root.z)
                + DuckQuaternion(w: q.0, x: q.1, y: q.2, z: q.3).rotate(local)
            rows.append((Double(i) / clip.hz, world.z))
        }
        print("PROBE mouth height over the pick, every 0.2 s:")
        for (t, z) in rows where (t * 5).rounded() == t * 5 {
            print("PROBE   t=\(r(t)) z=\(r(z))")
        }
        // Descending pass only: the first time it crosses each height.
        let lowest = rows.min { $0.1 < $1.1 }!
        for target in [0.20, 0.15, 0.12, 0.10, 0.08, 0.06, 0.04] where target > lowest.1 {
            if let hit = rows.first(where: { $0.0 <= lowest.0 && $0.1 <= target }) {
                print("PROBE crosses \(r(target)) m going down at t=\(r(hit.0))")
            }
        }
    }
    private func r(_ v: Double) -> String { String(format: "%.4f", v) }
}
