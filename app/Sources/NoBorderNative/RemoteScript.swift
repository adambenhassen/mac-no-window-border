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
    /// Test-only: the dispatched stub delivers (absorber and handback included) but never queues
    /// the block — the completion flag stays unset, so the run reads as timed-out. Isolates
    /// entry-machinery effects from block-queueing effects. Product code never sets it.
    public var suppressBlockQueueForTesting = false
    /// A script that only looks the application object up and writes it back to us. Its purpose is
    /// to answer one question before any window is touched: is this process an AppKit app at all?
    /// `objc_getClass("NSApplication")`/`sharedApplication` is nil in a process without AppKit —
    /// which is exactly what the generated code would silently do nothing about.
    public var appKitProbe = false
    /// A script that asks, for each window, whether the app has it as key. See
    /// `keyStateRead(windowNumbers:)`.
    public var keyStateRead = false
    /// Run a resident agent blob's entry as the dispatched block's body: `entry` is called with
    /// `state` as its only argument, on the app's main queue, under the fault guard. The block's
    /// flag write is the entry's completion — it says the entry returned, which is a separate fact
    /// from the blob's own `ready` slot (verdict 6: the entry can return having failed a checked
    /// registration, and can leave `ready` set while a later fault takes the thread).
    /// Dispatched mode only; the blob's pages are allocated by the installer, outside the
    /// executor's scratch ownership, so they outlive this run and the executor itself.
    public var blobEntry: BlobEntry?
    /// Remove a resident agent: the dispatched block invalidates the agent's CFMachPort
    /// (removing it from every run loop) and releases the port and the source, in that order.
    /// The value is the agent's STATE page address; the controller deallocates the blob's
    /// pages only after the block's completion flag — from then on no callback can be
    /// scheduled, so nothing can execute on the pages being freed.
    public var blobRemove: UInt64?

    public struct BlobEntry: Equatable {
        public var state: UInt64
        public var entry: UInt64
        public init(state: UInt64, entry: UInt64) { self.state = state; self.entry = entry }
    }

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

    /// Run the blob entry (see `blobEntry`): the installer's resident agent starts here.
    public static func blobEntry(state: UInt64, entry: UInt64) -> RemoteScript {
        var script = RemoteScript(windowNumbers: [], hasShadow: nil, cornerRadius: nil, drawsDecoration: nil)
        script.blobEntry = BlobEntry(state: state, entry: entry)
        return script
    }

    /// Remove the resident agent (see `blobRemove`): dispatched, so the invalidation and the
    /// releases run as a normal main-queue block in healthy CF state.
    public static func blobRemove(state: UInt64) -> RemoteScript {
        var script = RemoteScript(windowNumbers: [], hasShadow: nil, cornerRadius: nil, drawsDecoration: nil)
        script.blobRemove = state
        return script
    }

    /// Ask the target which of these windows it has as key. The key state is the app's own answer
    /// to "is its key drawing showing on this window": the drawing `applied` removes comes back
    /// when a window becomes key (measured 2026-10-20), the properties that store it do not say
    /// so, and reading the screen is off the table.
    ///
    /// The answer word packs one bit per window, set for "the app has it key". The generator
    /// shifts the accumulator as it walks the windows, so the first window lands in the bit above
    /// the last window's: window `i` of `windowNumbers` is at bit `count-1-i`. At most 32 windows
    /// per read, one bit each.
    public static func keyStateRead(windowNumbers: [UInt32]) -> RemoteScript {
        var script = RemoteScript(windowNumbers: windowNumbers, hasShadow: nil, cornerRadius: nil, drawsDecoration: nil)
        script.keyStateRead = true
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
    /// The address to run next: the completed receive's original return PC. Reissuing a receive
    /// here could overwrite a message that CoreFoundation has not consumed yet.
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
    /// The dispatch entry's three: the main queue object, the queueing call, and the block isa
    /// that makes `Block_copy` a no-op (a global block queues by pointer). `dispatch_get_main_queue`
    /// is an inline header function returning `&_dispatch_main_q`, so the object itself is the
    /// symbol — there is no getter in the symbol table. The shared cache is mapped at one address
    /// for the whole boot, so these resolve identically in the target.
    public var dispatchMainQueue: UInt64
    public var dispatchAsync: UInt64
    public var concreteGlobalBlock: UInt64
    /// The legacy `mach_msg` entry (libsystem_kernel): the shim every normal caller uses, which
    /// adds the overmach request bits and supplies the overmach port itself. The dispatched
    /// stub's absorber trap calls it — the raw `mach_msg2_trap` rejects a timed receive with
    /// `MACH_RCV_INVALID_ARGUMENTS` (measured 2026-10-20: the same kr CoreFoundation dies on).
    public var machMsg: UInt64
    /// The removal pair (P1d): CFMachPortInvalidate + CFRelease, run in the dispatched block
    /// against the agent's state page.
    public var cfmachPortInvalidate: UInt64
    public var cfmachPortRelease: UInt64

    public init(msgSend: UInt64, selRegisterName: UInt64, objcGetClass: UInt64,
                dispatchMainQueue: UInt64 = 0, dispatchAsync: UInt64 = 0, concreteGlobalBlock: UInt64 = 0,
                machMsg: UInt64 = 0, cfmachPortInvalidate: UInt64 = 0, cfmachPortRelease: UInt64 = 0) {
        self.msgSend = msgSend
        self.selRegisterName = selRegisterName
        self.objcGetClass = objcGetClass
        self.dispatchMainQueue = dispatchMainQueue
        self.dispatchAsync = dispatchAsync
        self.concreteGlobalBlock = concreteGlobalBlock
        self.machMsg = machMsg
        self.cfmachPortInvalidate = cfmachPortInvalidate
        self.cfmachPortRelease = cfmachPortRelease
    }

    /// Resolves the functions from this process. `NSApplication` is asked for by name inside
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
              let objcGetClass = address("objc_getClass"),
              let dispatchMainQueue = address("_dispatch_main_q"),
              let dispatchAsync = address("dispatch_async"),
              let concreteGlobalBlock = address("_NSConcreteGlobalBlock"),
              let machMsg = address("mach_msg"),
              let cfmachPortInvalidate = address("CFMachPortInvalidate"),
              let cfmachPortRelease = address("CFRelease") else { return nil }
        return AddressTable(msgSend: msgSend, selRegisterName: selRegisterName, objcGetClass: objcGetClass,
                            dispatchMainQueue: dispatchMainQueue, dispatchAsync: dispatchAsync,
                            concreteGlobalBlock: concreteGlobalBlock, machMsg: machMsg,
                            cfmachPortInvalidate: cfmachPortInvalidate, cfmachPortRelease: cfmachPortRelease)
    }
}
