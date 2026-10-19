import XCTest
@testable import NoBorderEngine

final class TrampolineTests: XCTestCase {
    /// Fixed addresses so generation is deterministic and the blob layout can be asserted.
    private static let addresses = AddressTable(msgSend: 0x1_8000_0000,
                                               selRegisterName: 0x1_8000_1000,
                                               nsAppGlobal: 0x1_8000_2000)

    private func blob(_ script: RemoteScript) -> [UInt8] { Trampoline.data(script, addresses: Self.addresses) }
    private func code(_ script: RemoteScript) -> [UInt32] { Trampoline.code(script, addresses: Self.addresses) }

    private func hasCString(_ haystack: [UInt8], _ text: String) -> Bool {
        let needle = Array(text.utf8) + [0]
        return hasSequence(haystack, needle)
    }

    private func hasLEValue(_ haystack: [UInt8], _ value: UInt64) -> Bool {
        var word = value
        var needle: [UInt8] = []
        for _ in 0..<8 { needle.append(UInt8(word & 0xff)); word >>= 8 }
        return hasSequence(haystack, needle)
    }

    private func hasSequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    private func hasLEValue(_ haystack: [UInt8], _ value: Double) -> Bool { hasLEValue(haystack, value.bitPattern) }

    private func indirectCallCount(_ code: [UInt32]) -> Int {
        code.filter { $0 == Arc64.blr(Trampoline.msgSendRegister) }.count
    }

    // MARK: the call script

    func testAppliedScriptCarriesAllThreeChanges() {
        let script = RemoteScript.applied(windowNumbers: [42])
        XCTAssertEqual(script.hasShadow, false)
        XCTAssertEqual(script.cornerRadius, 0.01)
        XCTAssertEqual(script.drawsDecoration, false)
        XCTAssertEqual(script.windowNumbers, [42])
    }

    func testRestoredScriptReversesAllThreeChanges() {
        let script = RemoteScript.restored(windowNumbers: [42])
        XCTAssertEqual(script.hasShadow, true)
        XCTAssertEqual(script.cornerRadius, 0.0)
        XCTAssertEqual(script.drawsDecoration, true)
    }

    // MARK: the generated call sequence

    func testAppliedWindowMakesOneIndirectCallPerStep() {
        // [NSApp windowWithWindowNumber:] + setHasShadow: + _setCornerRadius:
        //   + _titlebarContainerView + setDrawsDecorationView:
        XCTAssertEqual(indirectCallCount(code(RemoteScript.applied(windowNumbers: [7]))), 5)
        XCTAssertEqual(indirectCallCount(code(RemoteScript.applied(windowNumbers: [7, 8]))), 10)
    }

    func testCodeEndsAtTheBreakpointSentinel() {
        XCTAssertEqual(code(RemoteScript.applied(windowNumbers: [7])).last, Arc64.brk)
    }

    func testSkippedStepsMakeFewerCalls() {
        var script = RemoteScript.applied(windowNumbers: [7])
        script.cornerRadius = nil
        script.drawsDecoration = nil
        // window lookup + setHasShadow: only; the titlebar view is not looked up at all
        XCTAssertEqual(indirectCallCount(code(script)), 2)
    }

    // MARK: the data blob

    func testBlobCarriesEverySelectorTheCodeNeeds() {
        let data = blob(RemoteScript.applied(windowNumbers: [7]))
        for name in ["windowWithWindowNumber:", "setHasShadow:", "_setCornerRadius:",
                     "_titlebarContainerView", "setDrawsDecorationView:"] {
            XCTAssertTrue(hasCString(data, name), "missing selector name \(name)")
        }
    }

    func testBlobCarriesTheAppliedCornerRadius() {
        XCTAssertTrue(hasLEValue(blob(RemoteScript.applied(windowNumbers: [7])), 0.01))
    }

    func testBlobCarriesTheRestoredCornerRadiusZero() {
        XCTAssertTrue(hasLEValue(blob(RemoteScript.restored(windowNumbers: [7])), 0.0))
    }

    func testOmittedRadiusStepCarriesNoRadiusSelector() {
        var script = RemoteScript.applied(windowNumbers: [7])
        script.cornerRadius = nil
        XCTAssertFalse(hasCString(blob(script), "_setCornerRadius:"))
    }

    func testBlobCarriesTheRuntimeAddresses() {
        let data = blob(RemoteScript.applied(windowNumbers: [7]))
        for address: UInt64 in [0x1_8000_0000, 0x1_8000_1000, 0x1_8000_2000] {
            XCTAssertTrue(hasLEValue(data, address), "missing address 0x\(String(address, radix: 16))")
        }
    }

    // MARK: instruction encodings, cross-checked against the system assembler

    func testEncodingsMatchTheSystemAssembler() throws {
        let check = AssemblerCheck()
        guard check.available else { throw XCTSkip("no clang/otool for the assembler cross-check") }
        let hand = try check.bytes(forHand: [
            "adr x17, #0x40",
            "ldr x0, [x17, #8]",
            "ldr d0, [x17, #16]",
            "mov w2, #1",
            "mov x0, x19",
            "blr x16",
            "brk #0",
        ])
        let mine = try check.bytes(forWords: [
            Arc64.adr(dst: 17, immediate: 0x40),
            Arc64.ldr(dst: 0, base: 17, offset: 8),
            Arc64.ldrd(dst: 0, base: 17, offset: 16),
            Arc64.movz(dst: 2, value: 1),
            Arc64.movReg(dst: 0, src: 19),
            Arc64.blr(16),
            Arc64.brk,
        ])
        XCTAssertEqual(mine, hand)
    }

    func testTheAssemblerCrossCheckCanItselfFail() throws {
        let check = AssemblerCheck()
        guard check.available else { throw XCTSkip("no clang/otool for the assembler cross-check") }
        let hand = try check.bytes(forHand: ["brk #0"])
        let wrong = try check.bytes(forWords: [Arc64.brk &+ 1])
        XCTAssertNotEqual(wrong, hand)
    }
}
