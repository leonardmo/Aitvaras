import Foundation
import Testing

@Suite struct DragonRuntimeAssetTests {
    @Test func bundledDragonHasBoundedGeometryAndOnlyLiveFacialControls() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/AitvarasDragonRuntime.glb"))
        func word(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
        }
        #expect(word(0) == 0x46546c67)
        #expect(word(4) == 2)
        #expect(Int(word(8)) == data.count)
        #expect(data.count < 20 * 1024 * 1024)
        let length = Int(word(12))
        #expect(word(16) == 0x4e4f534a)
        let json = try #require(JSONSerialization.jsonObject(with: data.subdata(in: 20..<(20 + length))) as? [String: Any])
        #expect((json["animations"] as? [Any] ?? []).isEmpty)
        #expect((json["skins"] as? [Any] ?? []).isEmpty)
        let accessors = try #require(json["accessors"] as? [[String: Any]])
        let meshes = try #require(json["meshes"] as? [[String: Any]])
        var triangles = 0
        var names = Set<String>()
        for mesh in meshes {
            if let extras = mesh["extras"] as? [String: Any], let targets = extras["targetNames"] as? [String] {
                names.formUnion(targets)
            }
            for primitive in try #require(mesh["primitives"] as? [[String: Any]]) {
                let index = try #require(primitive["indices"] as? Int)
                triangles += try #require(accessors[index]["count"] as? Int) / 3
            }
        }
        #expect(triangles > 80_000 && triangles < 150_000)
        #expect(names == Set(["jawOpen", "eyeBlinkLeft", "eyeBlinkRight", "eyeLookLeft",
                              "eyeLookRight", "eyeLookUp", "eyeLookDown"]))
        let nodes = try #require(json["nodes"] as? [[String: Any]])
        #expect(nodes.contains { ($0["name"] as? String) == "Runtime.Dragon.Body" })
        #expect(!nodes.contains { $0["camera"] != nil || $0["skin"] != nil })
    }
}
