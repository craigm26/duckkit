#if canImport(RealityKit)
import RealityKit
import Foundation
import simd
import DuckKit
import DuckVisual
#if canImport(UIKit)
import UIKit
#endif

/// The Microduck, drawn with its own geometry and posed by its own kinematics.
///
/// SHARED BY EVERY AR SCREEN ON PURPOSE. The ghost, the soccer pitch and
/// anything later all need the same duck; a second copy would be a second place
/// for the coordinate conversion to be got wrong, and that error looks like a
/// duck lying on its side rather than like a bug.
///
/// The meshes come from `DuckVisual` — Pollen's own parts under Apache-2.0, one
/// mesh per body in that body's local frame. So this holds no skeleton of its
/// own: it asks `DuckKinematics.bodyPoses(jointAngles:)` where each body is and
/// puts that body's mesh there. The thing that decides where a foot goes is
/// still the only thing that decides it.
@MainActor
public final class DuckGhostEntity: Entity {

    private var parts: [String: ModelEntity] = [:]
    /// Which feet this ghost wears; fixed at creation, like the robot's.
    public let variant: DuckKinematics.Variant
    /// Loaded once per process and variant. Decoding is a few megabytes of
    /// triangles and there is no reason two screens should each pay for it.
    private static var cached: [DuckKinematics.Variant: [DuckMesh.Body]] = [:]

    public required init() {
        self.variant = .legs
        super.init()
        build()
    }

    /// A ghost on rollers or legs.
    public init(variant: DuckKinematics.Variant) {
        self.variant = variant
        super.init()
        build()
    }

    private func build() {
        let bodies = Self.geometry(variant)

        for body in bodies {
            guard let mesh = Self.meshResource(for: body) else { continue }
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: .init(red: CGFloat(body.rgba.r),
                                                   green: CGFloat(body.rgba.g),
                                                   blue: CGFloat(body.rgba.b),
                                                   alpha: 1))
            // The real robot is matte printed plastic with metal fasteners.
            // Fully rough and non-metallic reads closer than RealityKit's
            // default shine, which makes every part look wet.
            material.roughness = 0.85
            material.metallic = 0.0
            let entity = ModelEntity(mesh: mesh, materials: [material])
            addChild(entity)
            parts[body.name] = entity
        }

        // NO FLOOR MEASUREMENT HERE ANY MORE. This used to compute a
        // `floorDrop` "so the anchor can be the floor", and the frame it
        // measured in was already the floor: `bodyPoses` puts `trunk_base` at
        // 0.12 m in the MODEL's world, so the entity origin IS ground level and
        // the home pose's lowest vertex is +2.3 mm. The function also seeded
        // its minimum at zero and only ever took `min`, so it returned −0.0 for
        // every input, and nothing read it. Feeding a repaired version back
        // into placement would have re-floated the robot by 117.7 mm.
        // `DuckVisual.DuckGroundClearance` is the honest per-frame answer.
        apply(jointAngles: DuckModel.homePose)
    }

    @MainActor public required init(from decoder: Decoder) throws { fatalError("not decodable") }

    /// Put the robot where a recording says it was.
    ///
    /// THE ONE CALL SITE FOR AN OFFSET THAT IS EASY TO MISS AND OBVIOUS ONCE
    /// SHIPPED. This entity's children come from
    /// `DuckKinematics.bodyPoses(jointAngles:)`, which works in the MODEL's
    /// world frame — the floor — with `trunk_base` already 120 mm up. A
    /// recording's root, though, IS the trunk. Setting `position` straight from
    /// it therefore adds the trunk height twice and draws the robot floating by
    /// exactly 116 mm, which on a 250 mm machine looks like a hovercraft. Duck
    /// Studio shipped a build doing precisely that.
    ///
    /// So placement lives here, once, rather than at every screen that wants to
    /// draw a clip. `DuckKinematics.placement(forRoot:orientation:)` does the
    /// arithmetic and ROTATES the offset, which matters the moment the robot
    /// rolls: an unrotated subtraction would push an inverted duck through the
    /// floor exactly when it is most visible.
    public func place(root: DuckIntentClip.Root, jointAngles: [Double]) {
        apply(jointAngles: jointAngles)
        let quaternion = DuckQuaternion(w: root.quaternion.0, x: root.quaternion.1,
                                        y: root.quaternion.2, z: root.quaternion.3)
        let placement = DuckKinematics.placement(
            forRoot: DuckVector(root.x, root.y, root.z), orientation: quaternion)
        position = Self.rk(placement.position)
        orientation = Self.rk(placement.orientation)
    }

    /// Put every part where this set of joint angles says it is.
    ///
    /// LEAVES THE ENTITY ITSELF WHERE IT IS. This is the right call for a
    /// bench, which has no root to honour, and the wrong one for a recording —
    /// use `place(root:jointAngles:)` there.
    public func apply(jointAngles: [Double]) {
        apply(jointAngles: jointAngles, wheelSpin: 0)
    }

    /// Pose plus, on rollers, how far the wheels have rolled (radians,
    /// positive forward). Ignored on legs.
    public func apply(jointAngles: [Double], wheelSpin: Double) {
        let poses = DuckKinematics.bodyPoses(jointAngles: jointAngles, variant: variant,
                                             wheelSpin: wheelSpin)
        for (name, entity) in parts {
            guard let pose = poses[name] else { continue }
            entity.position = Self.rk(pose.position)
            entity.orientation = Self.rk(pose.orientation)
        }
    }

    // MARK: - geometry

    private static func geometry(_ variant: DuckKinematics.Variant) -> [DuckMesh.Body] {
        if let hit = cached[variant] { return hit }
        let loaded = (try? DuckMesh.bundled(variant: variant)) ?? []
        cached[variant] = loaded
        return loaded
    }

    private static func meshResource(for body: DuckMesh.Body) -> MeshResource? {
        var descriptor = MeshDescriptor(name: body.name)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(body.vertexCount)
        normals.reserveCapacity(body.vertexCount)
        for i in stride(from: 0, to: body.positions.count, by: 3) {
            // Straight into ARKit's frame here rather than at draw time: the
            // vertices are baked once and the per-frame path then only moves
            // transforms.
            positions.append(SIMD3<Float>(body.positions[i],
                                          body.positions[i + 2],
                                          -body.positions[i + 1]))
            normals.append(SIMD3<Float>(body.normals[i],
                                        body.normals[i + 2],
                                        -body.normals[i + 1]))
        }
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(body.indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    // MARK: - coordinates

    /// MuJoCo (Z up, X forward, Y left) into RealityKit (Y up, -Z forward).
    ///
    /// A rotation of -90° about X, so handedness is preserved and there is no
    /// mirroring to undo. One place, because getting it wrong is not a crash —
    /// it is a duck walking sideways on its side.
    public static func rk(_ v: DuckVector) -> SIMD3<Float> {
        SIMD3<Float>(Float(v.x), Float(v.z), Float(-v.y))
    }

    /// The same change of basis for an orientation. A rotation of angle θ about
    /// axis `a` is (cos θ/2, sin θ/2 · a); re-expressing it in a frame related
    /// by rotation R is the same angle about `R·a`, so the scalar part is
    /// untouched and the vector part takes exactly the swap above.
    public static func rk(_ q: DuckQuaternion) -> simd_quatf {
        simd_quatf(ix: Float(q.x), iy: Float(q.z), iz: Float(-q.y), r: Float(q.w))
    }
}
#endif
