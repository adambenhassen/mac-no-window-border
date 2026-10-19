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

    /// mov sp, x<r> — the app's stack pointer, put back before we jump to its code.
    public static func movSp(from register: Int) -> UInt32 {
        0x9100_0000 | (UInt32(register & 0x1F) << 5) | 31
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
    static let titlebarRegister = 28
    static let firstSelectorRegister = 22      // five of these, ending at x26
    static let selLookupRegister = 16          // used only between loads and a lookup call
    static let classLookupRegister = 17

    /// The register the generated code jumps back to the app from. x17 is scratch in the ABI and
    /// holds nothing the app wants back, so it is free to use for the jump.
    public static let handbackRegister = 17

    /// When every call has returned, the script writes zero at this offset from the stack pointer it
    /// was given. The caller polls that word instead of touching the thread again.
    public static let completionFlagOffset = 8

    static let applicationClass = "NSApplication"
    static let sharedApplicationSelector = "sharedApplication"
    static let lookupSelector = "windowWithWindowNumber:"
    static let hasShadowSelector = "setHasShadow:"
    static let cornerRadiusSelector = "_setCornerRadius:"
    static let titlebarSelector = "_titlebarContainerView"
    static let decorationSelector = "setDrawsDecorationView:"

    /// Where the data goes: just after the code, on an 8-byte boundary, because every read of it
    /// is an 8-byte load from the base register. The executor writes the data here and the code
    /// below is generated against the same offset; only this function may say where it is.
    public static func dataOffset(codeWordCount: Int) -> Int {
        ((4 * codeWordCount) + 7) / 8 * 8
    }

    private struct Blob {
        var bytes: [UInt8] = []
        var msgSend: Int { 0 }
        var selRegisterName: Int { 8 }
        var objcGetClass: Int { 16 }
        var firstWindowNumber: Int { 24 }

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
        case call(reg: Int)
        case storeCompletionFlag
        case moveStackPointer(from: Int)
        case branch(to: Int)
    }

    /// The selectors this script needs, in the order they are resolved into registers.
    private static func selectors(_ script: RemoteScript) -> [String] {
        var names = [lookupSelector]
        if script.hasShadow != nil { names.append(hasShadowSelector) }
        if script.cornerRadius != nil { names.append(cornerRadiusSelector) }
        if script.drawsDecoration != nil { names += [titlebarSelector, decorationSelector] }
        return names
    }

    public static func code(_ script: RemoteScript, addresses: AddressTable, handback: ThreadHandback) -> [UInt32] {
        let (ops, _) = plan(script, addresses: addresses, handback: handback)
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
            case .call(let reg):
                words.append(Arc64.blr(reg))
            case .storeCompletionFlag:
                words.append(Arc64.strZero(base: 31, offset: completionFlagOffset))
            case .moveStackPointer(let from):
                words.append(Arc64.movSp(from: from))
            case .branch(let register):
                words.append(Arc64.br(register))
            }
        }
        return words
    }

    public static func data(_ script: RemoteScript, addresses: AddressTable, handback: ThreadHandback) -> [UInt8] {
        plan(script, addresses: addresses, handback: handback).1.bytes
    }

    private static func plan(_ script: RemoteScript, addresses: AddressTable, handback: ThreadHandback) -> ([Op], Blob) {
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
        // one selector lookup per message the script sends
        for (index, name) in selectorNames.enumerated() {
            ops.append(.loadFromBlob(dst: selLookupRegister, blobOffset: blob.selRegisterName))
            ops.append(.adrBlob(dst: 0, offset: strings[name]!))
            ops.append(.call(reg: selLookupRegister))
            ops.append(.move(dst: firstSelectorRegister + index, src: 0))
        }

        let selector = Dictionary(uniqueKeysWithValues: selectorNames.enumerated().map {
            ($1, firstSelectorRegister + $0)
        })
        let send = { (receiver: Int, name: String) -> [Op] in
            [.move(dst: 0, src: receiver), .move(dst: 1, src: selector[name]!)]
        }

        for windowIndex in script.windowNumbers.indices {
            let numberOffset = blob.firstWindowNumber + 8 * windowIndex
            ops += send(appRegister, lookupSelector)
            ops.append(.loadFromBlob(dst: 2, blobOffset: numberOffset))
            ops.append(.call(reg: msgSendRegister))
            ops.append(.move(dst: windowRegister, src: 0))

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
                ops += send(windowRegister, titlebarSelector)
                ops.append(.call(reg: msgSendRegister))
                ops.append(.move(dst: titlebarRegister, src: 0))
                ops += send(titlebarRegister, decorationSelector)
                ops.append(.movImm(dst: 2, value: drawsDecoration ? 1 : 0))
                ops.append(.call(reg: msgSendRegister))
            }
        }
        // Hand the thread back to the app. The flag goes first: a caller that reads it knows every
        // call has returned. Then everything the calls may have clobbered, from the state that was
        // read before entering — including the instruction the app was about to run.
        ops.append(.storeCompletionFlag)
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
        return (ops, blob)
    }
}
