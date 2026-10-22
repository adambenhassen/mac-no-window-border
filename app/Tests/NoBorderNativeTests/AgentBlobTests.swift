import Foundation
import XCTest
import NoBorderNative

/// Audits the agent blob: every new encoding cross-checked against the system assembler (the
/// AssemblerCheck convention), and every word of the built code decoded to prove the properties
/// the hand-encoders cannot show by themselves — verdict 6's audit list: no callee-saved
/// register is written, x18 is untouched, SP is 16-aligned at every call and balanced at the
/// return, and every store lands on the state page, the stack, or a digits cursor — never the
/// code page.
final class AgentBlobTests: XCTestCase {
    func testEncodingsAgainstSystemAssembler() throws {
        let asm = AssemblerCheck()
        guard asm.available else { throw XCTSkip("no clang/otool") }
        // (hand-written assembly, our words). Branches are label-relative; each pair is a
        // self-contained fragment.
        let cases: [([String], [UInt32])] = [
            (["movk x3, #0x1234", "movk x3, #0x1234, lsl #16", "movk x3, #0x1234, lsl #32",
              "movk x3, #0x1234, lsl #48"],
             [Arc64.movk(dst: 3, value: 0x1234, shift: 0), Arc64.movk(dst: 3, value: 0x1234, shift: 16),
              Arc64.movk(dst: 3, value: 0x1234, shift: 32), Arc64.movk(dst: 3, value: 0x1234, shift: 48)]),
            (["movz x7, #0x1234"], [Arc64.movz64(dst: 7, value: 0x1234)]),
            // The chain, spelled: movImm64 is these four words in this order.
            (["movz x7, #0xcdef", "movk x7, #0x90ab, lsl #16", "movk x7, #0x5678, lsl #32",
              "movk x7, #0x1234, lsl #48"],
             Arc64.movImm64(dst: 7, value: 0x1234_5678_90ab_cdef)),
            (["ldr w4, [x1, #20]", "ldr w5, [x6, #0]"],
             [Arc64.ldr32(dst: 4, base: 1, offset: 20), Arc64.ldr32(dst: 5, base: 6, offset: 0)]),
            (["ldr d0, [x17, #8]", "ldr d1, [x17, #0]"],
             [Arc64.ldrd(dst: 0, base: 17, offset: 8), Arc64.ldrd(dst: 1, base: 17, offset: 0)]),
            (["fadd d0, d0, d1", "fadd d2, d4, d3"],
             [Arc64.faddD(dst: 0, lhs: 0, rhs: 1), Arc64.faddD(dst: 2, lhs: 4, rhs: 3)]),
            (["str w4, [sp, #4]", "str w5, [x8, #0]"],
             [Arc64.str32(src: 4, base: 31, offset: 4), Arc64.str32(src: 5, base: 8, offset: 0)]),
            (["ldrb w7, [x5, #1]", "ldrb w9, [x16, #0]"],
             [Arc64.ldrb(dst: 7, base: 5, offset: 1), Arc64.ldrb(dst: 9, base: 16, offset: 0)]),
            (["strb w7, [x4, #8]", "strb wzr, [x8, #0]"],
             [Arc64.strb(src: 7, base: 4, offset: 8), Arc64.strb(src: 31, base: 8, offset: 0)]),
            (["cmp x16, #2004", "cmp xzr, xzr"],
             [Arc64.cmpImm(src: 16, imm: 2004), Arc64.cmpReg(lhs: 31, rhs: 31)]),
            (["cmp x5, x9"], [Arc64.cmpReg(lhs: 5, rhs: 9)]),
            (["add x7, x7, #1", "sub x5, x4, #1"],
             [Arc64.addImmBytes(dst: 7, src: 7, imm: 1), Arc64.subImmBytes(dst: 5, src: 4, imm: 1)]),
            (["add x1, x2, x3", "sub x7, x3, x6"],
             [Arc64.addReg(dst: 1, lhs: 2, rhs: 3), Arc64.subReg(dst: 7, lhs: 3, rhs: 6)]),
            (["udiv x5, x3, x16"], [Arc64.udiv(dst: 5, lhs: 3, rhs: 16)]),
            (["madd x6, x5, x16, xzr"], [Arc64.madd(dst: 6, lhs: 5, rhs: 16, addend: 31)]),
            (["L: b L", "L2: cbz x16, L2", "L3: cbnz x3, L3", "L4: b.hs L4", "L5: b.ne L5"],
             [Arc64.b(immediate: 0), Arc64.cbz(src: 16, immediate: 0), Arc64.cbz(src: 3, immediate: 0, nonzero: true),
              Arc64.bCond(2, immediate: 0), Arc64.bCond(1, immediate: 0)]),
            // The observer/teardown slots live past 2728; the remove block and the blob read/write
            // them with scaled-immediate ldr/str. These pin the encoding at the exact offsets (the
            // historical "2040 ceiling" was a slot collision, not a field limit) against clang.
            (["ldr x16, [x0, #2768]", "ldr x0, [x17, #2760]", "str x0, [x17, #2760]",
              "ldr x16, [x17, #2728]", "ldr x16, [x17, #2744]"],
             [Arc64.ldr(dst: 16, base: 0, offset: AgentBlob.teardownAddrSlot),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.observerRefSlot),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.observerRefSlot),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.observerCreateSlot),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.observerInvalidateSlot)]),
        ]
        for (lines, words) in cases {
            let hand = try asm.bytes(forHand: lines)
            let ours = try asm.bytes(forWords: words)
            XCTAssertEqual(hand, ours, "encoding mismatch for \(lines)")
        }
    }

    /// A backward `b`: the 26-bit field is the whole mask — a wider mask traps the Int→UInt32
    /// conversion on the negative shift (measured 2026-10-21, the first backward branch in the
    /// blob). The word is the system assembler's: clang of `mov w16, #0; L1: b L1-8` disassembles
    /// to 52800010 17fffffe.
    func testBackwardBranchEncoding() {
        XCTAssertEqual(Arc64.b(immediate: -8), 0x17FF_FFFE)
        XCTAssertEqual(Arc64.b(immediate: 0), 0x1400_0000)
    }

    func testBuildManifest() {
        let built = AgentBlob.build(pid: 4242)
        func word(_ at: Int) -> UInt64 {
            built.state.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self) }
        }
        XCTAssertEqual(word(AgentBlob.magicSlot), AgentBlob.magic)
        XCTAssertEqual(word(AgentBlob.versionSlot), AgentBlob.version)
        XCTAssertEqual(word(AgentBlob.pidSlot), 4242)
        XCTAssertEqual(word(AgentBlob.entryOffSlot), 0)
        XCTAssertEqual(word(AgentBlob.cbOffSlot), UInt64(built.cbOff))
        XCTAssertEqual(word(AgentBlob.codeLenSlot), UInt64(built.code.count * 4))
        XCTAssertLessThanOrEqual(built.code.count * 4, AgentBlob.pageSize, "the code fits its page")
    }

    /// The observer slots (P1e) are genuinely free: distinct, 8-aligned, past the highest slot the
    /// blob ever writes (`selLoopCountSlot`+8 = 2728 — the misdiagnosed "2040 ldr limit" on
    /// `machPortRefSlot` was a slot collision, not an encoding ceiling), and inside the state page.
    func testObserverSlotsAreFreeAndDistinct() {
        let slots = [AgentBlob.observerCreateSlot, AgentBlob.observerAddSlot,
                     AgentBlob.observerInvalidateSlot, AgentBlob.observerCbAddrSlot,
                     AgentBlob.observerRefSlot, AgentBlob.teardownAddrSlot]
        XCTAssertEqual(Set(slots).count, slots.count, "observer slots overlap")
        for slot in slots {
            XCTAssertGreaterThanOrEqual(slot, AgentBlob.selLoopCountSlot + 8, "slot \(slot) collides with a written slot")
            XCTAssertEqual(slot % 8, 0, "slot \(slot) is not 8-aligned")
            XCTAssertLessThan(slot + 8, AgentBlob.pageSize, "slot \(slot) overruns the state page")
        }
    }

    /// The observer callback and the teardown subroutine are assembled, 16-aligned, and the whole
    /// code still fits the code page. The installer patches their absolute addresses into
    /// `observerCbAddrSlot` / `teardownAddrSlot`.
    func testObserverAndTeardownAreBuilt() {
        let built = AgentBlob.build(pid: 7)
        XCTAssertEqual(built.observerOff % 16, 0, "the observer entry is 16-aligned")
        XCTAssertEqual(built.teardownOff % 16, 0, "the teardown entry is 16-aligned")
        XCTAssertGreaterThan(built.observerWordCount, 0)
        XCTAssertGreaterThan(built.teardownWordCount, 0)
        XCTAssertLessThanOrEqual(built.code.count * 4, AgentBlob.pageSize, "the code still fits its page")
    }

    /// `AgentAddresses.current()` resolves the three new CFRunLoopObserver symbols on this OS, and
    /// they stay out of `.table` (so the 22-entry table — and `cbAddrSlot=240` below it — is
    /// unmoved). The installer prefills them into the fresh observer slots instead.
    func testObserverAddressesResolveAndStayOutOfTable() throws {
        guard let a = AgentAddresses.current() else { throw XCTSkip("no agent addresses") }
        XCTAssertNotEqual(a.cfRunLoopObserverCreate, 0)
        XCTAssertNotEqual(a.cfRunLoopAddObserver, 0)
        XCTAssertNotEqual(a.cfRunLoopObserverInvalidate, 0)
        XCTAssertEqual(a.table.count, 22, "the function table must not grow")
        XCTAssertFalse(a.table.contains(a.cfRunLoopObserverCreate))
        XCTAssertFalse(a.table.contains(a.cfRunLoopAddObserver))
        XCTAssertFalse(a.table.contains(a.cfRunLoopObserverInvalidate))
    }

    // MARK: the word audit

    private struct Decoded {
        var word: UInt32
        var name: String
        var writes: [Int]        // destination/rt registers
        var base: Int?           // memory base register, when the instruction reads/writes memory
        var isStore: Bool
        var isCall: Bool
        var spDelta: Int
        var terminates: Bool     // ret
    }

    /// The blob's exact instruction set, decoded by opcode pattern. Anything outside it is a
    /// failure: an instruction the audit has not considered is exactly what this test is for.
    private func decode(_ word: UInt32) -> Decoded? {
        func rd(_ w: UInt32) -> Int { Int(w & 0x1F) }
        func rn(_ w: UInt32) -> Int { Int((w >> 5) & 0x1F) }
        func imm12(_ w: UInt32) -> Int { Int((w >> 10) & 0xFFF) }
        func add(_ name: String, writes: [Int] = [], base: Int? = nil, isStore: Bool = false,
                 isCall: Bool = false, spDelta: Int = 0, terminates: Bool = false) -> Decoded {
            Decoded(word: word, name: name, writes: writes, base: base, isStore: isStore,
                    isCall: isCall, spDelta: spDelta, terminates: terminates)
        }
        if word == 0xD65F_03C0 { return add("ret", terminates: true) }
        if word & 0xD63F_0000 == 0xD63F_0000 { return add("blr", isCall: true) }
        if word & 0xD61F_0000 == 0xD61F_0000 { return add("br", isCall: true) }
        if (word & 0x7F00_0000) == 0x3400_0000 { return add("cbz") }
        if (word & 0x7F00_0000) == 0x3500_0000 { return add("cbnz") }
        if word & 0xFC00_0000 == 0x1400_0000 { return add("b") }
        if word & 0xFF00_0010 == 0x5400_0000 { return add("b.cond") }
        if word & 0x9F00_0000 == 0x1000_0000 { return add("adr", writes: [rd(word)]) }
        if word & 0xFF80_0000 == 0x5280_0000 { return add("movz", writes: [rd(word)]) }
        if word & 0xFF80_0000 == 0xD280_0000 { return add("movz64", writes: [rd(word)]) }
        if word & 0xFF80_0000 == 0xF280_0000 { return add("movk", writes: [rd(word)]) }
        if word & 0xFFE0_FFE0 == 0xAA00_03E0 { return add("mov", writes: [rd(word)]) }
        if word & 0xFFE0_FC00 == 0xCB00_0000 { return add("sub", writes: [rd(word)]) }
        if word & 0xFFE0_FC00 == 0x8B00_0000 { return add("add", writes: [rd(word)]) }
        if word & 0x7FE0_FC00 == 0x1AC0_0800 { return add("udiv", writes: [rd(word)]) }
        if word & 0x7FE0_8000 == 0x1B00_0000 { return add("madd", writes: [rd(word)]) }
        if word & 0xFFC0_0000 == 0xF100_0000 { return add("cmp imm") }   // subs XZR: Rd/imm/Rn excluded
        if word & 0xFFE0_0000 == 0xEB00_0000 { return add("cmp reg") }
        if word & 0xFFC0_0000 == 0xD100_0000, rd(word) == 31, rn(word) == 31 {
            return add("sub sp", writes: [31], spDelta: -imm12(word))
        }
        if word & 0xFFC0_0000 == 0x9100_0000, rd(word) == 31, rn(word) == 31 {
            return add("add sp", writes: [31], spDelta: imm12(word))
        }
        if word & 0xFFC0_0000 == 0xD100_0000 { return add("sub", writes: [rd(word)]) }
        if word & 0xFFC0_0000 == 0x9100_0000 { return add("add", writes: [rd(word)]) }
        if word & 0xFFC0_0000 == 0xF940_0000 { return add("ldr", writes: [rd(word)], base: rn(word)) }
        if word & 0xFFC0_0000 == 0xF900_0000 { return add("str", writes: [], base: rn(word), isStore: true) }
        // ldr d, [x, #imm]: an FP destination. The audit tracks GPRs only — d0-d7 are
        // caller-saved across every call (AAPCS), and the store/state-page rules are about
        // memory bases, which this check still enforces.
        if word & 0xFFC0_0000 == 0xFD40_0000 { return add("ldr d", writes: [], base: rn(word)) }
        if word & 0xFFC0_0000 == 0xFD00_0000 { return add("str d", writes: [], base: rn(word), isStore: true) }
        // fadd d,d,d: FP-only, caller-saved, no memory base (the wake timer's fire date).
        if word & 0x7FC0_FC00 == 0x1E40_2800 { return add("fadd d", writes: []) }
        if word & 0xFFC0_0000 == 0xB940_0000 { return add("ldr w", writes: [rd(word)], base: rn(word)) }
        if word & 0xFFC0_0000 == 0xB900_0000 { return add("str w", writes: [], base: rn(word), isStore: true) }
        if word & 0xFFC0_0000 == 0x3940_0000 { return add("ldrb", writes: [rd(word)], base: rn(word)) }
        if word & 0xFFC0_0000 == 0x3900_0000 { return add("strb", writes: [], base: rn(word), isStore: true) }
        // stp/ldp signed offset, 64-bit: bits 31-30 = 10, 29-27 = 010/011, 26 = 1.
        if word & 0x3FC0_0000 == 0x2900_0000 { return add("stp", base: rn(word), isStore: true) }
        if word & 0x3FC0_0000 == 0x2940_0000 {
            return add("ldp", writes: [Int(word & 0x1F), Int((word >> 10) & 0x1F)], base: rn(word))
        }
        return nil
    }

    private func audit(_ words: ArraySlice<UInt32>, label: String, storeBases: Set<Int>, loadBases: Set<Int>) {
        var sp = 0
        var pairSaved = false
        for (index, word) in words.enumerated() {
            // The frame pair, once saved, may be rewritten: the frame-pointer setup and the
            // ldp that restores it are the function's own business (the callee-saved promise is
            // to the caller, and the save came first).
            if (word & 0x3FC0_0000) == 0x2900_0000, word & 0x1F == 29, (word >> 10) & 0x1F == 30 {
                pairSaved = true
            }
            guard let decoded = decode(word) else {
                let at = (index + words.startIndex) * 4
                return XCTFail("at \(label)+\(at): word 0x" + String(word, radix: 16) +
                    " is not an instruction the audit knows")
            }
            for register in decoded.writes {
                // The block prologue gave libdispatch back x19-x28; the entry and callback
                // promise the same. x29/x30 come back only through the ldp that pairs with the
                // stp that saved them. x18 belongs to the platform (Apple reserves it).
                if register == 18 {
                    XCTFail("at \(label)+\(index * 4): \(decoded.name) writes x18")
                }
                if (19...28).contains(register) {
                    XCTFail("at \(label)+\(index * 4): \(decoded.name) writes callee-saved x\(register)")
                }
                if (29...30).contains(register), !pairSaved {
                    XCTFail("at \(label)+\(index * 4): \(decoded.name) writes x\(register) before the save pair")
                }
            }
            if let base = decoded.base {
                if decoded.isStore, !storeBases.contains(base) {
                    XCTFail("at \(label)+\(index * 4): store through x\(base)")
                }
                if !decoded.isStore, !loadBases.contains(base) {
                    XCTFail("at \(label)+\(index * 4): load through x\(base)")
                }
            }
            sp += decoded.spDelta
            if decoded.isCall {
                XCTAssertEqual(sp % 16, 0, "\(label)+\(index * 4): call with SP misaligned (\(sp))")
            }
            if decoded.terminates {
                XCTAssertEqual(sp, 0, "\(label)+\(index * 4): \(label) does not balance its stack (\(sp))")
            }
        }
    }

    /// The whole code page, both functions: stores land on the stack (sp), the state page (x17),
    /// or the itoa digits cursors (x4/x8 — cursors over the state page, checked to exist by the
    /// next test); loads read the state (x17), the self-pointer (x0 through the table), the RX
    /// strings (x1), the borrowed message (x1), and the scan cursors (x5/x9). No store reads
    /// through the code page, and the decode knows every instruction the builders emit.
    func testCodeAudit() {
        let built = AgentBlob.build(pid: 1)
        audit(built.code[0..<built.entryWordCount], label: "entry",
              storeBases: [31, 17, 2, 4, 8], loadBases: [0, 1, 5, 9, 16, 17, 31])
        // The op path adds x2/x3: the row cursor and the captured-originals base (frame and
        // state keep their usual roles; x16 stays for the kCFRunLoopDefaultMode dereference).
        audit(built.code[built.cbOff / 4..<built.cbOff / 4 + built.cbWordCount], label: "callback",
              storeBases: [31, 17, 2, 3], loadBases: [0, 1, 2, 3, 9, 16, 17, 31])
        // The wake timer entry (P1c): stores land on the frame and the state page only;
        // loads come from the frame, state, and the mode-pointer dereference (x16).
        audit(built.code[built.timerOff / 4..<built.timerOff / 4 + built.timerWordCount],
              label: "timer", storeBases: [31, 17], loadBases: [31, 17, 16])
        // The teardown subroutine (P1d/P1e/P1f): stores land on the frame (31 — state base and the
        // P1f restore-loop index); loads come from the frame, the state page (x17), and the
        // override-class table cursor (x2). (It also restores the setHasShadow: override.)
        audit(built.code[built.teardownOff / 4..<built.teardownOff / 4 + built.teardownWordCount],
              label: "teardown", storeBases: [31], loadBases: [31, 17, 2])
        // The border observer (P1e/P1f): stores land on the frame (31), the state page (x17 — depth
        // counter and the override-class table count), the row cursor (x2 — the ensured flag bit),
        // and the class-table cursor (x3); loads come from the frame, the state page, the row cursor,
        // and the class-table cursor.
        audit(built.code[built.observerOff / 4..<built.observerOff / 4 + built.observerWordCount],
              label: "observer", storeBases: [31, 17, 2, 3], loadBases: [31, 17, 2, 3])
        // The setHasShadow: override IMP (P1f): a leaf that stores nothing and tail-calls (no ret);
        // loads come from the op-table row cursor (x10) and the state page (x17).
        audit(built.code[built.shadowImpOff / 4..<built.shadowImpOff / 4 + built.shadowImpWordCount],
              label: "shadowImp", storeBases: [], loadBases: [10, 17])
    }

    /// The observer is the real regression re-removal, not a stub: it reads the `hasShadow` gate
    /// (iTerm re-enables the shadow when it redraws the border — the self-clearing regression
    /// signal) and re-applies via the decoration and shadow setters. A stub would load no selector
    /// and call nothing.
    func testObserverGatesOnShadowAndReapplies() {
        let built = AgentBlob.build(pid: 11)
        let words = built.code[built.observerOff / 4..<built.observerOff / 4 + built.observerWordCount]
        var gatesOnShadow = false, setsDecoration = false, setsShadow = false
        var calls = 0
        for word in words {
            if word == Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selHasShadowSlot) { gatesOnShadow = true }
            if word == Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selDecoSlot) { setsDecoration = true }
            if word == Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selShadowSlot) { setsShadow = true }
            if decode(word)?.isCall == true { calls += 1 }
        }
        XCTAssertTrue(gatesOnShadow, "the observer gates on the hasShadow regression signal")
        XCTAssertTrue(setsDecoration, "the observer re-applies setDrawsDecorationView:")
        XCTAssertTrue(setsShadow, "the observer re-applies setHasShadow:")
        XCTAssertGreaterThanOrEqual(calls, 4, "the observer resolves app/window/titlebar + gate + setters via msgSend")
    }

    /// The digits cursor stores live in the entry (`strb …, [x4, #8]`, `strb …, [x8]`); they are
    /// cursors over the state page. The entry audit above admits the state base directly; this
    /// pins the cursor stores' existence — the audit would pass a build that never wrote them.
    func testAuditSeesTheDigitStores() {
        let built = AgentBlob.build(pid: 99)
        let words = built.code[0..<built.cbOff / 4]
        var sawCursorStore = false
        for word in words where decode(word)?.name == "strb" {
            if let base = decode(word)?.base, base == 4 || base == 8 { sawCursorStore = true }
        }
        XCTAssertTrue(sawCursorStore, "the itoa/rev loops store through their cursors")
    }

    func testBlobEntryScriptPlans() throws {
        guard let addresses = AddressTable.current() else { throw XCTSkip("no addresses") }
        let script = RemoteScript.blobEntry(state: 0x1000, entry: 0x2000)
        let handback = ThreadHandback(registers: Array(repeating: 0, count: 31), sp: 0, pc: 0)
        let bytes = Trampoline.scratchBytes(script, addresses: addresses, handback: handback,
                                            dispatch: Trampoline.DispatchContext(codeBase: 0, flagAddress: 0,
                                                                                 resultAddress: 0))
        XCTAssertGreaterThan(bytes, 0)
        let code = Trampoline.code(script, addresses: addresses, handback: handback,
                                   dispatch: Trampoline.DispatchContext(codeBase: 0x8000, flagAddress: 0x100,
                                                                        resultAddress: 0x108))
        // The blob body is three ops (state load, entry load, call); the entry address reaches
        // x16 from the data, so no movImm64 chain appears in the stub — the selector sequence
        // was skipped.
        XCTAssertFalse(code.isEmpty)
    }
}
