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

    func testTheDefaultIsTheNativeEngine() {
        XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder"]), .native,
                       "the default is native: the user ran this engine on their own desktop and it " +
                           "works, which is the acceptance the phase asked for")
    }

    func testTheLegacyEngineIsStillSelectable() {
        defaults.set("legacy", forKey: "engine")
        XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder"]), .legacy)
        defaults.set("native", forKey: "engine")
        XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder", "-noborderEngine", "legacy"]), .legacy,
                       "the LLDB path stays selectable while it is in the app")
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

    func testAnUnrecognisedValueInTheDefaultsIsTheDefaultEngine() {
        for value in ["Native", "NATIVE", "nativ", "native engine", "", "lldb", "0", "1"] {
            defaults.set(value, forKey: "engine")
            XCTAssertEqual(EngineChoice.current(defaults: defaults, args: ["NoBorder"]), .native,
                           "'\(value)' is not a spelling of an engine, so it is not a choice: the " +
                               "answer is the engine the app ships with")
        }
    }

    func testAnUnrecognisedLaunchArgumentIsTheDefaultEngine() {
        for args in [["-noborderEngine", "Native"], ["-noborderEngine", "xcrun"], ["-noborderEngine"],
                     ["-noborderEngine", "legacy", "-noborderEngine", "Native"]] {
            var full = ["NoBorder"]
            full.append(contentsOf: args)
            XCTAssertEqual(EngineChoice.current(defaults: defaults, args: full), .native,
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
