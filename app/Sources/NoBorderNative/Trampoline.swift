import Foundation

/// arm64 instruction encoders used by `Trampoline`, and nothing else. The encodings are checked
/// against the system assembler in TrampolineTests.
public enum Arc64 {
    public static func adr(dst: Int, immediate: Int) -> UInt32 {
        let immlo = UInt32(immediate & 0x3)
        let imm19 = UInt32((immediate >> 2) & 0x7_FFFF)
        return (immlo << 29) | (0x10_0000_00 as UInt32) | (imm19 << 5) | UInt32(dst & 0x1F)
    }

    /// ldr x<d>, [x<b>, #<offset>]  (offset must be a multiple of 8)
    public static func ldr(dst: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset % 8 == 0 && offset >= 0 && offset < 64 * 1024, "ldr x\(dst), [x\(base), #\(offset)]")
        return 0xF940_0000 | (UInt32(offset >> 3) << 10) | (UInt32(base & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// ldr d<d>, [x<b>, #<offset>]  (loads raw bits into a SIMD&FP register)
    public static func ldrd(dst: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset % 8 == 0 && offset >= 0 && offset < 32 * 1024, "ldr d\(dst), [x\(base), #\(offset)]")
        return 0xFD40_0000 | (UInt32(offset >> 3) << 10) | (UInt32(base & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// str d.. (SIMD64, unsigned 8-scaled offset) — the store pair of `ldrd` (the blob captures
    /// a captured `cornerRadius` double with it).
    public static func strd(src: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset % 8 == 0 && offset >= 0 && offset < 32 * 1024, "str d\(src), [x\(base), #\(offset)]")
        return 0xFD00_0000 | (UInt32(offset >> 3) << 10) | (UInt32(base & 0x1F) << 5) | UInt32(src & 0x1F)
    }

    /// fadd d<d>, d<n>, d<m> — the wake timer's fire date (CFAbsoluteTimeGetCurrent + delay).
    public static func faddD(dst: Int, lhs: Int, rhs: Int) -> UInt32 {
        0x1E60_2800 | (UInt32(rhs & 0x1F) << 16) | (UInt32(lhs & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    public static func movz(dst: Int, value: UInt16) -> UInt32 {
        0x5280_0000 | (UInt32(value) << 5) | UInt32(dst & 0x1F)
    }

    public static func movReg(dst: Int, src: Int) -> UInt32 {
        0xAA00_03E0 | (UInt32(src & 0x1F) << 16) | UInt32(dst & 0x1F)
    }

    public static func blr(_ register: Int) -> UInt32 {
        0xD63F_0000 | (UInt32(register & 0x1F) << 5)
    }

    /// Branch to an address held in a register — how the generated code leaves for the app's own.
    public static func br(_ register: Int) -> UInt32 {
        0xD61F_0000 | (UInt32(register & 0x1F) << 5)
    }

    /// str xzr, [x<b>, #<offset>] — writing zero, which is how the script marks itself finished.
    public static func strZero(base: Int, offset: Int) -> UInt32 {
        precondition(offset % 8 == 0 && offset >= 0 && offset < 64 * 1024)
        return 0xF900_0000 | (UInt32(offset >> 3) << 10) | (UInt32(base & 0x1F) << 5) | 31
    }

    /// str x<s>, [x<b>, #<offset>] — the one way a script hands a value back to us; the AppKit
    /// probe writes the app object it found.
    public static func str(src: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset % 8 == 0 && offset >= 0 && offset < 64 * 1024)
        return 0xF900_0000 | (UInt32(offset >> 3) << 10) | (UInt32(base & 0x1F) << 5) | UInt32(src & 0x1F)
    }

    /// mov sp, x<r> — the app's stack pointer, put back before we jump to its code.
    public static func movSp(from register: Int) -> UInt32 {
        0x9100_0000 | (UInt32(register & 0x1F) << 5) | 31
    }

    /// mov w<d>, w<s> — the 32-bit register move. Writing a w register zero-extends into x, which
    /// is what normalizes a BOOL arriving in x0, where the ABI leaves the upper bits saying nothing.
    public static func movReg32(dst: Int, src: Int) -> UInt32 {
        0x2A00_03E0 | (UInt32(src & 0x1F) << 16) | UInt32(dst & 0x1F)
    }

    /// orr w<d>, w<n>, w<m> — the 32-bit form, for 0/1 values read off BOOLs.
    public static func orr32(dst: Int, lhs: Int, rhs: Int) -> UInt32 {
        0x2A00_0000 | (UInt32(rhs & 0x1F) << 16) | (UInt32(lhs & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// lsl w<d>, w<s>, #<amount> — in the shifted-register form `orr wzr, w<s>, lsl #n`, which
    /// computes the same thing; the modern `lsl` mnemonic assembles to a UBFM, a different
    /// encoding of the same operation, and the cross-check compares encodings.
    public static func lsl32(dst: Int, src: Int, amount: Int) -> UInt32 {
        precondition(amount >= 0 && amount < 32, "lsl32 #\(amount)")
        return 0x2A00_0000 | (UInt32(amount) << 10) | (UInt32(src & 0x1F) << 16) | (31 << 5) | UInt32(dst & 0x1F)
    }

    /// sub x<d>, x<s>, #<imm> — the plain 12-bit immediate, in bytes. The dispatched block's
    /// prologue shrinks the stack with it and its base setup steps the block pointer back to
    /// the data, whose offset from the block is a multiple of 8.
    public static func subImm(dst: Int, src: Int, imm: Int) -> UInt32 {
        precondition(imm >= 0 && imm < 4096 && imm % 8 == 0, "subImm #\(imm)")
        return 0xD100_0000 | (UInt32(imm) << 10) | (UInt32(src & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// add x<d>, x<s>, #<imm> — the prologue's counterpart in the epilogue.
    public static func addImm(dst: Int, src: Int, imm: Int) -> UInt32 {
        precondition(imm >= 0 && imm < 4096 && imm % 8 == 0, "addImm #\(imm)")
        return 0x9100_0000 | (UInt32(imm) << 10) | (UInt32(src & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// stp x<a>, x<b>, [x<s>, #<offset>] — signed-offset form, offset a multiple of 8.
    public static func stp(dst: Int, dst2: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset % 8 == 0 && offset >= -512 && offset <= 504, "stp #\(offset)")
        let imm7 = UInt32((offset >> 3) & 0x7F)
        return 0xA900_0000 | (imm7 << 15) | (UInt32(dst2 & 0x1F) << 10) | (UInt32(base & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// ldp x<a>, x<b>, [x<s>, #<offset>] — signed-offset form.
    public static func ldp(dst: Int, dst2: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset % 8 == 0 && offset >= -512 && offset <= 504, "ldp #\(offset)")
        let imm7 = UInt32((offset >> 3) & 0x7F)
        return 0xA940_0000 | (imm7 << 15) | (UInt32(dst2 & 0x1F) << 10) | (UInt32(base & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// ret — how the dispatched block returns to libdispatch, on the link register it was called with.
    public static func ret() -> UInt32 { 0xD65F_03C0 }

    /// `svc #0x80` — the `mach_msg2_trap` system call (encoding cross-checked against the system
    /// assembler 2026-10-20: `svc #0x80` assembles to d4001001).
    public static func svcMachMsg2() -> UInt32 { 0xD400_1001 }

    // The agent blob's additions (cross-checked against the system assembler in AgentBlobTests).

    /// movk x<d>, #<value>, lsl #<shift> — the upper halves of a 64-bit immediate; `movz64`
    /// starts it. The hw field is the shift: base 0xF2800000 (cross-checked against the system
    /// assembler 2026-10-20: the four shifts assemble to f280…, f2b2…, f2ca…, f2e2…).
    public static func movk(dst: Int, value: UInt16, shift: Int) -> UInt32 {
        precondition(shift % 16 == 0 && shift < 64, "movk shift #\(shift)")
        return 0xF280_0000 | (UInt32(shift / 16) << 21) | (UInt32(value) << 5) | UInt32(dst & 0x1F)
    }

    /// The full 64-bit immediate: a 64-bit movz + three movk (the w-form movz would zero the
    /// upper halves the movks are about to write).
    public static func movImm64(dst: Int, value: UInt64) -> [UInt32] {
        [movz64(dst: dst, value: UInt16(truncatingIfNeeded: value)),
         movk(dst: dst, value: UInt16(truncatingIfNeeded: value >> 16), shift: 16),
         movk(dst: dst, value: UInt16(truncatingIfNeeded: value >> 32), shift: 32),
         movk(dst: dst, value: UInt16(truncatingIfNeeded: value >> 48), shift: 48)]
    }

    /// ldr w<d>, [x<b>, #<offset>] — 32-bit load (offset a multiple of 4, < 32 KiB).
    public static func ldr32(dst: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset % 4 == 0 && offset >= 0 && offset < 32 * 1024, "ldr w\(dst), [x\(base), #\(offset)]")
        return 0xB940_0000 | (UInt32(offset >> 2) << 10) | (UInt32(base & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// str w<s>, [x<b>, #<offset>] — 32-bit store.
    public static func str32(src: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset % 4 == 0 && offset >= 0 && offset < 32 * 1024, "str w\(src), [x\(base), #\(offset)]")
        return 0xB900_0000 | (UInt32(offset >> 2) << 10) | (UInt32(base & 0x1F) << 5) | UInt32(src & 0x1F)
    }

    /// ldrb <d>, [x<b>, #<offset>] / strb <s>, [x<b>, #<offset>] — unsigned-offset byte moves.
    public static func ldrb(dst: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset < 4096, "ldrb #\(offset)")
        return 0x3940_0000 | (UInt32(offset) << 10) | (UInt32(base & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    public static func strb(src: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset < 4096, "strb #\(offset)")
        return 0x3900_0000 | (UInt32(offset) << 10) | (UInt32(base & 0x1F) << 5) | UInt32(src & 0x1F)
    }

    /// add x<d>, x<s>, #<imm> — any 12-bit immediate, not only the 8-aligned ones `addImm` takes:
    /// the blob's byte cursors step by one.
    public static func addImmBytes(dst: Int, src: Int, imm: Int) -> UInt32 {
        precondition(imm >= 0 && imm < 4096, "add #\(imm)")
        return 0x9100_0000 | (UInt32(imm) << 10) | (UInt32(src & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// sub x<d>, x<s>, #<imm> — any 12-bit immediate; the counterpart of `addImmBytes`.
    public static func subImmBytes(dst: Int, src: Int, imm: Int) -> UInt32 {
        precondition(imm >= 0 && imm < 4096, "sub #\(imm)")
        return 0xD100_0000 | (UInt32(imm) << 10) | (UInt32(src & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// cmp x<s>, #<imm> — subs XZR, x<s>, #<imm>; pairs with `bCond`.
    public static func cmpImm(src: Int, imm: Int) -> UInt32 {
        precondition(imm >= 0 && imm < 4096, "cmp #\(imm)")
        return 0xF100_0000 | (UInt32(imm) << 10) | (UInt32(src & 0x1F) << 5) | 31
    }

    /// b.<cond> #<label-in-bytes-from-this-word>. cond: 0 eq, 1 ne, 2 hs/cs, 3 lo/cc, 8 hi,
    /// 9 ls, 10 ge, 11 lt.
    public static func bCond(_ cond: Int, immediate: Int) -> UInt32 {
        precondition(cond >= 0 && cond < 16, "cond #\(cond)")
        let imm19 = UInt32((immediate >> 2) & 0x7_FFFF)
        return 0x5400_0000 | (imm19 << 5) | UInt32(cond)
    }

    /// cbz x<s> / cbnz x<s>, #<label-in-bytes-from-this-word> — the compare-and-branch loop
    /// heads. op is bit 30 (cross-checked 2026-10-20: `cbz x16, .` is b4000010, `cbnz x3, .`
    /// is b5000003).
    public static func cbz(src: Int, immediate: Int, nonzero: Bool = false) -> UInt32 {
        let imm19 = UInt32((immediate >> 2) & 0x7_FFFF)
        return (nonzero ? 0xB500_0000 : 0xB400_0000) | (imm19 << 5) | UInt32(src & 0x1F)
    }

    /// b #<label-in-bytes-from-this-word> — the unconditional branch (imm26). The mask is the
    /// 26-bit field itself: a backward branch is negative, and a wider mask leaves a value no
    /// UInt32 can hold (measured 2026-10-21: the first backward `b` trapped the conversion).
    public static func b(immediate: Int) -> UInt32 {
        0x1400_0000 | (UInt32((immediate >> 2) & 0x3F_F_FFFF))
    }

    /// sub x<d>, x<n>, x<m> — the plain register subtract.
    public static func subReg(dst: Int, lhs: Int, rhs: Int) -> UInt32 {
        0xCB00_0000 | (UInt32(rhs & 0x1F) << 16) | (UInt32(lhs & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// cmp x<n>, x<m> — subs XZR, x<n>, x<m>; pairs with `bCond`.
    public static func cmpReg(lhs: Int, rhs: Int) -> UInt32 {
        0xEB00_0000 | (UInt32(rhs & 0x1F) << 16) | (UInt32(lhs & 0x1F) << 5) | 31
    }

    /// movz x<d>, #<value> — the 64-bit form (the `movz` above writes the 32-bit one, which is
    /// what the selector sequences need; the encoding is cross-checked against the system
    /// assembler 2026-10-20: `movz x7, #0xcdef` is d299bde7).
    public static func movz64(dst: Int, value: UInt16) -> UInt32 {
        0xD280_0000 | (UInt32(value) << 5) | UInt32(dst & 0x1F)
    }

    /// udiv x<d>, x<n>, x<m> — the itoa loop's division (no zero-divide trap: result 0;
    /// cross-checked 2026-10-20: `udiv x5, x3, x16` is 9ad00865).
    public static func udiv(dst: Int, lhs: Int, rhs: Int) -> UInt32 {
        0x9AC0_0800 | (UInt32(rhs & 0x1F) << 16) | (UInt32(lhs & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// madd x<d>, x<n>, x<m>, x<a> — the itoa loop's multiply-accumulate. The addend field
    /// encodes the SP-register file: 31 is SP, never the zero register (measured 2026-10-20:
    /// an addend of 31 added SP to the product and the pid digits came out garbage). For a plain
    /// product use `mul`.
    public static func madd(dst: Int, lhs: Int, rhs: Int, addend: Int) -> UInt32 {
        0x9B00_0000 | (UInt32(rhs & 0x1F) << 16) | (UInt32(addend & 0x1F) << 10)
            | (UInt32(lhs & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// mul x<d>, x<n>, x<m> — MADD with the zero register as the addend (cross-checked 2026-10-20
    /// against the system assembler: `mul x6, x5, x16` is 9b107ca6).
    public static func mul(dst: Int, lhs: Int, rhs: Int) -> UInt32 {
        0x9B00_7C00 | (UInt32(rhs & 0x1F) << 16) | (UInt32(lhs & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// add x<d>, x<n>, x<m> — the plain register add.
    public static func addReg(dst: Int, lhs: Int, rhs: Int) -> UInt32 {
        0x8B00_0000 | (UInt32(rhs & 0x1F) << 16) | (UInt32(lhs & 0x1F) << 5) | UInt32(dst & 0x1F)
    }
}

/// Generates the code that runs inside the target app and the data it reads.
///
/// The code is straight-line: it looks up the app object with `+[NSApplication sharedApplication]`
/// (the `_NSApp` global is not a symbol we can reach from outside), resolves each selector it
/// needs once, then for each window number looks the window up and sends the requested messages.
/// Sending to a nil window or a nil titlebar view is a no-op in Objective-C, so there is nothing
/// to branch on. It ends by writing a completion flag, putting the app's registers, stack pointer
/// and instruction pointer back from the data, and jumping to that address: the app takes its own
/// thread back, in one branch, instead of waiting for us to stop it and write its state again.
///
/// Values that must survive the AppKit calls are kept in callee-saved registers; x16/x17 are the
/// ABI's intra-procedural temporaries and objc_msgSend clobbers them — and x17 is the register the
/// final jump is made from, so it is the one app register that is not restored.
public enum Trampoline {
    static let blobRegister = 19
    static let msgSendRegister = 20
    static let appRegister = 21
    static let windowRegister = 27
    /// One register per selector, kept live across the whole window loop. x27 is the window, so it is
    /// skipped; x28/x29 are callee-saved and the handback restores them.
    static let selectorRegisters = [22, 23, 24, 25, 26, 28, 29]
    static let selLookupRegister = 16          // used only between loads and a lookup call
    static let classLookupRegister = 17

    /// The register the generated code jumps back to the app from. x17 is scratch in the ABI and
    /// holds nothing the app wants back, so it is free to use for the jump.
    public static let handbackRegister = 17

    /// When every call has returned, the script writes zero at this offset from the stack pointer it
    /// was given. The caller polls that word instead of touching the thread again.
    public static let completionFlagOffset = 8

    /// The word a probe script writes: the value it was asked to look up. It is written while the
    /// script is still running, so it is only trustworthy once the completion flag says it is done —
    /// which is why the executor marks both words before every run.
    public static let resultOffset = 16

    static let applicationClass = "NSApplication"
    static let sharedApplicationSelector = "sharedApplication"
    static let lookupSelector = "windowWithWindowNumber:"
    static let hasShadowSelector = "setHasShadow:"
    static let cornerRadiusSelector = "_setCornerRadius:"
    static let titlebarSelector = "_titlebarContainerView"
    static let decorationSelector = "setDrawsDecorationView:"
    static let standardButtonSelector = "standardWindowButton:"
    static let setHiddenSelector = "setHidden:"
    /// The key state read's getter: the app's own answer about a window.
    static let isKeyWindowGetter = "isKeyWindow"
    /// The NSWindowButton values: close, miniaturize, zoom.
    static let buttonTypes: [UInt16] = [0, 1, 2]

    /// The key state read packs its answer bit by bit: this accumulator keeps them, and this one
    /// callee-saved temporary normalizes the BOOL. Both are callee-saved and the handback
    /// restores every register the app had, so neither needs saving here.
    static let readAccumulatorRegister = 26
    static let readTempRegister = 28

    /// Where the data goes: just after the code, on an 8-byte boundary, because every read of it
    /// is an 8-byte load from the base register. The executor writes the data here and the code
    /// below is generated against the same offset; only this function may say where it is.
    public static func dataOffset(codeWordCount: Int) -> Int {
        ((4 * codeWordCount) + 7) / 8 * 8
    }

    private struct Blob {
        var bytes: [UInt8] = []
        var windowsOffset = 24
        var msgSend: Int { 0 }
        var selRegisterName: Int { 8 }
        var objcGetClass: Int { 16 }
        var firstWindowNumber: Int { windowsOffset }

        mutating func appendWord(_ value: UInt64) {
            var word = value
            for _ in 0..<8 { bytes.append(UInt8(word & 0xff)); word >>= 8 }
        }


        mutating func appendString(_ text: String) -> Int {
            let at = bytes.count
            bytes.append(contentsOf: Array(text.utf8))
            bytes.append(0)
            return at
        }

        /// Names are variable length, so anything loaded as a word after them has to be brought
        /// back onto an 8-byte boundary first: an arm64 `ldr` faults on an address it cannot encode.
        mutating func alignToWord() {
            while bytes.count % 8 != 0 { bytes.append(0) }
        }
    }

    private enum Op {
        case adrBlobBase(dst: Int)
        case adrBlob(dst: Int, offset: Int)
        case loadFromBlob(dst: Int, blobOffset: Int)
        case loadDoubleFromBlob(dst: Int, blobOffset: Int)
        case movImm(dst: Int, value: UInt16)
        case move(dst: Int, src: Int)
        case move32(dst: Int, src: Int)
        case orr32(dst: Int, lhs: Int, rhs: Int)
        case lsl32(dst: Int, src: Int, amount: Int)
        case call(reg: Int)
        case storeCompletionFlag
        case storeResult(from: Int)
        case moveStackPointer(from: Int)
        case branch(to: Int)
        // the dispatched mode's: a C-function prologue/epilogue and stores through a register
        case subStack(imm: Int)
        case addStack(imm: Int)
        case savePair(Int, Int, offset: Int)
        case loadPair(Int, Int, offset: Int)
        case ret
        case loadFromPointer(dst: Int, src: Int, offset: Int)
        case subReg(dst: Int, src: Int, imm: Int)
        case storeIndirect(src: Int, base: Int, offset: Int)
        case svc
    }

    /// The facts only the executor knows, for the dispatched mode: where the code will be mapped
    /// (the block's `invoke` field names it in absolute terms), the absolute addresses of the two
    /// words the block writes (its stack is the app's real one, so the frame-relative `sp + 8` of
    /// the fabricated frame reads nothing there), and the absorber's receive port.
    public struct DispatchContext: Equatable {
        public var codeBase: UInt64
        public var flagAddress: UInt64
        public var resultAddress: UInt64
        /// The absorber trap's receive port: a send right the executor inserts into the target.
        /// Zero = no absorber port (the trap then answers `MACH_RCV_INVALID_NAME` and consumes
        /// nothing). A receive on `MACH_PORT_NULL` is not guarded, but a *send* on it raises
        /// `EXC_GUARD` on this OS (measured 2026-10-20: codes [0x0, 0x1] at the stub's pc) — the
        /// absorber must receive on a valid right.
        public var absorbPort: UInt64
        public init(codeBase: UInt64, flagAddress: UInt64, resultAddress: UInt64, absorbPort: UInt64 = 0) {
            self.codeBase = codeBase
            self.flagAddress = flagAddress
            self.resultAddress = resultAddress
            self.absorbPort = absorbPort
        }
    }

    /// The selectors this script needs, in the order they are resolved into registers.
    private static func selectors(_ script: RemoteScript) -> [String] {
        if script.blobEntry != nil { return [] }   // the body is one call into the blob, not AppKit
        if script.appKitProbe { return [] }   // it sends one message, and its selector is listed apart
        if script.keyStateRead { return [lookupSelector, isKeyWindowGetter] }
        var names = [lookupSelector]
        if script.hasShadow != nil { names.append(hasShadowSelector) }
        if script.cornerRadius != nil { names.append(cornerRadiusSelector) }
        if script.drawsDecoration != nil { names += [titlebarSelector, decorationSelector] }
        if script.hideButtons != nil { names += [standardButtonSelector, setHiddenSelector] }
        return names
    }

    public static func code(_ script: RemoteScript, addresses: AddressTable, handback: ThreadHandback,
                            dispatch: DispatchContext? = nil) -> [UInt32] {
        let (ops, _) = plan(script, addresses: addresses, handback: handback, dispatch: dispatch)
        // Every op is exactly one word, so this is the size of the code the loop below emits.
        let dataAt = dataOffset(codeWordCount: ops.count)
        var words: [UInt32] = []
        for (index, op) in ops.enumerated() {
            switch op {
            case .adrBlobBase(let dst):
                words.append(Arc64.adr(dst: dst, immediate: dataAt - 4 * index))
            case .adrBlob(let dst, let offset):
                words.append(Arc64.adr(dst: dst, immediate: dataAt + offset - 4 * index))
            case .loadFromBlob(let dst, let offset):
                words.append(Arc64.ldr(dst: dst, base: blobRegister, offset: offset))
            case .loadDoubleFromBlob(let dst, let offset):
                words.append(Arc64.ldrd(dst: dst, base: blobRegister, offset: offset))
            case .movImm(let dst, let value):
                words.append(Arc64.movz(dst: dst, value: value))
            case .move(let dst, let src):
                words.append(Arc64.movReg(dst: dst, src: src))
            case .move32(let dst, let src):
                words.append(Arc64.movReg32(dst: dst, src: src))
            case .orr32(let dst, let lhs, let rhs):
                words.append(Arc64.orr32(dst: dst, lhs: lhs, rhs: rhs))
            case .lsl32(let dst, let src, let amount):
                words.append(Arc64.lsl32(dst: dst, src: src, amount: amount))
            case .call(let reg):
                words.append(Arc64.blr(reg))
            case .storeCompletionFlag:
                words.append(Arc64.strZero(base: 31, offset: completionFlagOffset))
            case .storeResult(let src):
                words.append(Arc64.str(src: src, base: 31, offset: resultOffset))
            case .moveStackPointer(let from):
                words.append(Arc64.movSp(from: from))
            case .branch(let register):
                words.append(Arc64.br(register))
            case .subStack(let imm):
                words.append(Arc64.subImm(dst: 31, src: 31, imm: imm))
            case .addStack(let imm):
                words.append(Arc64.addImm(dst: 31, src: 31, imm: imm))
            case .savePair(let a, let b, let offset):
                words.append(Arc64.stp(dst: a, dst2: b, base: 31, offset: offset))
            case .loadPair(let a, let b, let offset):
                words.append(Arc64.ldp(dst: a, dst2: b, base: 31, offset: offset))
            case .ret:
                words.append(Arc64.ret())
            case .loadFromPointer(let dst, let src, let offset):
                words.append(Arc64.ldr(dst: dst, base: src, offset: offset))
            case .subReg(let dst, let src, let imm):
                words.append(Arc64.subImm(dst: dst, src: src, imm: imm))
            case .storeIndirect(let src, let base, let offset):
                words.append(Arc64.str(src: src, base: base, offset: offset))
            case .svc:
                words.append(Arc64.svcMachMsg2())
            }
        }
        return words
    }

    public static func data(_ script: RemoteScript, addresses: AddressTable, handback: ThreadHandback,
                            dispatch: DispatchContext? = nil) -> [UInt8] {
        plan(script, addresses: addresses, handback: handback, dispatch: dispatch).1.bytes
    }

    /// Where a faulted dispatched block is resumed: its epilogue — the `ldp`/`add sp`/`ret` that
    /// returns it to libdispatch with the callee-saved registers it saved on entry. A fault inside
    /// the block is a fault in the app's own dispatch/CF machinery; restoring the parked run-loop
    /// state around it leaves the queue drain half-finished and kills the app (measured
    /// 2026-10-20: survive-the-fault engine.sh section died). The epilogue is the last eight ops
    /// of the block's code.
    public static func dispatchedResumeCode(_ script: RemoteScript, addresses: AddressTable,
                                            handback: ThreadHandback, codeBase: UInt64) -> UInt64 {
        let (ops, _) = plan(script, addresses: addresses, handback: handback,
                            dispatch: DispatchContext(codeBase: codeBase, flagAddress: 0, resultAddress: 0))
        precondition(ops.count >= 8)
        return codeBase &+ UInt64(4 * (ops.count - 8))
    }

    /// Bytes the executor needs in the code region for one run: the code and the data after it.
    /// The size does not depend on `codeBase` (it only fills a word), so a context with a
    /// placeholder address answers the sizing question before the region is allocated.
    public static func scratchBytes(_ script: RemoteScript, addresses: AddressTable, handback: ThreadHandback,
                                    dispatch: DispatchContext?) -> Int {
        let placeholder = dispatch.map { DispatchContext(codeBase: 0, flagAddress: $0.flagAddress,
                                                         resultAddress: $0.resultAddress) }
        let (ops, blob) = plan(script, addresses: addresses, handback: handback, dispatch: placeholder)
        return dataOffset(codeWordCount: ops.count) + blob.bytes.count
    }

    private static func plan(_ script: RemoteScript, addresses: AddressTable, handback: ThreadHandback,
                             dispatch: DispatchContext? = nil) -> ([Op], Blob) {
        if let dispatch { return dispatchedPlan(script, addresses: addresses, handback: handback, dispatch: dispatch) }
        var blob = Blob()
        blob.appendWord(addresses.msgSend)
        blob.appendWord(addresses.selRegisterName)
        blob.appendWord(addresses.objcGetClass)
        for number in script.windowNumbers { blob.appendWord(UInt64(number)) }
        let radiusOffset = blob.bytes.count
        if let radius = script.cornerRadius { blob.appendWord(radius.bitPattern) }

        let selectorNames = selectors(script)
        var strings: [String: Int] = [:]
        strings[applicationClass] = blob.appendString(applicationClass)
        strings[sharedApplicationSelector] = blob.appendString(sharedApplicationSelector)
        for name in selectorNames { strings[name] = blob.appendString(name) }

        var ops: [Op] = [.adrBlobBase(dst: blobRegister)]
        if script.forceFaultForTesting {
            // Before anything is applied: a test that wants a fault wants to see that the app is
            // unharmed *and* untouched, not just that it survived.
            ops = [.movImm(dst: 16, value: 1), .branch(to: 16)]   // an address no process has mapped
        }
        // The frame the script runs on is the one it was entered on, so the answer words sit at
        // fixed offsets from its sp — the executor's stack, where it polls them.
        let answerStore = { (from: Int) -> [Op] in [.storeResult(from: from)] }
        ops += scriptBody(script, blob: blob, strings: strings, radiusOffset: radiusOffset, answerStore: answerStore)
        // Hand the thread back to the app. The flag goes first: a caller that reads it knows every
        // call has returned. Then everything the calls may have clobbered, from the state that was
        // read before entering — including the instruction the app was about to run.
        ops.append(.storeCompletionFlag)
        let (handbackSlots, stackSlot, returnSlot) = appendHandback(into: &blob, handback: handback)
        ops += handbackOps(handbackSlots: handbackSlots, stackSlot: stackSlot, returnSlot: returnSlot)
        return (ops, blob)
    }

    /// The app-facing sequence, shared by both entries: look the application up, resolve the
    /// script's selectors, then per window send the messages. `answerStore` writes a value where
    /// the executor will find it — frame-relative in the fabricated frame, absolute in a block.
    private static func scriptBody(_ script: RemoteScript, blob: Blob, strings: [String: Int],
                                   radiusOffset: Int, answerStore: (Int) -> [Op]) -> [Op] {
        let selectorNames = selectors(script)
        var ops: [Op] = []
        // app = objc_getClass("NSApplication")
        ops.append(.loadFromBlob(dst: classLookupRegister, blobOffset: blob.objcGetClass))
        ops.append(.adrBlob(dst: 0, offset: strings[applicationClass]!))
        ops.append(.call(reg: classLookupRegister))
        ops.append(.move(dst: appRegister, src: 0))
        // app = [app sharedApplication]
        ops.append(.loadFromBlob(dst: msgSendRegister, blobOffset: blob.msgSend))
        ops.append(.loadFromBlob(dst: selLookupRegister, blobOffset: blob.selRegisterName))
        ops.append(.adrBlob(dst: 0, offset: strings[sharedApplicationSelector]!))
        ops.append(.call(reg: selLookupRegister))
        ops.append(.move(dst: 1, src: 0))
        ops.append(.move(dst: 0, src: appRegister))
        ops.append(.call(reg: msgSendRegister))
        ops.append(.move(dst: appRegister, src: 0))
        if script.appKitProbe {
            // The whole point of a probe script: hand back the application object, which is nil in a
            // process with no AppKit. Written before the completion flag, so a caller that read the
            // flag can trust it.
            ops += answerStore(appRegister)
        }
        // one selector lookup per message the script sends
        precondition(selectorNames.count <= selectorRegisters.count, "one selector register per selector")
        for (index, name) in selectorNames.enumerated() {
            ops.append(.loadFromBlob(dst: selLookupRegister, blobOffset: blob.selRegisterName))
            ops.append(.adrBlob(dst: 0, offset: strings[name]!))
            ops.append(.call(reg: selLookupRegister))
            ops.append(.move(dst: selectorRegisters[index], src: 0))
        }

        let selector = Dictionary(uniqueKeysWithValues: zip(selectorNames, selectorRegisters))
        let send = { (receiver: Int, name: String) -> [Op] in
            [.move(dst: 0, src: receiver), .move(dst: 1, src: selector[name]!)]
        }

        if script.keyStateRead {
            precondition(script.windowNumbers.count <= 32, "one answer bit per window")
            ops.append(.movImm(dst: Self.readAccumulatorRegister, value: 0))
        }

        for windowIndex in script.windowNumbers.indices {
            let numberOffset = blob.firstWindowNumber + 8 * windowIndex
            ops += send(appRegister, lookupSelector)
            ops.append(.loadFromBlob(dst: 2, blobOffset: numberOffset))
            ops.append(.call(reg: msgSendRegister))
            ops.append(.move(dst: windowRegister, src: 0))

            if script.keyStateRead {
                // The window's answer bit: the app has it key. The BOOL is normalized (writing w28
                // zeroes x28's upper bits) before it joins the accumulator.
                ops += send(windowRegister, isKeyWindowGetter)
                ops.append(.call(reg: msgSendRegister))
                ops.append(.move32(dst: Self.readTempRegister, src: 0))
                ops.append(.lsl32(dst: Self.readAccumulatorRegister, src: Self.readAccumulatorRegister, amount: 1))
                ops.append(.orr32(dst: Self.readAccumulatorRegister, lhs: Self.readAccumulatorRegister,
                                  rhs: Self.readTempRegister))
            }

            if let hasShadow = script.hasShadow {
                ops += send(windowRegister, hasShadowSelector)
                ops.append(.movImm(dst: 2, value: hasShadow ? 1 : 0))
                ops.append(.call(reg: msgSendRegister))
            }
            if script.cornerRadius != nil {
                ops += send(windowRegister, cornerRadiusSelector)
                ops.append(.loadDoubleFromBlob(dst: 0, blobOffset: radiusOffset))
                ops.append(.call(reg: msgSendRegister))
            }
            if let drawsDecoration = script.drawsDecoration {
                // The titlebar view arrives in x0 and is the receiver of the very next call, so it
                // needs no register of its own: x1 and x2 are set after the lookup returns.
                ops += send(windowRegister, titlebarSelector)
                ops.append(.call(reg: msgSendRegister))
                ops.append(.move(dst: 1, src: selector[decorationSelector]!))
                ops.append(.movImm(dst: 2, value: drawsDecoration ? 1 : 0))
                ops.append(.call(reg: msgSendRegister))
            }
            if let hideButtons = script.hideButtons {
                // Each button arrives in x0 and receives setHidden: straight away. Sending to a nil
                // button — a borderless window with none — is a no-op, as for every nil receiver.
                for button in buttonTypes {
                    ops += send(windowRegister, standardButtonSelector)
                    ops.append(.movImm(dst: 2, value: button))
                    ops.append(.call(reg: msgSendRegister))
                    ops.append(.move(dst: 1, src: selector[setHiddenSelector]!))
                    ops.append(.movImm(dst: 2, value: hideButtons ? 1 : 0))
                    ops.append(.call(reg: msgSendRegister))
                }
            }
        }
        if script.keyStateRead {
            // The packed answer, written while the script is still running: it is trustworthy once
            // the completion flag says it is done, same as the AppKit probe's word.
            ops += answerStore(Self.readAccumulatorRegister)
        }
        return ops
    }

    /// The register slots, stack pointer and return address the app's state is restored from.
    private static func appendHandback(into blob: inout Blob, handback: ThreadHandback)
        -> (slots: [Int: Int], stackSlot: Int, returnSlot: Int) {
        blob.alignToWord()
        var handbackSlots: [Int: Int] = [:]
        for register in 0..<31 where register != handbackRegister {
            handbackSlots[register] = blob.bytes.count
            blob.appendWord(handback.registers[register])
        }
        let stackSlot = blob.bytes.count
        blob.appendWord(handback.sp)
        let returnSlot = blob.bytes.count
        blob.appendWord(handback.pc)
        return (handbackSlots, stackSlot, returnSlot)
    }

    /// The ops of the handback: put every app register back from its slot, the stack pointer and
    /// the run-loop call's address through the jump register, and branch there.
    private static func handbackOps(handbackSlots: [Int: Int], stackSlot: Int, returnSlot: Int) -> [Op] {
        var ops: [Op] = []
        for register in 0..<31 where register != handbackRegister && register != blobRegister {
            ops.append(.loadFromBlob(dst: register, blobOffset: handbackSlots[register]!))
        }
        // The app's stack pointer comes back through the jump register, which is the one register
        // the app does not get back: it is scratch in the ABI and it holds the address we jump to.
        ops.append(.loadFromBlob(dst: handbackRegister, blobOffset: stackSlot))
        ops.append(.moveStackPointer(from: handbackRegister))
        ops.append(.loadFromBlob(dst: handbackRegister, blobOffset: returnSlot))
        // x19 is the base every one of those loads reads from, so it is put back last.
        ops.append(.loadFromBlob(dst: blobRegister, blobOffset: handbackSlots[blobRegister]!))
        ops.append(.branch(to: handbackRegister))
        return ops
    }

    /// The handback's instruction count, fixed by its shape — the dispatch stub needs it before
    /// the handback's slots exist, because the block's invoke address is the code right behind it:
    /// a load for each of the 29 registers (all of x0…x30 but the jump register and x19, the two
    /// that come back at the end) plus the sp, mov, pc, x19 and branch.
    private static let handbackWordCount = (31 - 2) + 5

    // MARK: the dispatched entry

    static let dispatchMainQueueOffset = 24
    static let dispatchAsyncOffset = 32
    static let flagAddressOffset = 40
    static let resultAddressOffset = 48
    /// `BLOCK_IS_GLOBAL` in <Block.h>: the bit `_Block_copy` and `_Block_release` test. With it,
    /// a copy is the pointer itself and a release is nothing — which is what makes queuing a
    /// literal in stable scratch legal. Without it (measured 2026-10-20) `_Block_copy` takes the
    /// stack path and dereferences the descriptor, faulting on its null.
    static let blockIsGlobal: UInt64 = 0x4000_0000
    /// The block's callee-saved frame: x19…x30, the registers the selector sequence keeps live,
    /// which libdispatch expects back. 96 bytes, 16-aligned as the ABI requires.
    static let calleeSavedFrame = 96

    /// The dispatched entry: the fabricated frame calls one function — `dispatch_async` with a
    /// global block whose invoke is the selector sequence — and hands the thread straight back.
    /// The AppKit work runs as a block on the app's main queue: a normal run-loop iteration, on
    /// the app's real stack, in healthy CF/AppKit state. The block writes the executor's two
    /// answer words by absolute address, because its stack is the app's and not the frame's.
    private static func dispatchedPlan(_ script: RemoteScript, addresses: AddressTable, handback: ThreadHandback,
                                       dispatch: DispatchContext) -> ([Op], Blob) {
        var blob = Blob(windowsOffset: 56)
        blob.appendWord(addresses.msgSend)
        blob.appendWord(addresses.selRegisterName)
        blob.appendWord(addresses.objcGetClass)
        blob.appendWord(addresses.dispatchMainQueue)
        blob.appendWord(addresses.dispatchAsync)
        blob.appendWord(dispatch.flagAddress)
        blob.appendWord(dispatch.resultAddress)
        for number in script.windowNumbers { blob.appendWord(UInt64(number)) }
        let radiusOffset = blob.bytes.count
        if let radius = script.cornerRadius { blob.appendWord(radius.bitPattern) }

        // A buffer for the stub's sacrificial mach call (see absorberOps), and its port and the
        // shim's address beside it.
        blob.alignToWord()
        let msgOffset = blob.bytes.count
        for _ in 0..<8 { blob.appendWord(0) }
        let absorbPortOffset = msgOffset + 64
        blob.appendWord(dispatch.absorbPort)
        blob.appendWord(addresses.machMsg)

        let selectorNames = selectors(script)
        var strings: [String: Int] = [:]
        strings[applicationClass] = blob.appendString(applicationClass)
        strings[sharedApplicationSelector] = blob.appendString(sharedApplicationSelector)
        for name in selectorNames { strings[name] = blob.appendString(name) }

        // The blob entry's two words, appended before the literal's offset is taken: the literal's
        // position is what the queueing passes to `dispatch_async`, and the first word that was
        // appended after the offset (the entry pointer) became the block `_Block_copy` saw — it
        // read the pointer as the flags word, took the copy path, and stored into the RX page
        // (measured 2026-10-20: the fault at `_Block_copy`+0xD8).
        var stateOffset = 0
        if let blobEntry = script.blobEntry {
            blob.alignToWord()
            stateOffset = blob.bytes.count
            blob.appendWord(blobEntry.state)
            blob.appendWord(blobEntry.entry)
        }
        var removeOffset = 0
        if let removeState = script.blobRemove {
            blob.alignToWord()
            removeOffset = blob.bytes.count
            blob.appendWord(removeState)
            blob.appendWord(addresses.cfmachPortInvalidate)
            blob.appendWord(addresses.cfmachPortRelease)
        }

        // The block literal, 8-aligned: isa names the global class (so Block_copy is a no-op and
        // dispatch queues the pointer as-is), invoke is the block code's absolute address. A plain
        // global literal has no descriptor, and dispatch_async never reads one; the struct outlives
        // the queueing because it lives in the scratch region, which is released only after the
        // completion flag — which the block itself writes.
        blob.alignToWord()
        let blockOffset = blob.bytes.count
        precondition(blockOffset % 8 == 0 && blockOffset < 4096, "the block base step is an encoded immediate")
        // Queueing the block is the stub's only side effect on the app's own machinery; a test
        // script suppresses it to isolate the entry machinery alone.
        let queueOps: [Op] = script.suppressBlockQueueForTesting ? [] :
            [.loadFromBlob(dst: 0, blobOffset: Self.dispatchMainQueueOffset),
             .adrBlob(dst: 1, offset: blockOffset),
             .loadFromBlob(dst: 16, blobOffset: Self.dispatchAsyncOffset),
             .call(reg: 16)]
        let stubWordCount = 1 + Self.absorberWordCount + queueOps.count + handbackWordCount

        // The block: a C function by ABI — callee-saved registers in and out, returns to
        // libdispatch. Its x0 is the block as dispatch queued it — and the main queue *copies* a
        // global block (it must set the async/free flags), so x0 is a heap copy, not the literal
        // (measured 2026-10-20: x0 = 0x6000…). The copy preserves the descriptor pointer, and the
        // descriptor lives in our data, so the base comes back through it: x19 = [x0, #24] − the
        // descriptor's offset in the data.
        var block: [Op] = [.subStack(imm: Self.calleeSavedFrame)]
        for pair in 0..<6 {
            block.append(.savePair(19 + 2 * pair, 20 + 2 * pair, offset: 16 * pair))
        }
        block.append(.loadFromPointer(dst: Self.blobRegister, src: 0, offset: 24))
        block.append(.subReg(dst: Self.blobRegister, src: Self.blobRegister, imm: blockOffset + 32))
        if script.forceFaultForTesting {
            // Inside the block, before anything is applied: the app is to be unharmed *and*
            // untouched, and in this entry the block is where the app work happens.
            block += [.movImm(dst: 16, value: 1), .branch(to: 16)]   // an address no process has mapped
        }
        if let blobEntry = script.blobEntry {
            // The blob's entry, called with its state address — the whole block body. The blob's
            // pages are the installer's, not this region's: nothing here reads or frees them, so
            // they survive the executor the way a resident agent must (verdict 6: resident
            // lifetime explicit). The frame above has already given the callee-saved registers
            // back to libdispatch's expectation and left SP 16-aligned, as the C ABI requires.
            // The two words sit in the blob before the literal (hoisted above: the literal's
            // offset must be the literal's position).
            block += [.loadFromBlob(dst: 0, blobOffset: stateOffset),
                      .loadFromBlob(dst: 16, blobOffset: stateOffset + 8),
                      .call(reg: 16)]
        } else if script.blobRemove != nil {
            // CFMachPortInvalidate(portRef) removes the source from every run loop (any
            // thread; we are the main thread, so no callback is in flight); then the two
            // CFReleases drop our references. Order is invalidate FIRST: after it the run
            // loop holds no source, so the controller's page deallocation — which follows
            // the completion flag — cannot race a live callback.
            let portRef: [Op] = [.loadFromBlob(dst: 0, blobOffset: removeOffset),
                                 .loadFromPointer(dst: 0, src: 0, offset: AgentBlob.machPortRefSlot)]
            block += portRef
            block += [.loadFromBlob(dst: 16, blobOffset: removeOffset + 8), .call(reg: 16)]
            block += portRef
            block += [.loadFromBlob(dst: 16, blobOffset: removeOffset + 16), .call(reg: 16)]
            block += [.loadFromBlob(dst: 0, blobOffset: removeOffset),
                      .loadFromPointer(dst: 0, src: 0, offset: AgentBlob.srcRefSlot),
                      .loadFromBlob(dst: 16, blobOffset: removeOffset + 16), .call(reg: 16)]
        } else {
            let answerStore = { (from: Int) -> [Op] in
                [.loadFromBlob(dst: 16, blobOffset: Self.resultAddressOffset),
                 .storeIndirect(src: from, base: 16, offset: 0)]
            }
            block += scriptBody(script, blob: blob, strings: strings, radiusOffset: radiusOffset, answerStore: answerStore)
        }
        // The flag goes last: a caller that reads it knows every call has returned *and* the
        // answer word is written. Absolute address: this stack is the app's real one.
        block.append(.loadFromBlob(dst: 16, blobOffset: Self.flagAddressOffset))
        block.append(.storeIndirect(src: 31, base: 16, offset: 0))
        for pair in 0..<6 {
            block.append(.loadPair(19 + 2 * pair, 20 + 2 * pair, offset: 16 * pair))
        }
        block.append(.addStack(imm: Self.calleeSavedFrame))
        block.append(.ret)

        // The block literal: isa names the global class and the flags bit makes Block_copy a
        // no-op (dispatch queues the pointer as-is), invoke is the block code's absolute address;
        // the descriptor must exist for _Block_copy's size read. The struct outlives the queueing
        // because it lives in the scratch region, which is released only after the completion
        // flag — which the block itself writes.
        blob.appendWord(addresses.concreteGlobalBlock)
        blob.appendWord(Self.blockIsGlobal)   // flags; reserved = 0 — the global bit is what makes
                                              // Block_copy/_Block_release no-ops (see blockIsGlobal)
        blob.appendWord(dispatch.codeBase &+ UInt64(4 * stubWordCount))
        // The descriptor: macOS's _Block_copy dereferences desc->size even for global blocks
        // (measured: a null descriptor dies in _Block_copy+56, in-process). A minimal one:
        // reserved, the literal's size, no signature, no copy/destroy helpers.
        blob.appendWord(dispatch.codeBase &+ UInt64(dataOffset(codeWordCount: stubWordCount + block.count))
                        &+ UInt64(blockOffset + 32))
        blob.appendWord(0)
        blob.appendWord(32)   // size of the literal
        blob.appendWord(0)    // signature
        blob.appendWord(0)    // copy helper
        blob.appendWord(0)    // destroy helper

        let (handbackSlots, stackSlot, returnSlot) = appendHandback(into: &blob, handback: handback)

        // The stub: absorb the armed interrupt (first act), queue the block, then hand the thread
        // straight back. Microseconds in the fabricated frame, and its only side effect on the
        // app's own machinery is a queueing call. The main queue is a global object (the header
        // getter is an inline of its address), so one load puts it in x0 — no call at all.
        var ops: [Op] = [.adrBlobBase(dst: blobRegister)]
        ops += Self.absorberOps(msgOffset: msgOffset, absorbPortOffset: absorbPortOffset)
        ops += queueOps
        ops += handbackOps(handbackSlots: handbackSlots, stackSlot: stackSlot, returnSlot: returnSlot)
        return (ops + block, blob)
    }

    /// The armed-interrupt absorber — the dispatched stub's first act, before `dispatch_async`.
    ///
    /// `thread_abort` arms `MACH_RCV_INTERRUPTED` on the thread when the state change has
    /// abandoned the call it targets; the armed flag is delivered to the next mach call that
    /// consults it. Measured 2026-10-20: CF's next run-loop-port receive answers
    /// `MACH_RCV_INVALID_ARGUMENTS` (0x10004013) at `__CFRunLoopServiceMachPort.cold.1` — the
    /// death class (five 1 ms-timer hostapps under `probe watch` with identical state, and live
    /// Vivaldi); park-shape gates do not see it (the dying call is CF's own next iteration, not
    /// the park we entered on). The stub takes the flag on a sacrificial `mach_msg2` of its own:
    /// a receive with a 1 ms timeout on a send right the executor injects into the target.
    /// Shapes measured and rejected: receive on `MACH_PORT_NULL` answers `MACH_RCV_INVALID_NAME`
    /// *before* the flag is consulted (consumes nothing); send on `MACH_PORT_NULL` raises
    /// `EXC_GUARD` (codes [0x0, 0x1]) — the port guard fires on this OS, a death vector of its
    /// own. The injected right is the only shape that is neither guarded nor short-circuited:
    /// armed answers `MACH_RCV_INTERRUPTED` (flag consumed), clean answers `MACH_RCV_TIMED_OUT`
    /// in 1 ms, and the stub discards the answer.
    static let absorberWordCount = 9

    /// The data offset of the absorber port word: after the seven address words, the window
    /// numbers, the optional radius, the 8-aligned 64-byte message buffer.
    static func absorbPortDataOffset(script: RemoteScript) -> Int {
        var off = 56 + 8 * script.windowNumbers.count
        if script.cornerRadius != nil { off += 8 }
        off = (off + 7) & ~7
        return off + 64
    }

    /// Where the absorber's trap leaves its kr for the executor to read: `[sp]` on the
    /// executor's writable stack — `sp + 8` is the completion flag, `sp + 16` the result word, and
    /// anything above is past the mapped pages (`sp + 24` faulted, measured; a store to the r-x
    /// code region faulted too). `NOBORDER_ABSORB_KR=1` on the probe prints it:
    /// 0x10004005 (`MACH_RCV_INTERRUPTED`) = the flag was armed and consumed; 0x10004003
    /// (`MACH_RCV_TIMED_OUT`) = the thread was not armed; 0x10004002 = no absorber port.
    static let absorbKrSpOffset = 0

    private static func absorberOps(msgOffset: Int, absorbPortOffset: Int) -> [Op] {
        [.adrBlob(dst: 0, offset: msgOffset),      // x0: the zeroed 64-byte message buffer
         .movImm(dst: 1, value: 0x102),            // x1: MACH_RCV_MSG | MACH_RCV_TIMEOUT (0x100,
                                                   // this SDK's value; 0x10 is SEND_TIMEOUT)
         .movImm(dst: 2, value: 0),                // x2: no send
         .movImm(dst: 3, value: 64),               // x3: receive size
         .loadFromBlob(dst: 4, blobOffset: absorbPortOffset),  // x4: a receive right the
                                                   // executor allocated in the target
         .movImm(dst: 5, value: 1),                // x5: 1 ms timeout
         .loadFromBlob(dst: 16, blobOffset: absorbPortOffset + 8),  // x16: mach_msg (libsystem_
                                                   // kernel): the legacy shim adds the overmach
                                                   // request bits and supplies the overmach port
                                                   // itself; the raw mach_msg2_trap rejects a
                                                   // timed receive with MACH_RCV_INVALID_
                                                   // ARGUMENTS (measured: the same kr CF dies on)
         .call(reg: 16),                           // armed -> MACH_RCV_INTERRUPTED (consumed),
                                                   // clean -> MACH_RCV_TIMED_OUT in 1 ms
         .storeIndirect(src: 0, base: 31, offset: absorbKrSpOffset)]  // keep the kr on the stack
    }
}
