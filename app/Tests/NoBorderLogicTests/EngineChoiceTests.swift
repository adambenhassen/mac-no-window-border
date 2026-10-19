import Foundation
import XCTest
@testable import NoBorderLogic

/// Which engine the app runs. The default is the legacy one, and stays it until the benchmark says
/// the native engine is faster: this is the switch the "keep both until it is beaten" instruction
/// needs, and the reason it is a launch argument and a `defaults` key rather than a menu item.
final class EngineChoiceTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "NoBorder.EngineChoiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
    }

    func testTheDefaultIsTheLegacyEngine() {
        XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder"]), .legacy)
    }

    func testTheLaunchArgumentSelectsTheNativeEngine() {
        XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder", "-noborderEngine", "native"]), .native)
    }

    func testTheLaunchArgumentIsAcceptedInTheFormTheSystemRegistersItIn() {
        // NSUserDefaults also records "-key value" launch arguments under the key itself.
        XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["/Applications/NoBorder.app/Contents/MacOS/NoBorder", "-noborderEngine=native"]), .native)
    }

    func testTheDefaultsKeySelectsTheNativeEngine() {
        defaults.set("native", forKey: "engine")
        XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder"]), .native)
    }

    func testTheLaunchArgumentWinsOverTheDefaultsKey() {
        defaults.set("native", forKey: "engine")
        XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder", "-noborderEngine", "legacy"]), .legacy)
        defaults.set("legacy", forKey: "engine")
        XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder", "-noborderEngine", "native"]), .native)
    }

    func testAnUnrecognisedValueInTheDefaultsIsTheLegacyEngine() {
        for value in ["Native", "NATIVE", "nativ", "native engine", "", "lldb", "0", "1"] {
            defaults.set(value, forKey: "engine")
            XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder"]), .legacy,
                           "'\(value)' is not a spelling of an engine; the safe answer is the one shipping today")
        }
    }

    func testAnUnrecognisedLaunchArgumentIsTheLegacyEngine() {
        for args in [["-noborderEngine", "Native"], ["-noborderEngine", "xcrun"], ["-noborderEngine"],
                     ["-noborderEngine", "native", "-noborderEngine", "legacy"]] {
            var full = ["NoBorder"]
            full.append(contentsOf: args)
            XCTAssertEqual(EngineChoice.current(defaults: defaults, args: full), .legacy,
                           "\(args) says nothing usable")
        }
    }

    func testTheNamesAreTheSpellingTheSwitchAccepts() {
        defaults.set(EngineChoice.native.rawValue, forKey: "engine")
        XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder"]), .native)
        defaults.set(EngineChoice.legacy.rawValue, forKey: "engine")
        XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder"]), .legacy)
    }
}
