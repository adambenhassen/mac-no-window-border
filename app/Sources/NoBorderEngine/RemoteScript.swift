import Foundation

/// One window's worth of work for one app, as data rather than as code.
///
/// A `nil` field means "do not touch this aspect"; it is how a partially-supported app is
/// handled without a second code path.
public struct RemoteScript: Equatable {
    public var windowNumbers: [UInt32]
    public var hasShadow: Bool?
    public var cornerRadius: Double?
    public var drawsDecoration: Bool?
    /// Hide the close/miniaturize/zoom buttons, or show them again. A `nil` field means "do not
    /// touch", like every other field: a script built without the option says nothing about buttons.
    public var hideButtons: Bool?
    /// Test-only: makes the generated code jump to an address no process has mapped, so the fault
    /// guard has something to catch. Product code never sets it and nothing sets it by default.
    public var forceFaultForTesting = false
    /// A script that only looks the application object up and writes it back to us. Its purpose is
    /// to answer one question before any window is touched: is this process an AppKit app at all?
    /// `objc_getClass("NSApplication")`/`sharedApplication` is nil in a process without AppKit —
    /// which is exactly what the generated code would silently do nothing about.
    public var appKitProbe = false

    public init(windowNumbers: [UInt32], hasShadow: Bool?, cornerRadius: Double?, drawsDecoration: Bool?,
                hideButtons: Bool? = nil) {
        self.windowNumbers = windowNumbers
        self.hasShadow = hasShadow
        self.cornerRadius = cornerRadius
        self.drawsDecoration = drawsDecoration
        self.hideButtons = hideButtons
    }

    /// The changes: no outline/shadow, square corners, no titlebar rim, and the window buttons hidden
    /// or shown as asked. The buttons are always named — a script that shows them is how turning the
    /// option off reaches a window that is staying maximized.
    public static func applied(windowNumbers: [UInt32], buttonsHidden: Bool = false) -> RemoteScript {
        RemoteScript(windowNumbers: windowNumbers, hasShadow: false, cornerRadius: 0.01, drawsDecoration: false,
                     hideButtons: buttonsHidden)
    }

    /// Back to exactly what AppKit had before: shadow on, default corner radius, rim drawn, buttons shown.
    public static func restored(windowNumbers: [UInt32]) -> RemoteScript {
        RemoteScript(windowNumbers: windowNumbers, hasShadow: true, cornerRadius: 0.0, drawsDecoration: true,
                     hideButtons: false)
    }

    /// Ask the target for its application object and nothing else.
    public static func appKitProbe() -> RemoteScript {
        var script = RemoteScript(windowNumbers: [], hasShadow: nil, cornerRadius: nil, drawsDecoration: nil)
        script.appKitProbe = true
        return script
    }
}

/// The state to hand the thread back to once the calls are done: the app's own registers, its
/// stack pointer, and the instruction it was about to run. The generated code restores these from
/// its data and jumps there, so the app takes itself back — no second stop, no second round trip.
public struct ThreadHandback: Equatable {
    /// x0…x30 as the app had them (x29 is the frame pointer, x30 the link register).
    public var registers: [UInt64]
    public var sp: UInt64
    /// The address to run next: the start of the run-loop call the thread was sitting in, so it
    /// re-issues that call instead of returning from one it never made.
    public var pc: UInt64

    public init(registers: [UInt64], sp: UInt64, pc: UInt64) {
        precondition(registers.count == 31, "x0…x30")
        self.registers = registers
        self.sp = sp
        self.pc = pc
    }
}

/// Addresses in the target process. The dyld shared cache is mapped at one address for the whole
/// boot, so an address resolved here is the same address in the target.
public struct AddressTable: Equatable {
    public var msgSend: UInt64
    public var selRegisterName: UInt64
    public var objcGetClass: UInt64

    public init(msgSend: UInt64, selRegisterName: UInt64, objcGetClass: UInt64) {
        self.msgSend = msgSend
        self.selRegisterName = selRegisterName
        self.objcGetClass = objcGetClass
    }

    /// Resolves the three functions from this process. `NSApplication` is asked for by name inside
    /// the target, because the `_NSApp` global is not a symbol reachable from here.
    public static func current() -> AddressTable? {
        let process = dlopen(nil, RTLD_NOW)
        let appKit = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW)
        func address(_ name: String) -> UInt64? {
            guard let symbol = dlsym(appKit ?? process, name) ?? dlsym(process, name) else { return nil }
            return UInt64(UInt(bitPattern: symbol))
        }
        guard let msgSend = address("objc_msgSend"),
              let selRegisterName = address("sel_registerName"),
              let objcGetClass = address("objc_getClass") else { return nil }
        return AddressTable(msgSend: msgSend, selRegisterName: selRegisterName, objcGetClass: objcGetClass)
    }
}
