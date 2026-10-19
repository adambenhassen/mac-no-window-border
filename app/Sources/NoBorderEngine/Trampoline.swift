import Foundation

/// arm64 instruction encoders used by `Trampoline`, and nothing else. The encodings are checked
/// against the system assembler in TrampolineTests.
public enum Arc64 {
    /// Breakpoint at exception level 0: our completion sentinel.
    public static let brk: UInt32 = 0xD420_0000
    public static let nop: UInt32 = 0xD503_201F

    public static func adr(dst: Int, immediate: Int) -> UInt32 {
        let immlo = UInt32(immediate & 0x3)
        let imm19 = UInt32((immediate >> 2) & 0x7_FFFF)
        return (immlo << 29) | (0x10_0000_00 as UInt32) | (imm19 << 5) | UInt32(dst & 0x1F)
    }

    /// ldr x<d>, [x<b>, #<offset>]  (offset must be a multiple of 8)
    public static func ldr(dst: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset % 8 == 0 && offset >= 0 && offset < 64 * 1024)
        return 0xF940_0000 | (UInt32(offset >> 3) << 10) | (UInt32(base & 0x1F) << 5) | UInt32(dst & 0x1F)
    }

    /// ldr d<d>, [x<b>, #<offset>]  (loads raw bits into a SIMD&FP register)
    public static func ldrd(dst: Int, base: Int, offset: Int) -> UInt32 {
        precondition(offset % 8 == 0 && offset >= 0 && offset < 32 * 1024)
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
}

/// Generates the code that runs inside the target app and the data it reads.
///
/// The generated code is straight-line: it resolves the selectors the script needs, then for each
/// window number looks the window up through `NSApp` and sends the requested messages. Sending a
/// message to a nil window or a nil titlebar view is a no-op in ObjC, so there is nothing to
/// branch on. It ends with `brk #0`, which stops the thread where the executor can pick it up.
///
/// Registers held across calls are callee-saved, because the AppKit code we call preserves them.
public enum Trampoline {
    static let blobRegister = 19
    static let msgSendRegister = 20
    static let selRegisterNameRegister = 28
    static let windowRegister = 26
    static let titlebarRegister = 27
    static let firstSelectorRegister = 21

    static let lookupSelector = "windowWithWindowNumber:"
    static let hasShadowSelector = "setHasShadow:"
    static let cornerRadiusSelector = "_setCornerRadius:"
    static let titlebarSelector = "_titlebarContainerView"
    static let decorationSelector = "setDrawsDecorationView:"

    private struct Blob {
        var bytes: [UInt8] = []
        var nsApp: Int { 0 }
        var msgSend: Int { 8 }
        var selRegisterName: Int { 16 }
        var firstWindowNumber: Int { 24 }

        mutating func appendWord(_ value: UInt64) {
            (0..<8).forEach { bytes.append(UInt8((value >> (8 * $0)) & 0xff)) }
        }

        mutating func appendString(_ text: String) -> Int {
            let at = bytes.count
            bytes.append(contentsOf: Array(text.utf8))
            bytes.append(0)
            return at
        }
    }

    private enum Op {
        case adrBlobBase(dst: Int)
        case adrBlob(dst: Int, offset: Int)
        case loadFromBlob(dst: Int, blobOffset: Int)
        case loadIndirect(dst: Int)
        case loadDoubleFromBlob(dst: Int, blobOffset: Int)
        case movImm(dst: Int, value: UInt16)
        case move(dst: Int, src: Int)
        case call(reg: Int)
        case halt
    }

    /// The selectors this script needs, in the order they are resolved into registers.
    private static func selectors(_ script: RemoteScript) -> [String] {
        var names = [lookupSelector]
        if script.hasShadow != nil { names.append(hasShadowSelector) }
        if script.cornerRadius != nil { names.append(cornerRadiusSelector) }
        if script.drawsDecoration != nil { names += [titlebarSelector, decorationSelector] }
        return names
    }

    public static func code(_ script: RemoteScript, addresses: AddressTable) -> [UInt32] {
        let (ops, blob) = plan(script, addresses: addresses)
        var words: [UInt32] = []
        for (index, op) in ops.enumerated() {
            switch op {
            case .adrBlobBase(let dst):
                words.append(Arc64.adr(dst: dst, immediate: blob.bytes.count))
            case .adrBlob(let dst, let offset):
                words.append(Arc64.adr(dst: dst, immediate: blob.bytes.count + offset - 4 * index))
            case .loadFromBlob(let dst, let offset):
                words.append(Arc64.ldr(dst: dst, base: blobRegister, offset: offset))
            case .loadIndirect(let dst):
                words.append(Arc64.ldr(dst: dst, base: dst, offset: 0))
            case .loadDoubleFromBlob(let dst, let offset):
                words.append(Arc64.ldrd(dst: dst, base: blobRegister, offset: offset))
            case .movImm(let dst, let value):
                words.append(Arc64.movz(dst: dst, value: value))
            case .move(let dst, let src):
                words.append(Arc64.movReg(dst: dst, src: src))
            case .call(let reg):
                words.append(Arc64.blr(reg))
            case .halt:
                words.append(Arc64.brk)
            }
        }
        return words
    }

    public static func data(_ script: RemoteScript, addresses: AddressTable) -> [UInt8] {
        plan(script, addresses: addresses).1.bytes
    }

    private static func plan(_ script: RemoteScript, addresses: AddressTable) -> ([Op], Blob) {
        var blob = Blob()
        blob.appendWord(addresses.nsAppGlobal)
        blob.appendWord(addresses.msgSend)
        blob.appendWord(addresses.selRegisterName)
        for number in script.windowNumbers { blob.appendWord(UInt64(number)) }
        let radiusOffset = blob.bytes.count
        if let radius = script.cornerRadius { blob.appendWord(radius.bitPattern) }

        let selectorNames = selectors(script)
        var selectorOffsets: [String: Int] = [:]
        for name in selectorNames { selectorOffsets[name] = blob.appendString(name) }

        var ops: [Op] = []
        ops.append(.adrBlobBase(dst: blobRegister))
        ops.append(.loadFromBlob(dst: selRegisterNameRegister, blobOffset: blob.selRegisterName))
        for (index, name) in selectorNames.enumerated() {
            ops.append(.adrBlob(dst: 0, offset: selectorOffsets[name]!))
            ops.append(.call(reg: selRegisterNameRegister))
            ops.append(.move(dst: firstSelectorRegister + index, src: 0))
        }
        ops.append(.loadFromBlob(dst: msgSendRegister, blobOffset: blob.msgSend))

        let selectorRegister = Dictionary(uniqueKeysWithValues: selectorNames.enumerated().map {
            ($1, firstSelectorRegister + $0)
        })
        let message = { (receiver: Int, selector: String) -> [Op] in
            [.move(dst: 0, src: receiver), .move(dst: 1, src: selectorRegister[selector]!)]
        }

        for windowIndex in script.windowNumbers.indices {
            let numberOffset = blob.firstWindowNumber + 8 * windowIndex
            ops.append(.loadFromBlob(dst: 0, blobOffset: blob.nsApp))
            ops.append(.loadIndirect(dst: 0))                                  // x0 = NSApp
            ops.append(.move(dst: 1, src: selectorRegister[lookupSelector]!))
            ops.append(.loadFromBlob(dst: 2, blobOffset: numberOffset))
            ops.append(.call(reg: msgSendRegister))
            ops.append(.move(dst: windowRegister, src: 0))

            if let hasShadow = script.hasShadow {
                ops += message(windowRegister, hasShadowSelector)
                ops.append(.movImm(dst: 2, value: hasShadow ? 1 : 0))
                ops.append(.call(reg: msgSendRegister))
            }
            if script.cornerRadius != nil {
                ops += message(windowRegister, cornerRadiusSelector)
                ops.append(.loadDoubleFromBlob(dst: 0, blobOffset: radiusOffset))
                ops.append(.call(reg: msgSendRegister))
            }
            if let drawsDecoration = script.drawsDecoration {
                ops += message(windowRegister, titlebarSelector)
                ops.append(.call(reg: msgSendRegister))
                ops.append(.move(dst: titlebarRegister, src: 0))
                ops += message(titlebarRegister, decorationSelector)
                ops.append(.movImm(dst: 2, value: drawsDecoration ? 1 : 0))
                ops.append(.call(reg: msgSendRegister))
            }
        }
        ops.append(.halt)
        return (ops, blob)
    }
}
