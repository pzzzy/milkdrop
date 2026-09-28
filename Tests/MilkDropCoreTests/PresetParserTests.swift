import Foundation
import XCTest
@testable import MilkDropCore

final class PresetParserTests: XCTestCase {
    func testParsesMilkDropScalarsAndShaderBlocks() throws {
        let source = """
        [preset00]
        fRating=4.500
        fDecay=0.970
        bTexWrap=1
        wavecode_0_enabled=1
        warp_1=`float3 ret = tex2D(sampler_main, uv).xyz;
        warp_2=`ret *= 1.2;
        comp_1=`return float4(ret, 1);
        """
        let preset = try MilkPreset.parse(source, name: "Test")
        XCTAssertEqual(preset.name, "Test")
        XCTAssertEqual(preset.rating, 4.5)
        XCTAssertEqual(preset.decay, 0.97)
        XCTAssertTrue(preset.wrap)
        XCTAssertEqual(preset.customWaves.first?.enabled, true)
        XCTAssertTrue(preset.warpShader.contains("tex2D"))
        XCTAssertTrue(preset.warpShader.contains("ret *= 1.2"))
        XCTAssertTrue(preset.compositeShader.contains("return float4"))
    }

    func testDefaultsMatchOriginalPresetSemantics() throws {
        let preset = try MilkPreset.parse("[preset00]\n", name: "Empty")
        XCTAssertEqual(preset.decay, 0.98)
        XCTAssertEqual(preset.zoom, 1.0)
        XCTAssertEqual(preset.gamma, 2.0)
        XCTAssertEqual(preset.customWaves.count, 4)
    }

    func testDiscoversMilkFilesRecursivelyAndSortsThem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "[preset00]".write(to: root.appendingPathComponent("z.milk"), atomically: true, encoding: .utf8)
        try "[preset00]".write(to: root.appendingPathComponent("nested/a.milk"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }
        let files = PresetLibrary.discover(in: root)
        XCTAssertEqual(files.map(\.lastPathComponent), ["a.milk", "z.milk"])
    }
}
