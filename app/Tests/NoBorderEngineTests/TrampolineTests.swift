import XCTest
@testable import NoBorderEngine

final class TrampolineTests: XCTestCase {
    /// Fixed addresses so generation is deterministic and the blob layout can be asserted.
    private static let addresses = AddressTable(msgSend: 0x1_8000_0000,
                                               selRegisterName: 0x1_8000_1000,
                                               objcGetClass: 0x1_8000_2000)

    /// Fixed thread state: x0…x30 each a distinct recognisable value, so a restored register can
    /// be traced back to the slot it came from.
    private static let handback = ThreadHandback(registers: (0..<31).map { UInt64(0xAA00 + $0) },
                                                sp: 0x1234_0000, pc: 0x5678_0000)

    private func blob(_ script: RemoteScript) -> [UInt8] {
        Trampoline.data(script, addresses: Self.addresses, handback: Self.handback)
    }

    private func code(_ script: RemoteScript) -> [UInt32] {
        Trampoline.code(script, addresses: Self.addresses, handback: Self.handback)
    }

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

    // MARK: a local decoder for checking what the generated code actually reads

    /// ldr x<d>, [x<b>, #<offset>], decoded from the instruction format rather than from Arc64.
    private func isLoad64(_ word: UInt32, base: Int) -> Bool {
        (word & 0xFFC0_0000) == 0xF940_0000 && Int((word >> 5) & 0x1F) == base
    }

    private func decodeLoad64(_ word: UInt32) -> (destination: Int, offset: Int) {
        (Int(word & 0x1F), Int((word >> 10) & 0xFFF) * 8)
    }

    private func readLE64(_ data: [UInt8], at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for shift in (0..<8).reversed() { value = (value << 8) | UInt64(data[offset + shift]) }
        return value
    }

    // MARK: finding the data from inside the target

    /// A local decoder, written from the instruction format rather than from `Arc64`, so a mistake
    /// in the generator's address arithmetic shows up here instead of cancelling out.
    private func isAdr(_ word: UInt32) -> Bool { (word & 0x9F00_0000) == 0x1000_0000 }

    private func adrTarget(_ word: UInt32, at instruction: Int) -> Int {
        let immlo = Int((word >> 29) & 0x3)
        let imm19 = Int(Int32(bitPattern: ((word >> 5) & 0x7_FFFF) << 13)) >> 13
        return 4 * instruction + (immlo | (imm19 << 2))
    }

    func testTheDataOffsetStartsAfterTheCodeAndIsEightAligned() {
        // The code reads its data with 8-byte loads from one base register, so the base must be
        // 8-aligned and must not overlap the code.
        for wordCount in [1, 2, 47, 48] {
            let offset = Trampoline.dataOffset(codeWordCount: wordCount)
            XCTAssertGreaterThanOrEqual(offset, 4 * wordCount)
            XCTAssertEqual(offset % 8, 0, "offset for \(wordCount) words")
        }
    }

    func testGeneratedCodePointsItsBaseRegisterAtTheData() {
        for script in [RemoteScript.applied(windowNumbers: [7]),
                       RemoteScript.restored(windowNumbers: [7, 9])] {
            let code = self.code(script)
            let dataAt = Trampoline.dataOffset(codeWordCount: code.count)
            XCTAssertEqual(adrTarget(code[0], at: 0), dataAt,
                           "the base-register adr at the first instruction must reach the data")
        }
    }

    func testEveryDataReferenceStaysInsideTheData() {
        for script in [RemoteScript.applied(windowNumbers: [7]),
                       RemoteScript.applied(windowNumbers: [7, 8, 9]),
                       RemoteScript.restored(windowNumbers: [7])] {
            let code = self.code(script)
            let data = self.blob(script)
            let dataAt = Trampoline.dataOffset(codeWordCount: code.count)
            for (index, word) in code.enumerated() where isAdr(word) {
                let target = adrTarget(word, at: index)
                XCTAssertTrue(target >= dataAt && target < dataAt + data.count,
                              "adr at instruction \(index) reads \(target), outside the data at \(dataAt)")
            }
        }
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
        // [NSApplication sharedApplication] once, then per window:
        // [app windowWithWindowNumber:] + setHasShadow: + _setCornerRadius:
        //   + _titlebarContainerView + setDrawsDecorationView:
        XCTAssertEqual(indirectCallCount(code(RemoteScript.applied(windowNumbers: [7]))), 6)
        XCTAssertEqual(indirectCallCount(code(RemoteScript.applied(windowNumbers: [7, 8]))), 11)
    }

    func testCodeHandsTheThreadBackInsteadOfWaitingForUs() {
        // A self-loop leaves the app spinning until our thread_set_state takes effect: measured at
        // 7.5 ms of spinning, more than this phase is allowed to cost. So the last thing the script
        // does is jump to the address the app was going to run.
        let code = self.code(RemoteScript.applied(windowNumbers: [7]))
        XCTAssertEqual(code.last, Arc64.br(Trampoline.handbackRegister))
    }

    func testEveryRegisterTheScriptUsesComesBackFromTheHandback() {
        let code = self.code(RemoteScript.applied(windowNumbers: [7]))
        let data = self.blob(RemoteScript.applied(windowNumbers: [7]))
        let loads = code.filter { isLoad64($0, base: Trampoline.blobRegister) }.map(decodeLoad64)
        // x17 is the register the jump is made from, so it is the one exception.
        for register in Array(0...16) + Array(18...30) {
            let restored = loads.filter { $0.destination == register }
                .contains { readLE64(data, at: $0.offset) == Self.handback.registers[register] }
            XCTAssertTrue(restored, "x\(register) is never restored from its saved value")
        }
    }

    func testTheHandbackPutsTheAppsStackAndItsRunLoopCallBack() {
        let code = self.code(RemoteScript.applied(windowNumbers: [7]))
        let data = self.blob(RemoteScript.applied(windowNumbers: [7]))
        let jumpFrom = Trampoline.handbackRegister
        guard let restoreSp = code.firstIndex(of: Arc64.movSp(from: jumpFrom)) else {
            return XCTFail("the app's stack pointer is never put back")
        }
        let loads = code.enumerated().filter { isLoad64($0.element, base: Trampoline.blobRegister) }
        func loadsInto(_ register: Int, holding value: UInt64, between from: Int, and to: Int) -> Bool {
            loads.contains { $0.offset > from && $0.offset < to && decodeLoad64($0.element).destination == register
                             && readLE64(data, at: decodeLoad64($0.element).offset) == value }
        }
        XCTAssertTrue(loadsInto(jumpFrom, holding: Self.handback.sp, between: -1, and: restoreSp),
                      "the stack pointer put back does not come from the saved stack pointer")
        XCTAssertTrue(loadsInto(jumpFrom, holding: Self.handback.pc, between: restoreSp, and: code.count - 1),
                      "the address jumped to is not the run-loop call the app was in, or it was loaded "
                      + "before the stack pointer moved through the same register")
    }

    func testTheScriptMarksItselfFinishedBeforeHandingTheThreadBack() {
        let code = self.code(RemoteScript.applied(windowNumbers: [7]))
        let flag = Arc64.strZero(base: 31, offset: Trampoline.completionFlagOffset)
        guard let at = code.firstIndex(of: flag) else { return XCTFail("no completion flag write") }
        XCTAssertLessThan(at, code.count - 1, "the flag must be written before the app gets the thread back")
    }

    func testSkippedStepsMakeFewerCalls() {
        var script = RemoteScript.applied(windowNumbers: [7])
        script.cornerRadius = nil
        script.drawsDecoration = nil
        // shared application + window lookup + setHasShadow:; the titlebar view is not looked up
        XCTAssertEqual(indirectCallCount(code(script)), 3)
    }

    // MARK: the data blob

    func testBlobCarriesEverySelectorTheCodeNeeds() {
        let data = blob(RemoteScript.applied(windowNumbers: [7]))
        for name in ["NSApplication", "sharedApplication", "windowWithWindowNumber:",
                     "setHasShadow:", "_setCornerRadius:", "_titlebarContainerView",
                     "setDrawsDecorationView:"] {
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
            "str xzr, [sp, #8]",
            "ldr x16, [x19, #512]",
            "mov sp, x17",
            "br x17",
        ])
        let mine = try check.bytes(forWords: [
            Arc64.adr(dst: 17, immediate: 0x40),
            Arc64.ldr(dst: 0, base: 17, offset: 8),
            Arc64.ldrd(dst: 0, base: 17, offset: 16),
            Arc64.movz(dst: 2, value: 1),
            Arc64.movReg(dst: 0, src: 19),
            Arc64.blr(16),
            Arc64.strZero(base: 31, offset: 8),
            Arc64.ldr(dst: 16, base: 19, offset: 512),
            Arc64.movSp(from: 17),
            Arc64.br(17),
        ])
        XCTAssertEqual(mine, hand)
    }

    func testTheAssemblerCrossCheckCanItselfFail() throws {
        let check = AssemblerCheck()
        guard check.available else { throw XCTSkip("no clang/otool for the assembler cross-check") }
        let hand = try check.bytes(forHand: ["blr x16"])
        let wrong = try check.bytes(forWords: [Arc64.blr(16) &+ 1])
        XCTAssertNotEqual(wrong, hand)
    }
}
