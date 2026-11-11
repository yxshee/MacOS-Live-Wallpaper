import XCTest
@testable import LiveWallpaper

final class FramePolicyTests: XCTestCase {
    func testShaderTimeIsFoldedBackWithoutReplayingTheStart() {
        XCTAssertEqual(ShaderScene.fold(0, limit: 3600), 0)
        XCTAssertEqual(ShaderScene.fold(3599.5, limit: 3600), 3599.5)
        XCTAssertEqual(ShaderScene.fold(3600, limit: 3600), 60)
        XCTAssertEqual(ShaderScene.fold(90_000, limit: 1800), 60 + (90_000 - 60).truncatingRemainder(dividingBy: 1740), accuracy: 1e-9)
        XCTAssertEqual(ShaderScene.fold(-5, limit: 3600), 0)
        XCTAssertEqual(ShaderScene.fold(.infinity, limit: 3600), 0)
        for t in stride(from: 0.0, through: 400_000, by: 977.3) {
            let folded = ShaderScene.fold(t, limit: ShaderScene.timeLimit)
            XCTAssertTrue(folded >= 0 && folded < ShaderScene.timeLimit, "\(t) -> \(folded)")
            if t >= ShaderScene.timeLimit { XCTAssertGreaterThanOrEqual(folded, ShaderScene.timeBase) }
        }
    }

    typealias C = FramePolicy.Conditions

    func testQuietPicturesCostLessThanBusyOnes() {
        for c in [C(), C(onBattery: true), C(desktopInFront: true), C(onBattery: true, desktopInFront: true)] {
            let still = FramePolicy.rate(c, hint: .still), slow = FramePolicy.rate(c, hint: .slow)
            let lively = FramePolicy.rate(c, hint: .lively), moving = FramePolicy.rate(c, hint: .moving)
            XCTAssertEqual(still, 1)
            XCTAssertLessThanOrEqual(still, slow)
            XCTAssertLessThanOrEqual(slow, lively)
            XCTAssertLessThanOrEqual(lively, moving)
        }
    }

    func testBatteryAndInattentionNeverRaiseTheRate() {
        for hint in [FramePolicy.Hint.still, .slow, .lively, .moving, .burst] {
            let front = FramePolicy.rate(C(desktopInFront: true), hint: hint)
            XCTAssertLessThanOrEqual(FramePolicy.rate(C(), hint: hint), front, "another app in front, \(hint)")
            XCTAssertLessThanOrEqual(FramePolicy.rate(C(onBattery: true, desktopInFront: true), hint: hint), front, "battery, \(hint)")
        }
    }

    func testSavingPowerCapsEverything() {
        for hint in [FramePolicy.Hint.still, .slow, .lively, .moving, .burst] {
            XCTAssertLessThanOrEqual(FramePolicy.rate(C(saving: true, desktopInFront: true), hint: hint), 5)
        }
        XCTAssertEqual(FramePolicy.rate(C(saving: true), hint: .still), 1)
    }

    func testASceneAskingForMoreThanTwentyGetsItOnlyWhenWatchedOnMainsPower() {
        XCTAssertEqual(FramePolicy.sceneRate(C(desktopInFront: true), maxFPS: 60), 60)
        XCTAssertEqual(FramePolicy.sceneRate(C(desktopInFront: true), maxFPS: 30), 30)
        XCTAssertEqual(FramePolicy.sceneRate(C(), maxFPS: 30), 15)
        XCTAssertEqual(FramePolicy.sceneRate(C(onBattery: true), maxFPS: 30), 9)
        XCTAssertEqual(FramePolicy.sceneRate(C(saving: true, desktopInFront: true), maxFPS: 60), 5)
        for cap in [Float(1), 5, 10, 15, 20] {
            for c in [C(), C(onBattery: true), C(desktopInFront: true), C(saving: true)] {
                XCTAssertEqual(FramePolicy.sceneRate(c, maxFPS: cap), FramePolicy.rate(c, hint: .lively, cap: cap))
            }
        }
        for cap in stride(from: Float(1), through: 60, by: 1) {
            let watched = FramePolicy.sceneRate(C(desktopInFront: true), maxFPS: cap)
            XCTAssertLessThanOrEqual(watched, cap)
            XCTAssertLessThanOrEqual(FramePolicy.sceneRate(C(), maxFPS: cap), watched)
            XCTAssertLessThanOrEqual(FramePolicy.sceneRate(C(onBattery: true, desktopInFront: true), maxFPS: cap), watched)
        }
    }

    func testASceneCanAskForLessButNeverLessThanOne() {
        XCTAssertEqual(FramePolicy.rate(C(desktopInFront: true), hint: .lively, cap: 12), 12)
        XCTAssertEqual(FramePolicy.rate(C(desktopInFront: true), hint: .lively, cap: 60), 20)
        XCTAssertEqual(FramePolicy.rate(C(), hint: .burst, cap: 0.2), 1)
    }
}

final class SceneRegistryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lw-scenes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeScene(_ id: String, json: String, shader: Bool = true) throws {
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json.write(to: folder.appendingPathComponent("scene.json"), atomically: true, encoding: .utf8)
        if shader { try "void mainImage(thread vec4& c, vec2 p) { c = vec4(1.0); }".write(
            to: folder.appendingPathComponent("main.metal"), atomically: true, encoding: .utf8) }
    }

    func testLoadsAValidSceneAndFillsDefaults() throws {
        try makeScene("blue-hour", json: #"{"title": "Blue Hour", "author": "A. Person", "licence": "CC0-1.0", "style": "cosy"}"#)
        let registry = SceneRegistry(folders: [root])
        let scene = try XCTUnwrap(registry.scene("blue-hour"))
        XCTAssertEqual(scene.title, "Blue Hour")
        XCTAssertEqual(scene.style, .cosy)
        XCTAssertEqual(scene.maxFPS, 20)
        XCTAssertEqual(scene.scale, 0.5)
        XCTAssertFalse(scene.isNonCommercial)
        XCTAssertEqual(scene.credit, "Blue Hour by A. Person")
        XCTAssertTrue(registry.problems.isEmpty)
        XCTAssertEqual(registry.scenes(in: .cosy).map(\.id), ["blue-hour"])
    }

    func testBuiltinsAreAlwaysPresentAndCannotBeReplaced() throws {
        try makeScene("horizon", json: #"{"title": "Impostor", "licence": "MIT"}"#)
        let registry = SceneRegistry(folders: [root])
        XCTAssertEqual(registry.scene("horizon")?.title, "Horizon")
        XCTAssertNotNil(registry.scene("nebula"))
        XCTAssertEqual(registry.problems.count, 1)
    }

    func testRejectsScenesThatCouldNotBeShownOrCredited() throws {
        try makeScene("no-licence", json: #"{"title": "X", "licence": " "}"#)
        try makeScene("no-shader", json: #"{"title": "X", "licence": "MIT"}"#, shader: false)
        try makeScene("bad-json", json: "{ not json")
        try makeScene("escapes", json: #"{"title": "X", "licence": "MIT", "channels": ["../../secret.png"]}"#)
        try makeScene("too-many", json: #"{"title": "X", "licence": "MIT", "channels": ["a.png", "b.png", "c.png"]}"#)
        let registry = SceneRegistry(folders: [root])
        XCTAssertEqual(registry.scenes.count, SceneRegistry.builtins.count)
        XCTAssertEqual(registry.problems.count, 5)
    }

    func testNonCommercialLicencesAreFlagged() throws {
        try makeScene("sea", json: #"{"title": "Sea", "licence": "CC-BY-NC-SA-3.0"}"#)
        try makeScene("sky", json: #"{"title": "Sky", "licence": "CC-BY-4.0"}"#)
        let registry = SceneRegistry(folders: [root])
        XCTAssertEqual(registry.scene("sea")?.isNonCommercial, true)
        XCTAssertEqual(registry.scene("sky")?.isNonCommercial, false)
    }

    func testOutOfRangeSettingsAreClamped() throws {
        try makeScene("wild", json: #"{"title": "W", "licence": "MIT", "maxFPS": 1000, "scale": 50}"#)
        let scene = try XCTUnwrap(SceneRegistry(folders: [root]).scene("wild"))
        XCTAssertEqual(scene.maxFPS, 60)
        XCTAssertEqual(scene.scale, 2)
    }

    /// Every scene shipped in the repository must load, carry a licence file and a credit.
    func testEveryBundledSceneIsWellFormed() throws {
        let scenes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scenes")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: scenes.path), "no Scenes folder")
        let registry = SceneRegistry(folders: [scenes])
        XCTAssertEqual(registry.problems, [])
        for scene in registry.scenes where !SceneRegistry.reserved.contains(scene.id) {
            guard case .shader(let folder) = scene.source else { continue }
            let licence = (try? String(contentsOf: folder.appendingPathComponent("LICENSE"), encoding: .utf8)) ?? ""
            XCTAssertGreaterThan(licence.count, 80, "\(scene.id) has no LICENSE file")
            XCTAssertFalse(scene.author.isEmpty, "\(scene.id) names no author")
            XCTAssertTrue(scene.sourceURL.hasPrefix("https://"), "\(scene.id) has no source link")
            XCTAssertNotEqual(scene.style, .other, "\(scene.id) has no style")
        }
    }

    func testShaderUniformsMatchThePrelude() {
        // LWUniforms in ScenePrelude.metal: five float4, one int4, two float4, in this order.
        XCTAssertEqual(MemoryLayout<LWUniforms>.stride, 8 * 16)
        XCTAssertEqual(MemoryLayout<LWUniforms>.offset(of: \.resolution), 0)
        XCTAssertEqual(MemoryLayout<LWUniforms>.offset(of: \.time), 16)
        XCTAssertEqual(MemoryLayout<LWUniforms>.offset(of: \.date), 32)
        XCTAssertEqual(MemoryLayout<LWUniforms>.offset(of: \.sky), 48)
        XCTAssertEqual(MemoryLayout<LWUniforms>.offset(of: \.pointer), 64)
        XCTAssertEqual(MemoryLayout<LWUniforms>.offset(of: \.frame), 80)
        XCTAssertEqual(MemoryLayout<LWUniforms>.offset(of: \.channelRes0), 96)
        XCTAssertEqual(MemoryLayout<LWUniforms>.offset(of: \.channelRes1), 112)
        let prelude = try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/ScenePrelude.metal"), encoding: .utf8)
        let fields = ["resolution", "time", "date", "sky", "pointer", "frame", "channelRes"]
        var cursor = prelude?.range(of: "struct LWUniforms")?.upperBound
        XCTAssertNotNil(cursor, "ScenePrelude.metal no longer declares LWUniforms")
        for field in fields {
            guard let text = prelude, let from = cursor, let found = text.range(of: " \(field)", range: from..<text.endIndex) else {
                return XCTFail("LWUniforms in the prelude has no \(field) after the fields before it")
            }
            cursor = found.upperBound
        }
    }
}
