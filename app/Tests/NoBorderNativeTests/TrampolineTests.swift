import XCTest
@testable import NoBorderNative

final class TrampolineTests: XCTestCase {
    /// Fixed addresses so generation is deterministic and the blob layout can be asserted.
    private static let addresses = AddressTable(msgSend: 0x1_8000_0000,
                                               selRegisterName: 0x1_8000_1000,
                                               objcGetClass: 0x1_8000_2000,
                                               dispatchMainQueue: 0x1_8000_3000,
                                               dispatchAsync: 0x1_8000_4000,
                                               concreteGlobalBlock: 0x1_8000_5000)

    /// Fixed dispatch facts, as the executor would hand them: the code's address (the block's
    /// invoke names it) and the absolute addresses of the two words the block writes.
    private static let dispatch = Trampoline.DispatchContext(codeBase: 0x1200_0000,
                                                             flagAddress: 0x1300_0008,
                                                             resultAddress: 0x1300_0010)

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

    private func dispatchedCode(_ script: RemoteScript) -> [UInt32] {
        Trampoline.code(script, addresses: Self.addresses, handback: Self.handback, dispatch: Self.dispatch)
    }

    private func dispatchedData(_ script: RemoteScript) -> [UInt8] {
        Trampoline.data(script, addresses: Self.addresses, handback: Self.handback, dispatch: Self.dispatch)
    }

    /// The block literal's offset: the 8-aligned data word that names the global-block isa.
    private func findBlockOffset(_ data: [UInt8]) -> Int {
        for start in stride(from: 0, through: data.count - 8, by: 8)
        where readLE64(data, at: start) == Self.addresses.concreteGlobalBlock { return start }
        XCTFail("no global-block isa word in the data")
        return -1
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

    func testForceFaultForTestingJumpsToAnAddressNoProcessHas() {
        var script = RemoteScript.applied(windowNumbers: [7])
        script.forceFaultForTesting = true
        let code = self.code(script)
        guard let at = code.firstIndex(of: Arc64.movz(dst: 16, value: 1)) else {
            return XCTFail("nothing jumps to address 1")
        }
        XCTAssertTrue(at + 1 < code.count)
        XCTAssertEqual(code[at + 1], Arc64.br(16), "the jump is not the instruction after it")
        let flag = code.firstIndex(of: Arc64.strZero(base: 31, offset: Trampoline.completionFlagOffset))!
        XCTAssertLessThan(at, flag, "the fault must happen while the thread is still ours")
    }

    func testForceFaultIsOffUnlessATestAsksForIt() {
        XCTAssertFalse(RemoteScript.applied(windowNumbers: [7]).forceFaultForTesting)
        XCTAssertFalse(self.code(RemoteScript.applied(windowNumbers: [7])).contains(Arc64.movz(dst: 16, value: 1)))
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
        XCTAssertEqual(script.hideButtons, false)
        XCTAssertEqual(script.windowNumbers, [42])
    }

    func testRestoredScriptReversesAllThreeChanges() {
        let script = RemoteScript.restored(windowNumbers: [42])
        XCTAssertEqual(script.hasShadow, true)
        XCTAssertEqual(script.cornerRadius, 0.0)
        XCTAssertEqual(script.drawsDecoration, true)
        XCTAssertEqual(script.hideButtons, false, "restoring shows the buttons as AppKit had them")
    }

    // MARK: the generated call sequence

    func testAppliedWindowMakesOneIndirectCallPerStep() {
        // [NSApplication sharedApplication] once, then per window:
        // [app windowWithWindowNumber:] + setHasShadow: + _setCornerRadius:
        //   + _titlebarContainerView + setDrawsDecorationView:
        //   + three standardWindowButton: each followed by setHidden:
        XCTAssertEqual(indirectCallCount(code(RemoteScript.applied(windowNumbers: [7]))), 12)
        XCTAssertEqual(indirectCallCount(code(RemoteScript.applied(windowNumbers: [7, 8]))), 23)
    }

    func testTheButtonStepAsksForEveryButton() {
        let hidden = code(RemoteScript.applied(windowNumbers: [7], buttonsHidden: true))
        let shown = code(RemoteScript.applied(windowNumbers: [7], buttonsHidden: false))
        // The zoom button's index 2 is sent only by the standardWindowButton: step.
        XCTAssertTrue(hidden.contains(Arc64.movz(dst: 2, value: 2)), "zoom is never asked for")
        // setHidden: gets its argument: true three more times than the shown script asks for.
        let trueArgs = Arc64.movz(dst: 2, value: 1)
        XCTAssertEqual(hidden.filter { $0 == trueArgs }.count, shown.filter { $0 == trueArgs }.count + 3)
        let data = blob(RemoteScript.applied(windowNumbers: [7], buttonsHidden: true))
        XCTAssertTrue(hasCString(data, "standardWindowButton:"))
        XCTAssertTrue(hasCString(data, "setHidden:"))
    }

    func testAScriptWithoutTheButtonFieldSaysNothingAboutButtons() {
        var script = RemoteScript.applied(windowNumbers: [7])
        script.hideButtons = nil
        XCTAssertEqual(indirectCallCount(code(script)), 6)
        XCTAssertFalse(hasCString(blob(script), "setHidden:"))
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

    // MARK: the AppKit probe

    func testTheProbeAsksForTheApplicationObjectAndNothingElse() {
        let code = self.code(.appKitProbe())
        let calls = code.filter { $0 == Arc64.blr(Trampoline.classLookupRegister)
            || $0 == Arc64.blr(Trampoline.selLookupRegister)
            || $0 == Arc64.blr(Trampoline.msgSendRegister) }.count
        XCTAssertEqual(calls, 3, "objc_getClass, one selector lookup, one message — no window work")
        let store = Arc64.str(src: Trampoline.appRegister, base: 31, offset: Trampoline.resultOffset)
        guard let at = code.firstIndex(of: store) else { return XCTFail("the probe never writes its answer") }
        let flag = code.firstIndex(of: Arc64.strZero(base: 31, offset: Trampoline.completionFlagOffset))
        XCTAssertLessThan(at, flag!, "the answer is written before the flag says the script is done")
    }

    func testTheProbeCarriesNoWindowSelectors() {
        let data = self.blob(.appKitProbe())
        XCTAssertFalse(hasCString(data, Trampoline.lookupSelector))
        XCTAssertFalse(hasCString(data, Trampoline.hasShadowSelector))
        XCTAssertFalse(hasCString(data, Trampoline.cornerRadiusSelector))
        XCTAssertTrue(hasCString(data, Trampoline.sharedApplicationSelector), "it does ask for the app")
    }

    func testSkippedStepsMakeFewerCalls() {
        var script = RemoteScript.applied(windowNumbers: [7])
        script.cornerRadius = nil
        script.drawsDecoration = nil
        // shared application + window lookup + setHasShadow: + the six button calls;
        // the titlebar view is not looked up
        XCTAssertEqual(indirectCallCount(code(script)), 9)
    }

    // MARK: the key state read

    func testKeyStateReadAsksTheGetterPerWindow() {
        // shared application + per window: windowWithWindowNumber: + isKeyWindow
        XCTAssertEqual(indirectCallCount(code(.keyStateRead(windowNumbers: [7]))), 3)
        XCTAssertEqual(indirectCallCount(code(.keyStateRead(windowNumbers: [7, 9]))), 5)
    }

    func testKeyStateReadCarriesTheGetterNameAndNoneOfTheSetters() {
        let data = blob(.keyStateRead(windowNumbers: [7]))
        XCTAssertTrue(hasCString(data, "windowWithWindowNumber:"))
        XCTAssertTrue(hasCString(data, "isKeyWindow"))
        XCTAssertFalse(hasCString(data, "setHasShadow:"))
        XCTAssertFalse(hasCString(data, "setDrawsDecorationView:"))
        XCTAssertFalse(hasCString(data, "standardWindowButton:"))
    }

    func testKeyStateReadPacksItsAnswerIntoTheResultWordBeforeTheFlag() {
        let code = self.code(.keyStateRead(windowNumbers: [7, 9]))
        let store = Arc64.str(src: Trampoline.readAccumulatorRegister, base: 31, offset: Trampoline.resultOffset)
        guard let at = code.firstIndex(of: store) else { return XCTFail("the read never writes its answer") }
        let flag = code.firstIndex(of: Arc64.strZero(base: 31, offset: Trampoline.completionFlagOffset))
        XCTAssertLessThan(at, flag!, "the answer is written while the script is still running")
    }

    func testKeyStateReadAccumulatorIsZeroedBeforeTheFirstWindow() {
        let code = self.code(.keyStateRead(windowNumbers: [7]))
        let zero = Arc64.movz(dst: Trampoline.readAccumulatorRegister, value: 0)
        guard let at = code.firstIndex(of: zero) else { return XCTFail("the answer accumulator is never zeroed") }
        // The first window number is the first word of the window list: [msgSend, selName, class, wid…].
        let firstAsk = code.firstIndex(of: Arc64.ldr(dst: 2, base: Trampoline.blobRegister, offset: 24))!
        XCTAssertLessThan(at, firstAsk, "zeroed before the first window is asked")
    }

    // MARK: the data blob

    func testBlobCarriesEverySelectorTheCodeNeeds() {
        let data = blob(RemoteScript.applied(windowNumbers: [7]))
        for name in ["NSApplication", "sharedApplication", "windowWithWindowNumber:",
                     "setHasShadow:", "_setCornerRadius:", "_titlebarContainerView",
                     "setDrawsDecorationView:", "standardWindowButton:", "setHidden:"] {
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
            "str x21, [sp, #16]",
            "ldr x16, [x19, #512]",
            "mov sp, x17",
            "br x17",
            "orr w0, w1, w2",
            "mov w28, w0",
            "orr w26, wzr, w27, lsl #1",   // the shift as the generator encodes it, not the lsl mnemonic
            "sub sp, sp, #96",
            "stp x19, x20, [sp, #0]",
            "stp x21, x22, [sp, #16]",
            "stp x29, x30, [sp, #80]",
            "ldp x19, x20, [sp, #0]",
            "ldp x29, x30, [sp, #80]",
            "sub x19, x0, #32",
            "add sp, sp, #96",
            "ret",
        ])
        let mine = try check.bytes(forWords: [
            Arc64.adr(dst: 17, immediate: 0x40),
            Arc64.ldr(dst: 0, base: 17, offset: 8),
            Arc64.ldrd(dst: 0, base: 17, offset: 16),
            Arc64.movz(dst: 2, value: 1),
            Arc64.movReg(dst: 0, src: 19),
            Arc64.blr(16),
            Arc64.strZero(base: 31, offset: 8),
            Arc64.str(src: 21, base: 31, offset: 16),
            Arc64.ldr(dst: 16, base: 19, offset: 512),
            Arc64.movSp(from: 17),
            Arc64.br(17),
            Arc64.orr32(dst: 0, lhs: 1, rhs: 2),
            Arc64.movReg32(dst: 28, src: 0),
            Arc64.lsl32(dst: 26, src: 27, amount: 1),
            Arc64.subImm(dst: 31, src: 31, imm: 96),
            Arc64.stp(dst: 19, dst2: 20, base: 31, offset: 0),
            Arc64.stp(dst: 21, dst2: 22, base: 31, offset: 16),
            Arc64.stp(dst: 29, dst2: 30, base: 31, offset: 80),
            Arc64.ldp(dst: 19, dst2: 20, base: 31, offset: 0),
            Arc64.ldp(dst: 29, dst2: 30, base: 31, offset: 80),
            Arc64.subImm(dst: 19, src: 0, imm: 32),
            Arc64.addImm(dst: 31, src: 31, imm: 96),
            Arc64.ret(),
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

    // MARK: the dispatched entry

    func testDispatchedStubQueuesTheBlockOnTheMainQueue() {
        let script = RemoteScript.applied(windowNumbers: [7])
        let code = dispatchedCode(script)
        let data = dispatchedData(script)
        // dispatch_async(&main queue, &block): load the queue object (the header getter is an
        // inline of its address), point x1 at the literal, make the one call.
        XCTAssertTrue(isAdr(code[0]), "the stub starts by pointing x19 at its data")
        XCTAssertEqual(code[1 + Trampoline.absorberWordCount],
                       Arc64.ldr(dst: 0, base: Trampoline.blobRegister,
                                 offset: Trampoline.dispatchMainQueueOffset),
                       "the main queue object loads straight into x0")
        let blockOffset = findBlockOffset(data)
        let dataAt = Trampoline.dataOffset(codeWordCount: code.count)
        let queueBase = 1 + Trampoline.absorberWordCount
        XCTAssertEqual(adrTarget(code[queueBase + 1], at: queueBase + 1), dataAt + blockOffset,
                       "x1 must point at the block literal")
        XCTAssertEqual(code[queueBase + 2], Arc64.ldr(dst: 16, base: Trampoline.blobRegister,
                                                      offset: Trampoline.dispatchAsyncOffset))
        XCTAssertEqual(code[queueBase + 3], Arc64.blr(16))
        // The words the block writes by absolute address are in the data.
        XCTAssertTrue(hasLEValue(data, Self.dispatch.flagAddress))
        XCTAssertTrue(hasLEValue(data, Self.dispatch.resultAddress))
        // The window numbers come after the seven dispatch words.
        XCTAssertEqual(readLE64(data, at: 56), 7)
    }

    func testStubAbsorbsTheArmedInterruptBeforeQueueing() throws {
        // thread_abort leaves CF's armed receive interrupted: its MACH_RCV_INTERRUPTED hits CF's
        // next mach call, and measured 2026-10-20 every death (five hostapps + live Vivaldi) is
        // __CFRunLoopServiceMachPort.cold.1 — CF tolerates only {success, TOO_LARGE, TIMED_OUT}.
        // The stub's first act must be its own sacrificial receive, before dispatch_async makes
        // CF touch a port. It goes through the legacy `mach_msg` shim: the raw mach_msg2_trap
        // rejects a timed receive with MACH_RCV_INVALID_ARGUMENTS (0x10004013) — the same kr
        // class the absorber exists to prevent — and requires the overmach bits the shim owns.
        let script = RemoteScript.applied(windowNumbers: [7])
        let code = dispatchedCode(script)
        let data = dispatchedData(script)
        let absorbCall = 1 + 7   // the stub's blr(16): absorber ops come first
        XCTAssertEqual(code[absorbCall], Arc64.blr(16), "the absorber's shim call")
        XCTAssertEqual(code[absorbCall + 1],
                       Arc64.str(src: 0, base: 31, offset: Trampoline.absorbKrSpOffset),
                       "the absorber leaves its kr on the executor's writable stack (the code region is r-x)")
        let shimCalls = code.indices.filter { code[$0] == Arc64.blr(16) }
        let queueCall = try XCTUnwrap(shimCalls.count > 1 ? shimCalls[1] : nil,
                                      "the dispatch_async call")
        XCTAssertLessThan(absorbCall, queueCall,
                          "the sacrificial receive must come before dispatch_async queues the block")
        // The absorber's arguments: a timed receive on the executor's allocated right. Its two
        // data words sit right after the 64-byte message buffer, before the strings.
        let absorbAt = Trampoline.absorbPortDataOffset(script: script)
        XCTAssertEqual(readLE64(data, at: absorbAt), Self.dispatch.absorbPort, "port word")
        XCTAssertEqual(readLE64(data, at: absorbAt + 8), Self.addresses.machMsg, "mach_msg address word")
        XCTAssertTrue(isAdr(code[1]), "x0 is the message buffer, data-relative via adr")
        XCTAssertEqual(code[2], Arc64.movz(dst: 1, value: 0x102), "MACH_RCV_MSG | MACH_RCV_TIMEOUT (0x100)")
        XCTAssertEqual(code[3], Arc64.movz(dst: 2, value: 0), "no send")
        XCTAssertEqual(code[4], Arc64.movz(dst: 3, value: 64), "receive size")
        XCTAssertEqual(code[5], Arc64.ldr(dst: 4, base: Trampoline.blobRegister, offset: absorbAt),
                       "x4 = the absorber port word")
        XCTAssertEqual(code[6], Arc64.movz(dst: 5, value: 1), "1 ms timeout")
        XCTAssertEqual(code[7], Arc64.ldr(dst: 16, base: Trampoline.blobRegister, offset: absorbAt + 8),
                       "x16 = the mach_msg address word")
    }

    func testDispatchedStubHandsTheThreadBackRightAfterQueueing() {
        let code = dispatchedCode(RemoteScript.applied(windowNumbers: [7]))
        // base + absorber (8) + four queueing ops + the 34-op handback: the last stub word is the
        // branch to the app, and the block code starts immediately behind it.
        let stubWords = 1 + Trampoline.absorberWordCount + 4 + 34
        XCTAssertEqual(code[stubWords - 1], Arc64.br(Trampoline.handbackRegister))
        XCTAssertEqual(code[stubWords], Arc64.subImm(dst: 31, src: 31, imm: Trampoline.calleeSavedFrame),
                       "the block's frame starts where the stub ends")
    }

    func testBlockLiteralIsAGlobalBlockInvokingTheGeneratedCode() {
        let code = dispatchedCode(RemoteScript.applied(windowNumbers: [7]))
        let data = dispatchedData(RemoteScript.applied(windowNumbers: [7]))
        let blockOffset = findBlockOffset(data)
        XCTAssertEqual(readLE64(data, at: blockOffset), Self.addresses.concreteGlobalBlock)
        XCTAssertEqual(readLE64(data, at: blockOffset + 8) & ~Trampoline.blockIsGlobal, 0,
                       "flags carry BLOCK_IS_GLOBAL (the only way Block_copy returns the pointer) "
                       + "and nothing else; reserved is zero")
        XCTAssertNotEqual(readLE64(data, at: blockOffset + 8) & Trampoline.blockIsGlobal, 0,
                          "without the global bit _Block_copy takes the stack path")
        // invoke names the block code: the word list right behind the stub's branch.
        let invoke = readLE64(data, at: blockOffset + 16)
        XCTAssertEqual(invoke, Self.dispatch.codeBase &+ UInt64(4 * (1 + Trampoline.absorberWordCount + 4 + 34)))
        XCTAssertEqual(invoke, Self.dispatch.codeBase &+ UInt64(4 * code.firstIndex(of: Arc64.subImm(
            dst: 31, src: 31, imm: Trampoline.calleeSavedFrame))!),
                       "invoke must land exactly on the block's first instruction")
        // The descriptor sits right behind the literal, and _Block_copy dereferences desc->size
        // even for globals — it must be non-null and the size must be the literal's.
        let desc = readLE64(data, at: blockOffset + 24)
        XCTAssertNotEqual(desc, 0, "a null descriptor dies in _Block_copy")
        let dataAt = Trampoline.dataOffset(codeWordCount: code.count)
        XCTAssertEqual(desc, Self.dispatch.codeBase &+ UInt64(dataAt) &+ UInt64(blockOffset + 32),
                       "desc must point at the descriptor words behind the literal")
        XCTAssertEqual(readLE64(data, at: blockOffset + 32), 0, "descriptor reserved")
        XCTAssertEqual(readLE64(data, at: blockOffset + 40), 32, "descriptor size")
    }

    func testDispatchedBlockSavesAndRestoresTheCalleeSavedRegisters() {
        let code = dispatchedCode(RemoteScript.applied(windowNumbers: [7]))
        // The C ABI: x19…x30 in and out, the frame 16-aligned, back to libdispatch on the link
        // register. The selector sequence keeps those registers live; libdispatch expects them.
        for offset in stride(from: 0, to: 96, by: 16) {
            XCTAssertTrue(code.contains(Arc64.stp(dst: 19 + offset / 8, dst2: 20 + offset / 8,
                                                  base: 31, offset: offset)), "no stp at #\(offset)")
            XCTAssertTrue(code.contains(Arc64.ldp(dst: 19 + offset / 8, dst2: 20 + offset / 8,
                                                  base: 31, offset: offset)), "no ldp at #\(offset)")
        }
        XCTAssertTrue(code.contains(Arc64.subImm(dst: 31, src: 31, imm: 96)))
        XCTAssertTrue(code.contains(Arc64.addImm(dst: 31, src: 31, imm: 96)))
        XCTAssertEqual(code.last, Arc64.ret(), "the block returns to libdispatch, it does not jump")
        // The data base comes from the block's descriptor field: the main queue heap-copies a
        // global block, so x0 is that copy and only the descriptor pointer survives into it.
        let blockOffset = findBlockOffset(dispatchedData(RemoteScript.applied(windowNumbers: [7])))
        let load = code.firstIndex(of: Arc64.ldr(dst: Trampoline.blobRegister, base: 0, offset: 24))
        let base = code.firstIndex(of: Arc64.subImm(dst: Trampoline.blobRegister, src: Trampoline.blobRegister,
                                                    imm: blockOffset + 32))
        let prologue = code.firstIndex(of: Arc64.stp(dst: 29, dst2: 30, base: 31, offset: 80))!
        XCTAssertGreaterThan(load!, prologue, "the descriptor loads after the frame")
        XCTAssertEqual(base!, load! + 1, "the descriptor is stepped back to the data at once")
        let firstCall = code.firstIndex(of: Arc64.blr(Trampoline.msgSendRegister))!
        XCTAssertGreaterThan(firstCall, base!, "app work starts after the base is set")
        let epilogue = code.firstIndex(of: Arc64.ldp(dst: 19, dst2: 20, base: 31, offset: 0))!
        XCTAssertGreaterThan(epilogue, firstCall, "the registers come back after the work")
    }

    func testDispatchedFlagIsWrittenByTheBlockAtTheAbsoluteAddressLast() {
        let code = dispatchedCode(RemoteScript.applied(windowNumbers: [7]))
        let load = Arc64.ldr(dst: 16, base: Trampoline.blobRegister, offset: Trampoline.flagAddressOffset)
        let store = Arc64.str(src: 31, base: 16, offset: 0)
        guard let at = code.firstIndex(of: store) else { return XCTFail("the block never writes the flag") }
        XCTAssertEqual(code[at - 1], load, "the flag store reads its absolute address from the data")
        let lastCall = code.lastIndex(of: Arc64.blr(Trampoline.msgSendRegister))!
        XCTAssertGreaterThan(at, lastCall, "the flag says every call has returned")
        let epilogue = code.firstIndex(of: Arc64.ldp(dst: 19, dst2: 20, base: 31, offset: 0))!
        XCTAssertLessThan(at, epilogue, "the flag is written before the block returns")
        // The fabricated frame's sp-relative flag write is gone: this stack is the app's.
        XCTAssertFalse(code.contains(Arc64.strZero(base: 31, offset: Trampoline.completionFlagOffset)))
    }

    func testDispatchedKeyStateReadWritesTheAnswerToTheAbsoluteResultWord() {
        let code = dispatchedCode(RemoteScript.keyStateRead(windowNumbers: [7, 9]))
        let load = Arc64.ldr(dst: 16, base: Trampoline.blobRegister, offset: Trampoline.resultAddressOffset)
        let store = Arc64.str(src: Trampoline.readAccumulatorRegister, base: 16, offset: 0)
        guard let at = code.firstIndex(of: store) else { return XCTFail("the read never writes its answer") }
        XCTAssertEqual(code[at - 1], load)
        let flagStore = code.firstIndex(of: Arc64.str(src: 31, base: 16, offset: 0))!
        XCTAssertLessThan(at, flagStore, "the answer is written before the flag says it is done")
    }

    func testDispatchedEntrySendsTheSameMessagesAsTheFrameScript() {
        for script in [RemoteScript.applied(windowNumbers: [7]),
                       RemoteScript.applied(windowNumbers: [7, 8], buttonsHidden: true),
                       RemoteScript.restored(windowNumbers: [7]),
                       RemoteScript.keyStateRead(windowNumbers: [7])] {
            XCTAssertEqual(indirectCallCount(dispatchedCode(script)), indirectCallCount(code(script)),
                           "the selector sequence must be the same work, in a block")
        }
    }

    func testDispatchedForceFaultFaultsInsideTheBlockBeforeAppWork() {
        var script = RemoteScript.applied(windowNumbers: [7])
        script.forceFaultForTesting = true
        let code = dispatchedCode(script)
        let blockOffset = findBlockOffset(dispatchedData(script))
        let base = code.firstIndex(of: Arc64.subImm(dst: Trampoline.blobRegister, src: Trampoline.blobRegister,
                                                    imm: blockOffset + 32))!
        let jump = code.firstIndex(of: Arc64.movz(dst: 16, value: 1))!
        let firstCall = code.firstIndex(of: Arc64.blr(Trampoline.msgSendRegister))!
        XCTAssertGreaterThan(jump, base, "the fault happens in the block, not the stub")
        XCTAssertLessThan(jump, firstCall, "and before anything is applied")
        let lastCall = code.lastIndex(of: Arc64.blr(Trampoline.msgSendRegister))!
        XCTAssertLessThan(lastCall, code.count - 1, "the block code is still generated after the jump")
    }

    func testDispatchedResumeLandsOnTheBlockEpilogue() {
        // A fault inside the block steps it home: the resume address is the first ldp of the
        // epilogue, so the callee-saved registers come back and the block returns to libdispatch.
        for script in [RemoteScript.applied(windowNumbers: [7]),
                       RemoteScript.applied(windowNumbers: [7, 8], buttonsHidden: true),
                       RemoteScript.keyStateRead(windowNumbers: [7])] {
            let code = dispatchedCode(script)
            let resume = Trampoline.dispatchedResumeCode(script, addresses: Self.addresses,
                                                         handback: Self.handback, codeBase: Self.dispatch.codeBase)
            let at = Int((resume &- Self.dispatch.codeBase) / 4)
            XCTAssertEqual(code[at], Arc64.ldp(dst: 19, dst2: 20, base: 31, offset: 0),
                           "resume must be the epilogue's first ldp for \(script)")
            XCTAssertEqual(code[at + 6], Arc64.addImm(dst: 31, src: 31, imm: Trampoline.calleeSavedFrame))
            XCTAssertEqual(code[at + 7], Arc64.ret())
        }
    }

    func testScratchBytesCoversExactlyCodeAndData() {
        for script in [RemoteScript.applied(windowNumbers: [7, 8]),
                       RemoteScript.keyStateRead(windowNumbers: [7]),
                       RemoteScript.restored(windowNumbers: [7])] {
            for dispatch in [nil, Self.dispatch] {
                let code = Trampoline.code(script, addresses: Self.addresses, handback: Self.handback,
                                           dispatch: dispatch)
                let data = Trampoline.data(script, addresses: Self.addresses, handback: Self.handback,
                                           dispatch: dispatch)
                let bytes = Trampoline.scratchBytes(script, addresses: Self.addresses, handback: Self.handback,
                                                    dispatch: dispatch)
                XCTAssertEqual(bytes, Trampoline.dataOffset(codeWordCount: code.count) + data.count)
            }
        }
    }
}
