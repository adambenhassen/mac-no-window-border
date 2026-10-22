import Foundation

/// The functions the agent blob calls. Resolved in the tool by `dlsym` and prefilled into the
/// blob's RW state: the dyld shared cache is mapped at one address for the whole boot, so an
/// address that resolves here is the same address in the target (the property `AddressTable`
/// already ships on). `current()` answers nil when any symbol is missing — the installer refuses
/// before touching the target (verdict 5's build order).
///
/// `commonModesVar` and `machTaskSelfVar` are the *addresses of variables*, not values: the blob
/// loads the CFStringRef and the self-task name from them at run time, in the target's own
/// address space (verdict 6 — the installer must never prefill the tool's task-port name).
public struct AgentAddresses: Equatable {
    public var cfmachPortCreate: UInt64
    public var cfmachPortGetPort: UInt64
    public var createRunLoopSource: UInt64
    public var runLoopGetMain: UInt64
    public var runLoopAddSource: UInt64
    public var machMsg: UInt64
    public var taskGetSpecialPort: UInt64
    public var bootstrapRegister: UInt64
    public var bootstrapLookUp: UInt64
    public var commonModesVar: UInt64
    public var machTaskSelfVar: UInt64
    public var cfmachPortInvalidate: UInt64
    public var cfRelease: UInt64
    /// The Objective-C trio (P1b): the callback sends the window selectors through these.
    public var msgSend: UInt64
    public var selRegisterName: UInt64
    public var objcGetClass: UInt64
    /// The P1b deferral helpers: the callback gates execution on the run loop's real current
    /// mode (commonModes is not a safety predicate — codex P1b verdict), and the wake timer
    /// sends the internal APPLY_PENDING message when the controller has gone quiet (the timer
    /// callback sends; it touches no AppKit).
    public var runLoopCopyCurrentMode: UInt64
    public var defaultModeVar: UInt64
    public var timerCreate: UInt64
    public var timerInvalidate: UInt64
    public var timeGetCurrent: UInt64
    /// P1c: arming the wake timer on the main run loop (CFRunLoopAddTimer).
    public var runLoopAddTimer: UInt64
    /// P1e: the border observer. These stay OUT of `table` — adding them would grow the 22-entry
    /// function table and move `cbAddrSlot=240` and every state offset below it. The installer
    /// prefills them into the fresh `observerCreateSlot`/`observerAddSlot`/`observerInvalidateSlot`
    /// instead. Create + add arm the observer in the entry; invalidate tears it down in the blob's
    /// teardown subroutine.
    public var cfRunLoopObserverCreate: UInt64
    public var cfRunLoopAddObserver: UInt64
    public var cfRunLoopObserverInvalidate: UInt64
    /// P1f: the ObjC runtime functions for the setHasShadow: override (also out of `table`).
    public var classAddMethod: UInt64
    public var classGetMethodImplementation: UInt64
    public var classGetInstanceMethod: UInt64
    public var methodSetImplementation: UInt64
    public var methodGetImplementation: UInt64
    /// Sandbox rendezvous: wraps a controller-planted receive right (out of `table`).
    public var cfMachPortCreateWithPort: UInt64

    public init(cfmachPortCreate: UInt64, cfmachPortGetPort: UInt64, createRunLoopSource: UInt64,
                runLoopGetMain: UInt64, runLoopAddSource: UInt64, machMsg: UInt64,
                taskGetSpecialPort: UInt64, bootstrapRegister: UInt64,
                bootstrapLookUp: UInt64, commonModesVar: UInt64, machTaskSelfVar: UInt64,
                cfmachPortInvalidate: UInt64, cfRelease: UInt64,
                msgSend: UInt64, selRegisterName: UInt64, objcGetClass: UInt64,
                runLoopCopyCurrentMode: UInt64, defaultModeVar: UInt64,
                timerCreate: UInt64, timerInvalidate: UInt64, timeGetCurrent: UInt64,
                runLoopAddTimer: UInt64, cfRunLoopObserverCreate: UInt64,
                cfRunLoopAddObserver: UInt64, cfRunLoopObserverInvalidate: UInt64,
                classAddMethod: UInt64, classGetMethodImplementation: UInt64,
                classGetInstanceMethod: UInt64, methodSetImplementation: UInt64,
                methodGetImplementation: UInt64, cfMachPortCreateWithPort: UInt64) {
        self.cfmachPortCreate = cfmachPortCreate
        self.cfmachPortGetPort = cfmachPortGetPort
        self.createRunLoopSource = createRunLoopSource
        self.runLoopGetMain = runLoopGetMain
        self.runLoopAddSource = runLoopAddSource
        self.machMsg = machMsg
        self.taskGetSpecialPort = taskGetSpecialPort
        self.bootstrapRegister = bootstrapRegister
        self.bootstrapLookUp = bootstrapLookUp
        self.commonModesVar = commonModesVar
        self.machTaskSelfVar = machTaskSelfVar
        self.cfmachPortInvalidate = cfmachPortInvalidate
        self.cfRelease = cfRelease
        self.msgSend = msgSend
        self.selRegisterName = selRegisterName
        self.objcGetClass = objcGetClass
        self.runLoopCopyCurrentMode = runLoopCopyCurrentMode
        self.defaultModeVar = defaultModeVar
        self.timerCreate = timerCreate
        self.timerInvalidate = timerInvalidate
        self.timeGetCurrent = timeGetCurrent
        self.runLoopAddTimer = runLoopAddTimer
        self.cfRunLoopObserverCreate = cfRunLoopObserverCreate
        self.cfRunLoopAddObserver = cfRunLoopAddObserver
        self.cfRunLoopObserverInvalidate = cfRunLoopObserverInvalidate
        self.classAddMethod = classAddMethod
        self.classGetMethodImplementation = classGetMethodImplementation
        self.classGetInstanceMethod = classGetInstanceMethod
        self.methodSetImplementation = methodSetImplementation
        self.methodGetImplementation = methodGetImplementation
        self.cfMachPortCreateWithPort = cfMachPortCreateWithPort
    }

    /// All of them, from this process. nil for the first one that does not resolve.
    public static func current() -> AgentAddresses? {
        let process = dlopen(nil, RTLD_NOW)
        func address(_ name: String) -> UInt64? {
            guard let symbol = dlsym(process, name) else { return nil }
            return UInt64(UInt(bitPattern: symbol))
        }
        guard let cfmachPortCreate = address("CFMachPortCreate"),
              let cfmachPortGetPort = address("CFMachPortGetPort"),
              let createRunLoopSource = address("CFMachPortCreateRunLoopSource"),
              let runLoopGetMain = address("CFRunLoopGetMain"),
              let runLoopAddSource = address("CFRunLoopAddSource"),
              let machMsg = address("mach_msg"),
              let taskGetSpecialPort = address("task_get_special_port"),
              let bootstrapRegister = address("bootstrap_register"),
              let bootstrapLookUp = address("bootstrap_look_up"),
              let commonModesVar = address("kCFRunLoopCommonModes"),
              let machTaskSelfVar = address("mach_task_self_"),
              let cfmachPortInvalidate = address("CFMachPortInvalidate"),
              let cfRelease = address("CFRelease"),
              let msgSend = address("objc_msgSend"),
              let selRegisterName = address("sel_registerName"),
              let objcGetClass = address("objc_getClass"),
              let runLoopCopyCurrentMode = address("CFRunLoopCopyCurrentMode"),
              let defaultModeVar = address("kCFRunLoopDefaultMode"),
              let timerCreate = address("CFRunLoopTimerCreate"),
              let timerInvalidate = address("CFRunLoopTimerInvalidate"),
              let timeGetCurrent = address("CFAbsoluteTimeGetCurrent"),
              let runLoopAddTimer = address("CFRunLoopAddTimer"),
              let cfRunLoopObserverCreate = address("CFRunLoopObserverCreate"),
              let cfRunLoopAddObserver = address("CFRunLoopAddObserver"),
              let cfRunLoopObserverInvalidate = address("CFRunLoopObserverInvalidate"),
              let classAddMethod = address("class_addMethod"),
              let classGetMethodImplementation = address("class_getMethodImplementation"),
              let classGetInstanceMethod = address("class_getInstanceMethod"),
              let methodSetImplementation = address("method_setImplementation"),
              let methodGetImplementation = address("method_getImplementation"),
              let cfMachPortCreateWithPort = address("CFMachPortCreateWithPort") else { return nil }
        return AgentAddresses(cfmachPortCreate: cfmachPortCreate, cfmachPortGetPort: cfmachPortGetPort,
                              createRunLoopSource: createRunLoopSource, runLoopGetMain: runLoopGetMain,
                              runLoopAddSource: runLoopAddSource, machMsg: machMsg,
                              taskGetSpecialPort: taskGetSpecialPort,
                              bootstrapRegister: bootstrapRegister, bootstrapLookUp: bootstrapLookUp,
                              commonModesVar: commonModesVar, machTaskSelfVar: machTaskSelfVar,
                              cfmachPortInvalidate: cfmachPortInvalidate, cfRelease: cfRelease,
                              msgSend: msgSend, selRegisterName: selRegisterName,
                              objcGetClass: objcGetClass,
                              runLoopCopyCurrentMode: runLoopCopyCurrentMode,
                              defaultModeVar: defaultModeVar, timerCreate: timerCreate,
                              timerInvalidate: timerInvalidate, timeGetCurrent: timeGetCurrent,
                              runLoopAddTimer: runLoopAddTimer,
                              cfRunLoopObserverCreate: cfRunLoopObserverCreate,
                              cfRunLoopAddObserver: cfRunLoopAddObserver,
                              cfRunLoopObserverInvalidate: cfRunLoopObserverInvalidate,
                              classAddMethod: classAddMethod,
                              classGetMethodImplementation: classGetMethodImplementation,
                              classGetInstanceMethod: classGetInstanceMethod,
                              methodSetImplementation: methodSetImplementation,
                              methodGetImplementation: methodGetImplementation,
                              cfMachPortCreateWithPort: cfMachPortCreateWithPort)
    }

    /// The table as it goes into the state page, in the slot order the blob reads it.
    public var table: [UInt64] {
        [cfmachPortCreate, cfmachPortGetPort, createRunLoopSource, runLoopGetMain, runLoopAddSource,
         machMsg, taskGetSpecialPort, bootstrapRegister, bootstrapLookUp,
         commonModesVar, machTaskSelfVar, cfmachPortInvalidate, cfRelease,
         msgSend, selRegisterName, objcGetClass,
         runLoopCopyCurrentMode, defaultModeVar, timerCreate, timerInvalidate, timeGetCurrent,
         runLoopAddTimer]
    }
}

/// The resident agent, as bytes: one executable page and one writable page, assembled here and
/// written into the target by `AgentInstaller`. The entry creates a CFMachPort (the callback
/// arrives in the create context; the run-loop source is added last, so a checked failure
/// publishes nothing), registers "com.noborder.rz.<pid>" in the bootstrap namespace, and marks
/// itself ready. The callback answers HELLO (2004) with the COMPLEX handshake — a MOVE_SEND on
/// the agent's port, the shape P1a-0 proved — and pings (2001) with ACKs (2002), each send
/// non-blocking (`MACH_SEND_MSG | MACH_SEND_TIMEOUT`, timeout 0 — verdict 6: `TIMEOUT_NONE`
/// names no timeout, it names no *option*, and a send without the option can wait for queue
/// space on the app's main thread).
///
/// The instructions are hand-encoded through `Arc64` the way `Trampoline` does. AgentBlobTests
/// audits the build two ways: every encoding cross-checked against the system assembler, and
/// every word decoded to show the blob writes no callee-saved register and no x18, keeps SP
/// 16-aligned at every call, balances its stack, and lands every store on the state page, the
/// stack, or the digits cursor — never the code page.
///
/// The message layouts are the measured LP64 kernel shapes (the ledger, 2026-10-20). HELLO
/// carries no counter field: the pid is not needed once the service name is in the message, and
/// a 64-byte name at offset 32 would overlap a counter (verdict 6 froze this layout; the
/// hostapp's linked agent and the probe speak it too):
///
/// ```text
/// HELLO 96 B:       header(24) · token@24 · service name[64]@32   (msgh_id 2004)
/// PING/ACK 40 B:    header(24) · seq@24 · counter@32              (msgh_id 2001 / 2002)
/// HANDSHAKE 48 B:   header(24) · count@24 · desc(name@28, disposition@38, type@39) · token@40
///                   (msgh_id 2003, msgh_bits 0x80000013: COMPLEX + MACH_MSGH_BITS(COPY_SEND, PORT_NONE))
/// ```
public enum AgentBlob {
    public static let pageSize = 0x4000
    /// Code page + state page, in one contiguous `vm_allocate`.
    public static let regionBytes = 2 * pageSize

    // The manifest, at the top of the state page.
    /// "NOBAGENT" as the first eight bytes of the state page, little-endian.
    public static let magic: UInt64 = 0x544E_4547_4142_4F4E
    public static let version: UInt64 = 1
    public static let magicSlot = 0
    public static let versionSlot = 8
    public static let codeLenSlot = 16
    public static let entryOffSlot = 24
    public static let cbOffSlot = 32

    /// The function table, in `AgentAddresses.table` order.
    public static let tableSlot = 64

    // The slots the blob keeps state in. Every offset stays under 32768 (the `ldr`/`str`
    // immediate is a scaled 12-bit count of eights); the name buffers are 8-aligned for word
    // copies. The P1b slots (424 up) are the entry-resolved selector cache, the NSApplication
    // class, the prefilled corner-radius doubles, and the per-window op table.
    // The table takes the state page's first 240 bytes (22 function addresses); every slot
    // below starts where the table ends.
    public static let cbAddrSlot = 240        // absolute, patched by the installer after the allocation
    public static let pidSlot = 248
    public static let agentPortSlot = 256
    public static let cbEntriesSlot = 264      // every callback invocation counted, rejected messages included
    public static let srcRefSlot = 272
    public static let toolPortSlot = 280
    /// The CFMachPort REFERENCE (the create reference, kept after the source took its own):
    /// removal invalidates it (CFMachPortInvalidate removes it from every run loop, from any
    /// thread) and releases it — the source slot alone cannot reach the port. Slot 352 (the
    /// free word between dbgSize and the name block). It once sat at 2728 and the removal faulted
    /// (measured 2026-10-21: address = state & 0xffffffff); that was a collision with a slot the
    /// blob wrote, not an `ldr` range limit — the scaled immediate reaches 32760, and the
    /// assembler cross-check pins the encodings at 2728 and up.
    public static let machPortRefSlot = 352
    public static let counterSlot = 288
    public static let readySlot = 296
    public static let errSlot = 304           // the entry's checked failure: the kr that said no
    public static let errHandshakeSlot = 312  // the callback's HELLO path
    public static let errAckSlot = 320        // the callback's ping path: the last ACK kr
    public static let tokenSlot = 328
    public static let bsSlot = 336            // the bootstrap port, read once by the entry
    public static let dbgSizeSlot = 344       // cb entry: the raw `size` argument (debug probe)
    public static let rzNameSlot = 368        // 32 bytes: "com.noborder.rz.<pid>"
    public static let toolNameSlot = 400      // 64 bytes: the HELLO's service name, copied out
    // P1b: the selector cache the entry resolves once (a nil answer is a checked failure);
    // the NSApplication class; the corner-radius doubles' bits, prefilled at build time; the
    // mutation bookkeeping; the per-window op table. Rows are 128 bytes: the desired state,
    // the done state, and the originals captured at the row's FIRST execution (never
    // overwritten — codex P1b verdict), with object identity. Restore without capture mutates
    // nothing; a row owning originals is never evicted (a full table refuses new work).
    public static let selWindowSlot = 472     // windowWithWindowNumber:
    public static let selShadowSlot = 480     // setHasShadow:
    public static let selHasShadowSlot = 488  // hasShadow
    public static let selCornerSlot = 496     // _setCornerRadius:
    public static let selDecoSlot = 504       // setDrawsDecorationView:
    public static let selTitlebarSlot = 512   // _titlebarContainerView
    public static let selButtonSlot = 520     // standardWindowButton:
    public static let selHiddenSlot = 528     // setHidden:
    public static let selSharedAppSlot = 536  // sharedApplication
    public static let selRetainSlot = 544     // retain (the mutation sequence's strong ref)
    public static let selReleaseSlot = 552    // release
    public static let selRespondsSlot = 560   // respondsToSelector: (capability gate)
    public static let selIsHiddenSlot = 568   // isHidden (per-button originals capture)
    public static let selCornerGetterSlot = 576  // cornerRadius (the captured original)
    public static let selDecoGetterSlot = 584    // drawsDecorationView (the captured original)
    public static let selCount = 15           // selectors the entry preflight resolves (class name last)
    public static let nsAppClassSlot = 592    // the Class, from objc_getClass
    public static let cornerOnSlot = 600      // Double(0.01).bitPattern — applied
    public static let cornerOffSlot = 608     // 0.0 — restored (the shipped default)
    public static let depthSlot = 616         // main-thread mutation depth (reentrancy guard)
    public static let wakeTimerSlot = 624     // the wake timer's ref, 0 while none is armed
    public static let wakeDelaySlot = 632     // Double(0.05).bitPattern — fire date = now + this
    public static let timerCbAddrSlot = 2696  // absolute, patched by the installer (like cbAddr)
    public static let opTableSlot = 640
    public static let opTableCount = 16
    public static let opEntryBytes = 128
    // Row fields (offsets within a 128-byte row):
    public static let rowWid = 0
    public static let rowOp = 8               // 1 apply, 2 restore
    public static let rowButtons = 16         // bitmask of the three standard buttons
    public static let rowDesiredGen = 24
    public static let rowDoneGen = 32
    public static let rowLastStatus = 40
    public static let rowFlags = 48           // bit 0 occupied, 1 originals-captured, 2 decoration-known, 3 pending
    public static let rowObject = 56          // the mutated window's identity (kept, not chased)
    public static let rowOrigShadow = 64      // captured originals (getter read at FIRST apply)
    public static let rowOrigRadius = 72      // the Double's bits
    public static let rowOrigButton0 = 80     // per-button isHidden; 0 = button absent at capture
    public static let rowOrigButton1 = 88
    public static let rowOrigButton2 = 96
    public static let rowOrigDecoration = 104
    /// The app's own latest setHasShadow: request while the row was applied (recorded by the override
    /// at depth 0): 0 = none, else request + 1. Restore prefers it over the apply-time snapshot.
    public static let rowAppShadow = 112
    // Status codes the callback answers (the codex enum; kr stays reserved for Mach returns):
    public static let statusApplied: UInt64 = 1
    public static let statusRestored: UInt64 = 2
    public static let statusNotFound: UInt64 = 3
    public static let statusDeferred: UInt64 = 4
    public static let statusSuperseded: UInt64 = 5
    public static let statusUnsupported: UInt64 = 6
    public static let statusTableFull: UInt64 = 7
    public static let statusNoOriginal: UInt64 = 8
    // The entry's selector-loop bookkeeping. Every cursor and the count live in state and are
    // re-loaded after each call: x0-x15 are all caller-saved (measured 2026-10-21: the loop
    // first kept them in registers, `sel_registerName` clobbered the count, and the store
    // cursor walked off the state page into a fault).
    public static let opTableEnd = opTableSlot + opTableCount * opEntryBytes   // 2688
    public static let selNameCursorSlot = 2704
    public static let selStoreCursorSlot = 2712
    public static let selLoopCountSlot = 2720
    // P1e: the border observer (a CFRunLoopObserver on kCFRunLoopBeforeWaiting that re-removes
    // iTerm's window border the instant a tab/window switch redraws it) and the teardown
    // subroutine. Fresh slots past selLoopCountSlot (the highest offset the blob ever writes) —
    // genuinely free and zeroed, so no collision (the "2040 ldr ceiling" the machPortRef note
    // blamed was a stale-value collision, not an encoding limit). The function table is NOT grown:
    // cbAddrSlot=240 and every offset below it stay put. The three function addresses are prefilled
    // by the installer (they are not in AgentAddresses.table), the two absolute code addresses are
    // patched by the installer like cbAddr/timerCbAddr, and observerRef is written by the entry and
    // read by the teardown.
    public static let observerCreateSlot = 2728      // CFRunLoopObserverCreate (installer prefill)
    public static let observerAddSlot = 2736         // CFRunLoopAddObserver (installer prefill)
    public static let observerInvalidateSlot = 2744  // CFRunLoopObserverInvalidate (installer prefill)
    public static let observerCbAddrSlot = 2752      // absolute, patched by the installer
    public static let observerRefSlot = 2760         // the created observer (entry writes, teardown reads)
    public static let teardownAddrSlot = 2768        // absolute teardown entry (patched; the remove block calls it)
    // P1e: two extra selectors the observer sends after a re-apply to collapse the one-frame lag —
    // invalidateShadow forces the window shadow to recompute this cycle (setHasShadow:NO only marks
    // it), displayIfNeeded forces the decoration redraw. Resolved in a fresh slot each (the packed
    // selector range selWindow..selDecoGetter is full), by the entry after the class.
    public static let selInvalidateShadowSlot = 2824 // invalidateShadow
    public static let selDisplaySlot = 2832          // displayIfNeeded
    // P1f: the setHasShadow: override — the zero-flash path. iTerm re-enables the shadow
    // synchronously on every tab switch (updateForTransparency:), and no reactive hook can beat the
    // window server to the frame; overriding setHasShadow: to force NO on managed windows stops the
    // shadow from ever turning on. The four ObjC-runtime functions are prefilled (out of the
    // function table). shadowImpAddr is the IMP's absolute address (patched). shadowClassTable holds
    // the classes we added the override to (for the teardown restore — CRITICAL).
    public static let classAddMethodSlot = 2840          // class_addMethod (installer prefill)
    public static let classGetMethodImpSlot = 2848       // class_getMethodImplementation (prefill)
    public static let classGetInstanceMethodSlot = 2856  // class_getInstanceMethod (prefill)
    public static let methodSetImpSlot = 2864            // method_setImplementation (prefill)
    public static let selClassSlot = 2872                // the `class` selector (entry-resolved)
    public static let shadowOrigSlot = 2880              // NSWindow's setHasShadow: IMP (entry-resolved)
    public static let shadowImpAddrSlot = 2888           // the override IMP's absolute address (patched)
    public static let shadowClassCountSlot = 2896        // count of classes overridden
    public static let shadowTypesSlot = 2904             // "v@:B\0" — the method type encoding
    public static let shadowClassTableSlot = 2912        // up to 4 overridden classes (4×8), for teardown
    public static let shadowClassTableCount = 4
    public static let shadowClassTableEnd = shadowClassTableSlot + shadowClassTableCount * 8   // 2944
    public static let methodGetImpSlot = 2944            // method_getImplementation (installer prefill)
    public static let nsWindowClassSlot = 2952           // the NSWindow Class (entry-resolved)
    public static let selWindowNumberSlot = 2960         // windowNumber (the IMP's stale-row guard)
    /// Set by the teardown when a class's setHasShadow: was swizzled on top of our override: the
    /// swizzler's saved original is our IMP, so the pages must outlive the agent (the installer skips
    /// vm_deallocate and reports it). A small leak beats a jump into freed memory.
    public static let keepPagesSlot = 2968
    /// Sandbox rendezvous: the target-space RECEIVE port name the controller allocated in the target
    /// and planted here before the entry ran. When non-zero the entry wraps it with
    /// CFMachPortCreateWithPort instead of creating a new port + bootstrap_register (a sandboxed app
    /// may not register — err 1100). 0 → the bootstrap path (the fallback). Fresh slot (past
    /// keepPagesSlot); rzName stays for the fallback.
    public static let plantedPortSlot = 2976
    /// CFMachPortCreateWithPort, installer-prefilled (out of the 22-entry function table, like the
    /// P1e/P1f functions, so cbAddrSlot=240 and the offsets below it do not move).
    public static let cfMachPortCreateWithPortSlot = 2984

    public struct Built {
        public var code: [UInt32]
        /// `pageSize` bytes: manifest, pid, zeros. The installer patches in `cbAddr` and the
        /// table — absolute addresses, knowable only after `vm_allocate`.
        public var state: [UInt8]
        public var cbOff: Int
        /// The wake timer entry (P1c), 16-aligned after the callback; the installer patches
        /// its absolute address into `timerCbAddrSlot` (the timer callback gets no frame
        /// slot, so it finds state through the context pointer, and the arm code finds the
        /// callback address only through state).
        public var timerOff: Int
        /// The P1e border observer and the teardown subroutine, 16-aligned after the timer; the
        /// installer patches their absolute addresses into `observerCbAddrSlot` / `teardownAddrSlot`.
        public var observerOff: Int
        public var teardownOff: Int
        /// The P1f setHasShadow: override IMP, 16-aligned after the teardown. The installer patches
        /// its absolute address into `shadowImpAddrSlot` and patches its first four words (a
        /// movImm64 placeholder) with the state-page base so the IMP can reach the op table.
        public var shadowImpOff: Int
        /// Where each function ends, in words: the audit ranges (the pad to `cbOff` and the
        /// strings after the callback are data, not code).
        public var entryWordCount: Int
        public var cbWordCount: Int
        public var timerWordCount: Int
        public var observerWordCount: Int
        public var teardownWordCount: Int
        public var shadowImpWordCount: Int
    }

    /// Assemble the blob. `pid` is the target's; the entry formats it into the service name with
    /// an integer loop that writes only into RW state. `forceFault` makes the entry's first act
    /// a jump to address 1, for the fault-absorb gate; product code never sets it, as for
    /// `forceFaultForTesting` on `RemoteScript`.
    ///
    /// `namePrefix` is the service name's first 16 bytes — the entry appends the pid digits at
    /// offset 16, so it must be exactly 16 bytes with no NUL inside. `AgentInstaller` passes a
    /// per-install nonce: a removed agent's bootstrap registration outlives it (the entry has
    /// no `bootstrap_delete` — the symbol is not exported; measured 2026-10-21), so a second
    /// install into the same process collides on the name (blob `err` 0x44d, ready=0) forever
    /// after one remove. A fresh prefix per install sidesteps it (measured 2026-10-21: every
    /// app re-run was `entry-not-ready` on every target it had installed into before).
    public static func build(pid: UInt64, forceFault: Bool = false, namePrefix: String = "com.noborder.rz.") -> Built {
        precondition(Array(namePrefix.utf8).count == 16, "the entry appends pid digits at rzName+16")
        var entry = Assembler()
        entry.assembleEntry(forceFault: forceFault)
        var cb = Assembler()
        cb.assembleCallback()
        var timer = Assembler()
        timer.assembleTimer()
        var observer = Assembler()
        observer.assembleObserver()
        var teardown = Assembler()
        teardown.assembleTeardown()
        var shadowImp = Assembler()
        shadowImp.assembleShadowImp()
        let cbOff = (entry.bytes + 15) / 16 * 16
        let timerOff = (cbOff + cb.bytes + 15) / 16 * 16
        let observerOff = (timerOff + timer.bytes + 15) / 16 * 16
        let teardownOff = (observerOff + observer.bytes + 15) / 16 * 16
        // The +8 reserves one 8-byte word immediately before the 16-aligned IMP entry for the agent
        // MAGIC marker. The observer's install guard reads [IMP-8] to recognize a setHasShadow:
        // override left by ANY NoBorder instance (ours or a prior one a force-kill stranded) and
        // reclaim it, instead of mistaking it for a foreign app's own setHasShadow: and skipping.
        let shadowImpOff = (teardownOff + teardown.bytes + 8 + 15) / 16 * 16
        let prefix = Array(namePrefix.utf8) + [0]
        // The P1b selector names, 32 bytes each in slot order (selWindowSlot up), the class
        // name last. The entry resolves them once; the strings are RX code-page data.
        let selNames = ["windowWithWindowNumber:", "setHasShadow:", "hasShadow", "_setCornerRadius:",
                        "setDrawsDecorationView:", "_titlebarContainerView", "standardWindowButton:",
                        "setHidden:", "sharedApplication", "retain", "release", "respondsToSelector:",
                        // The decoration getter is `drawsDecorationView` — no leading underscore.
                        // Measured 2026-10-21: `NSTitlebarContainerView` answers YES to
                        // `drawsDecorationView` and NO to `_drawsDecorationView`; with the
                        // underscore the capability gate failed and decoration was left drawn
                        // (rim=1 after apply, while shadow and corners applied fine).
                        "isHidden", "cornerRadius", "drawsDecorationView", "NSApplication",
                        // P1e: resolved individually by the entry after the class (not in the
                        // selCount preflight loop) — the observer's post-reapply flush selectors.
                        "invalidateShadow", "displayIfNeeded",
                        // P1f: the `class` selector (to get a window's real class, not the KVO
                        // subclass object_getClass would return), the NSWindow class name (whose
                        // setHasShadow: IMP is the override's tail-call target), and `windowNumber`
                        // (the override IMP's guard against a stale, address-reused row).
                        "class", "NSWindow", "windowNumber"]
        var namesBlock = [UInt8]()
        for name in selNames {
            var bytes = Array(name.utf8)
            bytes.append(0)
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 32 - bytes.count))
            namesBlock.append(contentsOf: bytes)
        }

        var code = [UInt32](repeating: 0, count: cbOff / 4)
        let entryWords = entry.resolve()
        for (i, word) in entryWords.enumerated() { code[i] = word }
        let cbWords = cb.resolve()
        code.append(contentsOf: cbWords)
        code.append(contentsOf: [UInt32](repeating: 0, count: timerOff / 4 - code.count))
        let timerWords = timer.resolve()
        code.append(contentsOf: timerWords)
        code.append(contentsOf: [UInt32](repeating: 0, count: observerOff / 4 - code.count))
        let observerWords = observer.resolve()
        code.append(contentsOf: observerWords)
        code.append(contentsOf: [UInt32](repeating: 0, count: teardownOff / 4 - code.count))
        let teardownWords = teardown.resolve()
        code.append(contentsOf: teardownWords)
        code.append(contentsOf: [UInt32](repeating: 0, count: shadowImpOff / 4 - code.count))
        // The agent magic, as the 8 bytes immediately before the IMP entry (little-endian, matching
        // the state page's magicSlot). The install guard reads [IMP-8] and compares it to the blob's
        // own magic to recognize a NoBorder override from any instance. Data, not code — placed in
        // the padding before shadowImpOff, so the audited IMP range (shadowImpOff onward) is clean.
        code[shadowImpOff / 4 - 2] = UInt32(truncatingIfNeeded: magic)
        code[shadowImpOff / 4 - 1] = UInt32(truncatingIfNeeded: magic >> 32)
        let shadowImpWords = shadowImp.resolve()
        code.append(contentsOf: shadowImpWords)
        let pad = (8 - code.count * 4 % 8) % 8
        var tail = [UInt8](repeating: 0, count: pad)
        tail.append(contentsOf: prefix)
        let prefixAt = code.count * 4 + pad
        tail.append(contentsOf: namesBlock)
        let namesAt = prefixAt + prefix.count
        for i in stride(from: 0, to: tail.count, by: 4) {
            var word: UInt32 = 0
            for j in 0..<4 where i + j < tail.count { word |= UInt32(tail[i + j]) << (8 * j) }
            code.append(word)
        }
        // The entry's `adr`s to the prefix and the selector names resolve against the whole layout.
        code = Assembler.resolveAdr(code, fixups: entry.adrFixups,
                                    labels: ["prefix": prefixAt, "selNames": namesAt])

        var state = [UInt8](repeating: 0, count: pageSize)
        func put(_ at: Int, _ value: UInt64) {
            var word = value
            for i in 0..<8 { state[at + i] = UInt8(word & 0xff); word >>= 8 }
        }
        put(magicSlot, magic)
        put(versionSlot, version)
        put(codeLenSlot, UInt64(code.count * 4))
        put(entryOffSlot, 0)
        put(cbOffSlot, UInt64(cbOff))
        put(pidSlot, pid)
        put(cornerOnSlot, UInt64(truncatingIfNeeded: Double(0.01).bitPattern))
        put(cornerOffSlot, UInt64(truncatingIfNeeded: Double(0.0).bitPattern))
        put(wakeDelaySlot, UInt64(truncatingIfNeeded: Double(0.05).bitPattern))
        // P1f: the method type encoding "v@:B" (void; self, _cmd, BOOL) for class_addMethod, as a
        // NUL-terminated C string in a state slot (so the observer passes &state[shadowTypesSlot]
        // without an adr into the code page).
        for (i, byte) in Array("v@:B".utf8).enumerated() { state[shadowTypesSlot + i] = byte }
        return Built(code: code, state: state, cbOff: cbOff, timerOff: timerOff,
                     observerOff: observerOff, teardownOff: teardownOff, shadowImpOff: shadowImpOff,
                     entryWordCount: entryWords.count, cbWordCount: cbWords.count,
                     timerWordCount: timerWords.count, observerWordCount: observerWords.count,
                     teardownWordCount: teardownWords.count, shadowImpWordCount: shadowImpWords.count)
    }
}

// MARK: - the assembler

private extension AgentBlob {
    /// Straight-line words with named labels for the branch instructions. The blob is one
    /// function per page-half with short local loops, so labels are byte offsets inside the
    /// fragment, and `resolve` patches every recorded branch against them.
    struct Assembler {
        enum BranchKind {
            case plain
            case cond(Int)
            case cbz(src: Int, nonzero: Bool)
        }
        private struct Recorded {
            let index: Int
            let kind: BranchKind
            let label: String
        }
        var words: [UInt32] = []
        var labels: [String: Int] = [:]
        private var recorded: [Recorded] = []
        /// The `adr` fixups, resolved by the layout code once the strings' offsets exist. The
        /// entry uses one, for the service-name prefix.
        var adrFixups: [(index: Int, dst: Int, label: String)] = []

        var bytes: Int { words.count * 4 }

        mutating func emit(_ instructions: [UInt32]) { words.append(contentsOf: instructions) }
        mutating func label(_ name: String) {
            precondition(labels[name] == nil, "label \(name) twice")
            labels[name] = words.count * 4
        }
        mutating func branch(_ kind: BranchKind, _ label: String) {
            recorded.append(Recorded(index: words.count, kind: kind, label: label))
            words.append(0)
        }
        mutating func adrLabel(dst: Int, _ label: String) {
            adrFixups.append((words.count, dst, label))
            words.append(0)
        }

        func resolve() -> [UInt32] {
            var out = words
            for item in recorded {
                guard let target = labels[item.label] else {
                    preconditionFailure("branch to undefined label \(item.label)")
                }
                let immediate = target - item.index * 4
                switch item.kind {
                case .plain: out[item.index] = Arc64.b(immediate: immediate)
                case .cond(let cond): out[item.index] = Arc64.bCond(cond, immediate: immediate)
                case .cbz(let src, let nonzero): out[item.index] = Arc64.cbz(src: src, immediate: immediate, nonzero: nonzero)
                }
            }
            return out
        }

        /// Patch the `adr` words after the layout is known: `labels` names byte offsets in the
        /// whole code page, fixup indexes count words from the code page's start.
        static func resolveAdr(_ code: [UInt32], fixups: [(index: Int, dst: Int, label: String)],
                               labels: [String: Int]) -> [UInt32] {
            var out = code
            for fix in fixups {
                guard let target = labels[fix.label] else { preconditionFailure("adr to undefined \(fix.label)") }
                out[fix.index] = Arc64.adr(dst: fix.dst, immediate: target - fix.index * 4)
            }
            return out
        }
    }
}

// MARK: - the code

/// Table slot addresses, in `AgentAddresses.table` order.
private let tCreate = AgentBlob.tableSlot
private let tGetPort = AgentBlob.tableSlot + 8
private let tSource = AgentBlob.tableSlot + 16
private let tMain = AgentBlob.tableSlot + 24
private let tAdd = AgentBlob.tableSlot + 32
private let tMsg = AgentBlob.tableSlot + 40
private let tTgs = AgentBlob.tableSlot + 48
private let tReg = AgentBlob.tableSlot + 56
private let tLook = AgentBlob.tableSlot + 64
private let tModes = AgentBlob.tableSlot + 72
private let tSelf = AgentBlob.tableSlot + 80
private let tInvalidate = AgentBlob.tableSlot + 88
private let tRelease = AgentBlob.tableSlot + 96
private let tMsgSend = AgentBlob.tableSlot + 104
private let tSelReg = AgentBlob.tableSlot + 112
private let tGetClass = AgentBlob.tableSlot + 120
private let tCopyMode = AgentBlob.tableSlot + 128
private let tDefaultMode = AgentBlob.tableSlot + 136
private let tTimerCreate = AgentBlob.tableSlot + 144
private let tTimerInvalidate = AgentBlob.tableSlot + 152
private let tTimeNow = AgentBlob.tableSlot + 160
private let tAddTimer = AgentBlob.tableSlot + 168

private extension AgentBlob.Assembler {

    /// The entry: `x0` is the state page. It runs on the app's main queue as the dispatched
    /// block's body, on a frame the block prologue left 16-aligned, and returns — the block's
    /// flag write is what the installer's completion poll reads (that is `entryDone`; the blob's
    /// own `ready` slot is the separate fact verdict 6 asks for).
    ///
    /// Registers: x17 is the state base, x0…x9, x15 and x16 scratch. No callee-saved register
    /// is touched, and x18 is left alone — Apple reserves it (verdict 6 Q1: not a storage
    /// guarantee, so not used). After every call x17 is re-loaded from the stack slot, because
    /// x16/x17 are the ABI's scratch across calls.
    mutating func assembleEntry(forceFault: Bool) {
        if forceFault {
            // The fault-absorb gate: an address no process has mapped, as in Trampoline.
            emit([Arc64.movz(dst: 16, value: 1), Arc64.br(16)])
        }
        emit([Arc64.subImm(dst: 31, src: 31, imm: 80),
              Arc64.stp(dst: 29, dst2: 30, base: 31, offset: 64),
              Arc64.addImm(dst: 29, src: 31, imm: 64)])
        // CFMachPortContext {version 0, info = state, retain/release/copyDescription 0} at [sp,#0],
        // the Boolean out-param at [sp,#40], the state base at [sp,#56], the CFMachPort at [sp,#48].
        emit([Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 0),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 16),
              Arc64.strZero(base: 31, offset: 32),
              Arc64.str(src: 0, base: 31, offset: 56),
              Arc64.str(src: 0, base: 31, offset: 8)])
        // P1b preflight (codex verdict: resolve selectors BEFORE publishing the source): the
        // 12 window selectors and the NSApplication class, once, from the RX names block —
        // sel_registerName is idempotent and caching the SELs keeps the op path out of it.
        // A nil answer is a checked failure (err=1104): nothing was created, nothing published.
        adrLabel(dst: 1, "selNames")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.movz(dst: 15, value: UInt16(AgentBlob.selCount)),
              Arc64.movz(dst: 2, value: UInt16(AgentBlob.selWindowSlot)),
              Arc64.addReg(dst: 2, lhs: 2, rhs: 17),   // x2 = state + selWindowSlot
              Arc64.str(src: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.str(src: 2, base: 17, offset: AgentBlob.selStoreCursorSlot),
              Arc64.str(src: 15, base: 17, offset: AgentBlob.selLoopCountSlot)])
        label("selLoop")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.movReg(dst: 0, src: 1),
              Arc64.ldr(dst: 16, base: 17, offset: tSelReg),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "failSel")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.selStoreCursorSlot),
              Arc64.str(src: 0, base: 2, offset: 0),
              Arc64.addImmBytes(dst: 2, src: 2, imm: 8),
              Arc64.str(src: 2, base: 17, offset: AgentBlob.selStoreCursorSlot),
              // x1 is caller-saved: `sel_registerName` clobbers it (measured 2026-10-21: the
              // loop advanced the cursor from the clobbered register and the third call read
              // x0 = 0x28). Re-load the cursor from state, advance, store.
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.addImmBytes(dst: 1, src: 1, imm: 32),
              Arc64.str(src: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.ldr(dst: 15, base: 17, offset: AgentBlob.selLoopCountSlot),
              Arc64.subImmBytes(dst: 15, src: 15, imm: 1),
              Arc64.str(src: 15, base: 17, offset: AgentBlob.selLoopCountSlot)])
        branch(.cbz(src: 15, nonzero: false), "selClass")
        branch(.plain, "selLoop")
        label("selClass")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.movReg(dst: 0, src: 1),        // the cursor lands on the class name
              Arc64.ldr(dst: 16, base: 17, offset: tGetClass),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "failSel")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.nsAppClassSlot)])
        // P1e: resolve the two flush selectors (names after the class in the block). Advance the
        // cursor past the class, sel_registerName each into its fresh slot. A nil answer is the
        // same checked failure as the preflight (failSel: err=1104, nothing published).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.addImmBytes(dst: 1, src: 1, imm: 32),   // class -> "invalidateShadow"
              Arc64.str(src: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.movReg(dst: 0, src: 1),
              Arc64.ldr(dst: 16, base: 17, offset: tSelReg),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "failSel")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.selInvalidateShadowSlot),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.addImmBytes(dst: 1, src: 1, imm: 32),   // -> "displayIfNeeded"
              Arc64.str(src: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.movReg(dst: 0, src: 1),
              Arc64.ldr(dst: 16, base: 17, offset: tSelReg),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "failSel")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.selDisplaySlot)])
        // P1f: resolve the `class` selector (index 18) → selClassSlot.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.addImmBytes(dst: 1, src: 1, imm: 32),   // displayIfNeeded -> "class"
              Arc64.str(src: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.movReg(dst: 0, src: 1),
              Arc64.ldr(dst: 16, base: 17, offset: tSelReg),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "failSel")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.selClassSlot)])
        // objc_getClass("NSWindow") (index 19) — its setHasShadow: IMP is the override's tail-call
        // target (iTerm's window classes don't override setHasShadow:, so NSWindow's is inherited).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.addImmBytes(dst: 1, src: 1, imm: 32),   // "class" -> "NSWindow"
              Arc64.str(src: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.movReg(dst: 0, src: 1),
              Arc64.ldr(dst: 16, base: 17, offset: tGetClass),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "failSel")
        // Keep the NSWindow Class: the observer must never add the override to NSWindow itself
        // (that would suppress every window in the app), and the IMP guard compares against it.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.nsWindowClassSlot)])
        // class_getMethodImplementation(NSWindowClass, setHasShadow:) → shadowOrig. x0 = the class.
        // No nil check: it answers nil only for a nil class (refused just above), and an
        // unimplemented selector answers _objc_msgForward, never nil.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selShadowSlot),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.classGetMethodImpSlot),
              Arc64.blr(16)])
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.shadowOrigSlot)])
        // Resolve `windowNumber` (index 20) → selWindowNumberSlot (the IMP's stale-row guard).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.addImmBytes(dst: 1, src: 1, imm: 32),   // "NSWindow" -> "windowNumber"
              Arc64.str(src: 1, base: 17, offset: AgentBlob.selNameCursorSlot),
              Arc64.movReg(dst: 0, src: 1),
              Arc64.ldr(dst: 16, base: 17, offset: tSelReg),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "failSel")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.selWindowNumberSlot),
              // x0 held the SEL; the code below addresses state through x0. Restore it.
              Arc64.ldr(dst: 0, base: 31, offset: 56)])
        // Sandbox rendezvous: when the controller planted a receive right (plantedPort != 0), wrap
        // it with CFMachPortCreateWithPort — no bootstrap port, no service name, no register, so a
        // sandboxed app (which may not bootstrap_register — err 1100) comes up live. Otherwise the
        // bootstrap path runs: get the task's bootstrap port, create a fresh CFMachPort, register
        // its name. Both converge at portMade (the CFMachPort in [sp,48]).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.plantedPortSlot),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(1), "plantedCreate")   // b.ne: a port was planted
        // task_get_special_port(mach_task_self_, 4 /* BOOTSTRAP_PORT */, &state.bs) — three
        // arguments (measured 2026-10-20: with x0=state passed as the target task, the kernel
        // answers MACH_SEND_INVALID_DEST 0x10000003). The state base comes back from the frame.
        emit([Arc64.ldr(dst: 0, base: 31, offset: 56),
              Arc64.ldr(dst: 16, base: 0, offset: tTgs),
              Arc64.ldr(dst: 17, base: 0, offset: tSelf),
              Arc64.ldr(dst: 0, base: 17, offset: 0),
              Arc64.movz(dst: 1, value: 4),
              Arc64.ldr(dst: 2, base: 31, offset: 56),
              Arc64.addImm(dst: 2, src: 2, imm: AgentBlob.bsSlot),
              Arc64.blr(16),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(1), "fail")
        // CFMachPortCreate(NULL, cbAddr, &ctx, &available) — the callback in the create context
        // (the P1a-0 shape); delivery still needs the source, which comes last.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 16, base: 17, offset: tCreate),
              Arc64.movz(dst: 0, value: 0),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.cbAddrSlot),
              Arc64.addImm(dst: 2, src: 31, imm: 0),
              Arc64.addImm(dst: 3, src: 31, imm: 40),
              Arc64.blr(16),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(0), "failNull")
        branch(.plain, "portMade")
        // Planted path: CFMachPortCreateWithPort(NULL, plantedName, cbAddr, &ctx, &available) wraps
        // the controller's receive right. Same context and callback as the bootstrap create.
        label("plantedCreate")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.cfMachPortCreateWithPortSlot),
              Arc64.movz(dst: 0, value: 0),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.plantedPortSlot),
              Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.cbAddrSlot),
              Arc64.addImm(dst: 3, src: 31, imm: 0),
              Arc64.addImm(dst: 4, src: 31, imm: 40),
              Arc64.blr(16),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(0), "failNull")
        label("portMade")
        emit([Arc64.str(src: 0, base: 31, offset: 48),
              // x17 is scratch across calls (measured 2026-10-20: a store through the
              // create-clobbered x17 wrote 0x1f143b888 and faulted) — reload after every call.
              Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 16, base: 17, offset: tGetPort),
              Arc64.ldr(dst: 0, base: 31, offset: 48),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.agentPortSlot),
              // Keep the CFMachPort reference for removal (the source slot cannot reach the
              // port; CFMachPortInvalidate takes the port).
              Arc64.ldr(dst: 0, base: 31, offset: 48),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.machPortRefSlot)])
        // Planted path: the channel already exists (the controller holds the send), so skip the
        // service name and bootstrap_register entirely — straight to adding the run-loop source.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.plantedPortSlot),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(1), "portSource")   // b.ne: planted — no name, no register
        // No self-insert on the CFMachPort name: `CFMachPortGetPort` answers a plain send right
        // (measured 2026-10-20: its `mach_port_type` is 0x10000 = SEND, no rights), and a
        // MAKE_SEND insert on it is `KERN_INVALID_RIGHT` (17). The linked agent P1a-0 shipped
        // the same shape: register the returned name directly, insert nothing on it.
        // "com.noborder.rz." from RX, then the pid in decimal, all writes into RW (verdict 6 Q4:
        // the digits must land on the state page). Reverse-scan the digits into place.
        adrLabel(dst: 1, "prefix")
        emit([Arc64.addImm(dst: 2, src: 17, imm: AgentBlob.rzNameSlot),
              Arc64.ldr(dst: 3, base: 1, offset: 0),
              Arc64.str(src: 3, base: 2, offset: 0),
              Arc64.ldr(dst: 3, base: 1, offset: 8),
              Arc64.str(src: 3, base: 2, offset: 8),
              Arc64.ldrb(dst: 3, base: 1, offset: 16),
              Arc64.strb(src: 3, base: 2, offset: 16),
              Arc64.ldr(dst: 3, base: 17, offset: AgentBlob.pidSlot),
              Arc64.addImm(dst: 4, src: 2, imm: 16),
              Arc64.movz(dst: 16, value: 10)])
        // Digits are consecutive bytes from rzName+16 — the shipped version stored at [x4,#8]
        // with x4 += 8, so the first digit landed at +24 behind the prefix's NUL at +16 and the
        // registered name was the bare prefix (agent-dump, 2026-10-20). q*10 is a `mul`: the
        // madd addend 31 was SP, which made every digit garbage.
        label("itoa")
        emit([Arc64.udiv(dst: 5, lhs: 3, rhs: 16),
              Arc64.mul(dst: 6, lhs: 5, rhs: 16),
              Arc64.subReg(dst: 7, lhs: 3, rhs: 6),
              Arc64.addImmBytes(dst: 7, src: 7, imm: 48),
              Arc64.strb(src: 7, base: 4, offset: 0),
              Arc64.addImmBytes(dst: 4, src: 4, imm: 1),
              Arc64.movReg(dst: 3, src: 5)])
        branch(.cbz(src: 3, nonzero: true), "itoa")
        // x4 = one past the last digit. The reverse is a two-cursor swap — the shipped
        // forward-write reverse read back bytes it had already overwritten (pid 9280 produced
        // "9229", agent-dump 2026-10-20). The cursors stay in the audited set: x4/x5 read+write
        // the left byte, x8/x9 the right (the code audit admits stores through x4/x8 only).
        // x4 = one past the last digit; the cursors walk inward from start and x4-1.
        emit([Arc64.addImm(dst: 5, src: 2, imm: 16),
              Arc64.subImmBytes(dst: 9, src: 4, imm: 1),   // right cursor = last digit byte
              Arc64.movReg(dst: 8, src: 9),
              Arc64.addImm(dst: 4, src: 2, imm: 16)])      // …then x4 restarts at the start
        label("rev")
        emit([Arc64.ldrb(dst: 7, base: 5, offset: 0),
              Arc64.ldrb(dst: 16, base: 9, offset: 0),
              Arc64.strb(src: 16, base: 4, offset: 0),
              Arc64.strb(src: 7, base: 8, offset: 0),
              Arc64.addImmBytes(dst: 4, src: 4, imm: 1),
              Arc64.addImmBytes(dst: 5, src: 5, imm: 1),
              Arc64.subImmBytes(dst: 8, src: 8, imm: 1),
              Arc64.subImmBytes(dst: 9, src: 9, imm: 1),
              Arc64.cmpReg(lhs: 5, rhs: 9)])
        branch(.cond(3), "rev")   // b.lo (cond 3 = LO/CC): continue while the cursors have not crossed
        // The NUL goes at the run's end: after the loop x9 = (end−1) − iterations, so
        // end = x9 + (x4 − start) + 1. (Measured 2026-10-20: storing the NUL at [x4] put it at
        // byte 17 for a 5-digit pid — the registered name lost its digits.) x7 is the temp;
        // the store base stays in the audited x8 set.
        emit([Arc64.subReg(dst: 7, lhs: 4, rhs: 2),
              Arc64.subImmBytes(dst: 7, src: 7, imm: 16),   // x7 = iterations (x4 − start)
              Arc64.addReg(dst: 8, lhs: 9, rhs: 7),
              Arc64.addImmBytes(dst: 8, src: 8, imm: 1),
              Arc64.strb(src: 31, base: 8, offset: 0)])
        // bootstrap_register(bs, "com.noborder.rz.<pid>", port). A name in use (a second install
        // on one pid) is the checked failure: err records it, the source is never added, and
        // `ready` stays 0 — the no-duplicate-bootstrap gate.
        emit([Arc64.ldr(dst: 16, base: 17, offset: tReg),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.bsSlot),
              Arc64.addImm(dst: 1, src: 17, imm: AgentBlob.rzNameSlot),
              Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.agentPortSlot),
              Arc64.blr(16),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(1), "failMP")
        // Published: source last, so every checked failure above leaves the run loop untouched.
        label("portSource")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 16, base: 17, offset: tSource),
              Arc64.movz(dst: 0, value: 0),
              Arc64.ldr(dst: 1, base: 31, offset: 48),
              Arc64.movz(dst: 2, value: 0),
              Arc64.blr(16),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(0), "failMPSource")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.srcRefSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMain),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.srcRefSlot),
              // kCFRunLoopCommonModes is a variable: load the CFStringRef, then call (verdict 6).
              Arc64.ldr(dst: 16, base: 17, offset: tModes),
              Arc64.ldr(dst: 2, base: 16, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: tAdd),
              Arc64.blr(16)])
        // P1e: create + add the border observer BEFORE publishing ready, so ready==1 means the
        // whole agent — op source and observer — is live (the teardown still guards observerRef as
        // belt-and-suspenders). A nil create is non-fatal: the op path still works and the
        // ScanLoop slow re-assert covers the border, so skip straight to ready. The context
        // {version 0, info = state, retain 0, release 0, copy 0} is staged at [sp,#0..39] (the
        // CFMachPortContext there is long dead). Added in DEFAULT mode only — the observer must
        // fire where mutation is safe, never in a tracking/modal loop.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.stp(dst: 31, dst2: 17, base: 31, offset: 0),   // version 0, info = state
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 16),  // retain 0, release 0
              Arc64.strZero(base: 31, offset: 32),                 // copyDescription 0
              Arc64.movz(dst: 0, value: 0),                        // allocator
              Arc64.movz(dst: 1, value: 0x20),                     // kCFRunLoopBeforeWaiting
              Arc64.movz(dst: 2, value: 1),                        // repeats = true
              // order 1999999 — run LATE, just before CoreAnimation's transaction-commit observer
              // (order 2000000), so the re-removal is the last word before compositing no matter
              // when in the cycle iTerm redrew the border (the race that made the flash
              // intermittent at order 0).
              Arc64.movz(dst: 3, value: 0x847F),
              Arc64.movk(dst: 3, value: 0x1E, shift: 16),          // 0x1E847F = 1999999
              Arc64.ldr(dst: 4, base: 17, offset: AgentBlob.observerCbAddrSlot),
              Arc64.addImm(dst: 5, src: 31, imm: 0),               // &context
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.observerCreateSlot),
              Arc64.blr(16),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(0), "obsEntrySkip")   // b.eq: create returned nil — go ready without it
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.observerRefSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMain),
              Arc64.blr(16),                                       // x0 = the main run loop
              Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.observerRefSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tDefaultMode),
              Arc64.ldr(dst: 2, base: 16, offset: 0),              // kCFRunLoopDefaultMode value
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.observerAddSlot),
              Arc64.blr(16)])
        label("obsEntrySkip")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.movz(dst: 16, value: 1),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.readySlot)])
        branch(.plain, "done")
        label("fail")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.errSlot)])
        branch(.plain, "done")
        label("failNull")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.movz(dst: 16, value: 1),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.errSlot)])
        branch(.plain, "done")
        // A selector the system will not name, or no NSApplication class: the preflight ran
        // before anything was created, so record err and leave — no port, no source, no ready.
        label("failSel")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.movz(dst: 16, value: 1104),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.errSlot)])
        branch(.plain, "done")
        // A port exists and a name may: give CF back what it made (invalidate then release, the
        // documented order). No right to deallocate — the entry inserted nothing.
        label("failMP")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.errSlot)])
        branch(.plain, "cleanupMP")
        label("failMPSource")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.movz(dst: 16, value: 1),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.errSlot)])
        label("cleanupMP")
        emit([Arc64.ldr(dst: 16, base: 17, offset: tInvalidate),
              Arc64.ldr(dst: 0, base: 31, offset: 48),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 56),
              Arc64.ldr(dst: 16, base: 17, offset: tRelease),
              Arc64.ldr(dst: 0, base: 31, offset: 48),
              Arc64.blr(16)])
        label("done")
        emit([Arc64.ldp(dst: 29, dst2: 30, base: 31, offset: 64),
              Arc64.addImm(dst: 31, src: 31, imm: 80),
              Arc64.ret()])
    }
}

private extension AgentBlob.Assembler {
    /// The callback, on the app's main thread: `x0` port, `x1` msg (borrowed for the call only —
    //  the run loop frees it, so every byte used after is copied out), `x2` size, `x3` info =
    /// the state page. The frame is 176 bytes: the handshake and the ACKs are built at [sp,#0]
    /// (one message in flight at a time, the op ACK the longest at 56), the msg pointer at
    /// [sp,#72], the state base at [sp,#64], the op-path slots at [sp,#80..152], the saved pair
    /// at [sp,#160]. Callee-saved registers and x18 stay untouched. Every live value crosses a
    /// call in a frame slot: x0-x17 are caller-saved scratch (measured 2026-10-21).
    mutating func assembleCallback() {
        emit([Arc64.subImm(dst: 31, src: 31, imm: 176),
              Arc64.stp(dst: 29, dst2: 30, base: 31, offset: 160),
              Arc64.addImm(dst: 29, src: 31, imm: 160),
              Arc64.str(src: 1, base: 31, offset: 72),
              Arc64.str(src: 3, base: 31, offset: 64),
              // The callback counter: every invocation counts, including messages the size and
              // id gates reject. It answers "did delivery happen" separately from "did the
              // handler accept" — the pair that pinned the 2026-10-20 b.ls bug (cbEntries=1,
              // token=0). The slot was mpRef (unused by design; the CFMachPort reference lives
              // on the entry frame); it is the counter now.
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.cbEntriesSlot),
              Arc64.addImmBytes(dst: 16, src: 16, imm: 1),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.cbEntriesSlot),
              Arc64.str(src: 2, base: 17, offset: AgentBlob.dbgSizeSlot),
              Arc64.ldr32(dst: 16, base: 1, offset: 20),
              Arc64.cmpImm(src: 16, imm: 2004)])
        // 2004 is HELLO; 3001/3002 are op requests; 2001 pings and everything else go to the
        // "ping" label below, which answers 2001 and drops the rest.
        branch(.cond(0), "hello")
        emit([Arc64.ldr32(dst: 16, base: 1, offset: 20),
              Arc64.cmpImm(src: 16, imm: 3001)])
        branch(.cond(0), "opA")
        emit([Arc64.ldr32(dst: 16, base: 1, offset: 20),
              Arc64.cmpImm(src: 16, imm: 3002)])
        branch(.cond(0), "opR")
        emit([Arc64.ldr32(dst: 16, base: 1, offset: 20),
              Arc64.cmpImm(src: 16, imm: 4001)])   // the wake timer's internal APPLY_PENDING
        branch(.cond(0), "drainPending")
        branch(.plain, "ping")

        label("hello")
        // HELLO: 96 bytes (header, token, 64-byte service name). Size-checked before any field.
        emit([Arc64.cmpImm(src: 2, imm: 96)])
        branch(.cond(3), "ret")   // b.lo: a short HELLO says nothing; leave the counter alone
        // (b.ls shipped by mistake 2026-10-20: a valid 96-byte HELLO is lower-or-EQUAL, so LS
        // bailed on every real HELLO — cb fired, touched nothing, returned. Found with the
        // callback counter: cbEntries=1, token=0.)
        // The token is STAGED in a frame slot and only published after the name scan and the
        // look-up succeed (codex P1c review: a failed HELLO must not replace the session while
        // the old tool port stays in place). The slot is the callback's spare (152).
        emit([Arc64.ldr(dst: 16, base: 1, offset: 24),
              Arc64.str(src: 16, base: 31, offset: 152)])
        // Copy the name out of the borrowed buffer, then require a NUL inside it before any
        // string API sees it (verdict 6).
        for i in 0..<8 {
            emit([Arc64.ldr(dst: 16, base: 1, offset: 32 + 8 * i),
                  Arc64.str(src: 16, base: 17, offset: AgentBlob.toolNameSlot + 8 * i)])
        }
        emit([Arc64.addImm(dst: 9, src: 17, imm: AgentBlob.toolNameSlot),
              Arc64.movz(dst: 6, value: 64)])
        label("scan")
        emit([Arc64.ldrb(dst: 16, base: 9, offset: 0)])
        branch(.cbz(src: 16, nonzero: false), "found")
        emit([Arc64.addImmBytes(dst: 9, src: 9, imm: 1),
              Arc64.subImmBytes(dst: 6, src: 6, imm: 1)])
        branch(.cbz(src: 6, nonzero: true), "scan")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.movz(dst: 16, value: 1),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.errHandshakeSlot)])
        branch(.plain, "ret")
        label("found")
        // bootstrap_look_up(bs, state.toolName, &state.toolPort): the tool's registered service,
        // named in the HELLO itself — no task-port operation on this path, ever.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: tLook),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.bsSlot),
              Arc64.addImm(dst: 1, src: 17, imm: AgentBlob.toolNameSlot),
              Arc64.addImm(dst: 2, src: 17, imm: AgentBlob.toolPortSlot),
              Arc64.blr(16),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(1), "failHello")
        // The look-up succeeded: publish the staged token together with the new port (the
        // session flips atomically on this single-threaded path).
        emit([Arc64.ldr(dst: 16, base: 31, offset: 152),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.tokenSlot)])
        // Disposition COPY_SEND (19), not the linked agent's MOVE_SEND (17): CFMachPortGetPort
        // answered a single-reference plain send, and a hand-written blob has no ARC owner
        // re-acquiring it (codex verdict, 2026-10-20: the linked agent survives repeated moves
        // only because the CFMachPort's ARC keeps the reference alive). The copy leaves the
        // name intact, so every HELLO's handshake sends it (measured: the first move consumed
        // the name; a MAKE_SEND insert on a plain send is KERN_INVALID_RIGHT).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 0),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 16),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 32)])
        // The complex shape: MACH_MSGH_BITS_COMPLEX (1<<31) + 0x13, count@24, desc name@28 /
        // disposition@38 / type@39, token@40 — a disposition byte in the type slot is
        // MACH_SEND_INVALID_TYPE, measured, so these offsets are not negotiable. 0x13 is
        // MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_PORT_NONE): send on the held
        // send right, no reply port. (mach_msg's send options — SEND_MSG, TIMEOUT — are
        // separate trap arguments, not msgh_bits bits; the 2026-10-20 note here read the
        // low half as SEND_MSG|TIMEOUT|VOUCHER_CONTROL and was wrong.) Parity rule, measured:
        // the local disposition must match the name's parity — 0x300 (MAKE_SEND in the local
        // slot) on launchd's send-parity look-up name answers MACH_SEND_INVALID_DEST
        // 0x10000010. Self-send matrix 2026-10-20: 0x13 enqueues on msgh_remote (queue +1
        // for a bound receive-parity name and for an extracted send-parity name; a name with
        // no right answers MACH_SEND_INVALID_HEADER). The blob runs on the app's main thread
        // and this shape answers kr 0 there; byte-identical 0x13 sends from the probe binary
        // answer 0x10000010 — an OBSERVED binary-shape-dependent discrepancy, kernel
        // mechanism uncharacterized.
        emit([Arc64.movz(dst: 16, value: 0x13),
              Arc64.movk(dst: 16, value: 0x8000, shift: 16),
              Arc64.str(src: 16, base: 31, offset: 0),
              Arc64.movz(dst: 16, value: 48),
              Arc64.str32(src: 16, base: 31, offset: 4),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.toolPortSlot),
              Arc64.str(src: 16, base: 31, offset: 8),
              // {voucher 0, msgh_id 2003} as one 8-byte store: movImm64 lays out the id in the
              // header's upper half.
              ] + Arc64.movImm64(dst: 16, value: UInt64(2003) << 32) + [
              Arc64.str(src: 16, base: 31, offset: 16),
              Arc64.movz(dst: 16, value: 1),
              Arc64.str32(src: 16, base: 31, offset: 24),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.agentPortSlot),
              Arc64.str32(src: 16, base: 31, offset: 28),
              Arc64.movz(dst: 16, value: 19),   // MACH_MSG_TYPE_COPY_SEND (codex Q1: plain send, no ARC owner)
              Arc64.strb(src: 16, base: 31, offset: 38),
              Arc64.strb(src: 31, base: 31, offset: 39),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.tokenSlot),
              Arc64.str(src: 16, base: 31, offset: 40)])
        // SEND with the TIMEOUT option and timeout 0: the send never waits on main (verdict 6
        // Q5). The kr lands in errHandshake; the tool notices by not receiving the handshake.
        emit([Arc64.ldr(dst: 16, base: 17, offset: tMsg),
              Arc64.addImm(dst: 0, src: 31, imm: 0),
              Arc64.movz(dst: 1, value: 0x11),
              Arc64.movz(dst: 2, value: 48),
              Arc64.movz(dst: 3, value: 0),
              Arc64.movz(dst: 4, value: 0),
              Arc64.movz(dst: 5, value: 0),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.errHandshakeSlot)])
        branch(.plain, "ret")
        label("failHello")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.errHandshakeSlot)])
        branch(.plain, "ret")
        label("ping")
        emit([Arc64.ldr32(dst: 16, base: 1, offset: 20),
              Arc64.cmpImm(src: 16, imm: 2001)])
        branch(.cond(1), "ret")
        emit([Arc64.cmpImm(src: 2, imm: 40)])
        branch(.cond(3), "ret")   // b.lo: a short ping reads nothing — the seq@24 load needs 40
        // Count, then the 40-byte plain ACK to the tool's registered port (COPY_SEND dest: the
        // reference stays for every later ping; msgh_local PORT_NONE — the ACK carries no rights).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.counterSlot),
              Arc64.addImmBytes(dst: 16, src: 16, imm: 1),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.counterSlot),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 0),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 16),
              Arc64.strZero(base: 31, offset: 32),
              Arc64.movz(dst: 16, value: 0x13),   // COPY_SEND dest, PORT_NONE local (see handshake above)
              Arc64.str(src: 16, base: 31, offset: 0),
              Arc64.movz(dst: 16, value: 40),
              Arc64.str32(src: 16, base: 31, offset: 4),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.toolPortSlot),
              Arc64.str(src: 16, base: 31, offset: 8),
              Arc64.movz(dst: 16, value: 2002),
              Arc64.str32(src: 16, base: 31, offset: 20),
              Arc64.ldr(dst: 16, base: 1, offset: 24),
              Arc64.str(src: 16, base: 31, offset: 24),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.counterSlot),
              Arc64.str(src: 16, base: 31, offset: 32),
              Arc64.ldr(dst: 16, base: 17, offset: tMsg),
              Arc64.addImm(dst: 0, src: 31, imm: 0),
              Arc64.movz(dst: 1, value: 0x11),
              Arc64.movz(dst: 2, value: 40),
              Arc64.movz(dst: 3, value: 0),
              Arc64.movz(dst: 4, value: 0),
              Arc64.movz(dst: 5, value: 0),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.errAckSlot)])
        // The ping path ends by returning. Without this branch the ACK's last store falls
        // straight into the op path below: x1 is the ping's message pointer (not a request),
        // x2 the ACK's header (0x28_00000013 — never < 64, so the size gate passes), and the
        // gen load faults on the garbage pointer (measured 2026-10-21: SIGSEGV, host dies on
        // the FIRST ping).
        branch(.plain, "ret")
        // The op path (P1b): apply/restore requests (msgh_id 3001/3002, 64 bytes) mutate the
        // window through the ObjC runtime — the same shipped apply set as the remote-exec engine
        // (shadow off, corner 0.01, decoration off, buttons per mask) — and answer a 56-byte ACK
        // {gen, wid, status, session}. Mutations run only with the run loop in its default mode
        // and depth 0 (the codex gate: commonModes is not a safety predicate); anything else is
        // deferred with the row marked pending, and any later request completes pending rows.
        // Every live value lives in a frame slot and is reloaded after every call.
        label("opA")
        emit([Arc64.movz(dst: 9, value: 1)])
        branch(.plain, "opGo")
        label("opR")
        emit([Arc64.movz(dst: 9, value: 2)])
        label("opGo")
        // The drain flag at slot 56: 0 on the tool-request path (ACKs live), 1 while draining
        // (the timer's work — the ACK is answered by gen replay, not unsolicited). 152 is taken
        // (HELLO token staging, the row-scan cursor, the capture button temp): a row pointer
        // left in 152 read as "draining" and killed every op ACK (measured 2026-10-21).
        emit([Arc64.strZero(base: 31, offset: 56),
              Arc64.cmpImm(src: 2, imm: 64)])
        branch(.cond(3), "ret")   // b.lo: a short op request reads nothing
        // Copy the fields out, then the session gate: the token the last HELLO registered.
        emit([Arc64.ldr(dst: 16, base: 1, offset: 24),
              Arc64.str(src: 16, base: 31, offset: 80),
              Arc64.ldr(dst: 16, base: 1, offset: 32),
              Arc64.str(src: 16, base: 31, offset: 88),
              Arc64.str(src: 9, base: 31, offset: 96),
              Arc64.ldr(dst: 16, base: 1, offset: 48),
              Arc64.str(src: 16, base: 31, offset: 104),
              Arc64.ldr(dst: 16, base: 1, offset: 56),
              Arc64.str(src: 16, base: 31, offset: 112)])
        // Planted rendezvous: the op carries a reply port in its incoming msgh_remote_port (@8).
        // When present, refresh toolPort so the ACK returns to this sender — the bootstrap tool
        // sends 0 here and keeps the toolPort its HELLO registered. (A sandboxed install has no
        // HELLO, so tokenSlot is 0 and the planted client sends session 0 to match the gate below.)
        emit([Arc64.ldr32(dst: 16, base: 1, offset: 8),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(0), "opReplyKept")   // b.eq: no reply port — keep the registered toolPort
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.toolPortSlot)])
        label("opReplyKept")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.tokenSlot),
              Arc64.ldr(dst: 0, base: 31, offset: 112),
              Arc64.cmpReg(lhs: 0, rhs: 16)])
        branch(.cond(1), "ret")   // forged/stale session: counted, silent
        // Row scan: find wid; if absent and apply, the first free row.
        emit([Arc64.movz(dst: 15, value: UInt16(AgentBlob.opTableCount)),
              Arc64.str(src: 15, base: 31, offset: 144),
              Arc64.movz(dst: 2, value: UInt16(AgentBlob.opTableSlot)),
              Arc64.addReg(dst: 2, lhs: 2, rhs: 17),
              Arc64.str(src: 2, base: 31, offset: 152)])
        label("rowScan")
        emit([Arc64.ldr(dst: 2, base: 31, offset: 152),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowWid),
              Arc64.ldr(dst: 1, base: 31, offset: 88),
              Arc64.cmpReg(lhs: 0, rhs: 1)])
        branch(.cond(0), "rowFound")
        emit([Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(1), "rowNext")   // occupied by another wid
        // A free row: apply takes it (init), restore has nothing to restore (no-original).
        emit([Arc64.ldr(dst: 0, base: 31, offset: 96),
              Arc64.cmpImm(src: 0, imm: 2)])
        branch(.cond(0), "ackNoOriginal")
        // Initialize the row at [sp,152] for this apply. Reached by the free-row path and by the
        // eviction scan (a reused completed-restore row), so it reloads the cursor and clears the
        // fields that live outside the capture gate — rowObject and rowAppShadow — which a reused
        // row would otherwise carry over stale (the orig* fields are re-captured, bit 1 is cleared).
        label("initRow")
        emit([Arc64.ldr(dst: 2, base: 31, offset: 152),
              Arc64.ldr(dst: 0, base: 31, offset: 88),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowWid),
              Arc64.ldr(dst: 0, base: 31, offset: 96),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowOp),
              Arc64.ldr(dst: 0, base: 31, offset: 104),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowButtons),
              Arc64.ldr(dst: 0, base: 31, offset: 80),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowDesiredGen),
              Arc64.strZero(base: 2, offset: AgentBlob.rowDoneGen),
              Arc64.strZero(base: 2, offset: AgentBlob.rowLastStatus),
              Arc64.strZero(base: 2, offset: AgentBlob.rowObject),
              Arc64.strZero(base: 2, offset: AgentBlob.rowAppShadow),
              Arc64.movz(dst: 0, value: 1),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.str(src: 2, base: 31, offset: 120)])
        branch(.plain, "modeGate")
        label("rowNext")
        emit([Arc64.ldr(dst: 2, base: 31, offset: 152),
              Arc64.addImmBytes(dst: 2, src: 2, imm: AgentBlob.opEntryBytes),
              Arc64.str(src: 2, base: 31, offset: 152),
              Arc64.ldr(dst: 15, base: 31, offset: 144),
              Arc64.subImmBytes(dst: 15, src: 15, imm: 1),
              Arc64.str(src: 15, base: 31, offset: 144)])
        branch(.cbz(src: 15, nonzero: false), "scanDone")
        branch(.plain, "rowScan")
        label("scanDone")
        emit([Arc64.ldr(dst: 0, base: 31, offset: 96),
              Arc64.cmpImm(src: 0, imm: 2)])
        branch(.cond(0), "ackNoOriginal")   // restore with no row: nothing to restore
        // Apply with no free row: rather than refuse (ackTableFull), reuse a FINISHED row — occupied
        // (every row is, here), a completed restore (op==2), not pending (flags bit 3 clear). Its
        // window is already back to normal; only its replay answer is lost. An apply row is live and
        // a pending row has work outstanding, so neither is evicted. None evictable → ackTableFull.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.movz(dst: 15, value: UInt16(AgentBlob.opTableCount)),
              Arc64.str(src: 15, base: 31, offset: 144),
              Arc64.movz(dst: 2, value: UInt16(AgentBlob.opTableSlot)),
              Arc64.addReg(dst: 2, lhs: 2, rhs: 17),
              Arc64.str(src: 2, base: 31, offset: 152)])
        label("evictScan")
        emit([Arc64.ldr(dst: 2, base: 31, offset: 152),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowOp),
              Arc64.cmpImm(src: 0, imm: 2)])
        branch(.cond(1), "evictNext")   // b.ne: not a completed-restore row
        // not pending: (flags / 8) mod 2 == 0 — division parity, the blob's AND-free idiom.
        emit([Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.movz(dst: 3, value: 8),
              Arc64.udiv(dst: 1, lhs: 0, rhs: 3),
              Arc64.movz(dst: 3, value: 2),
              Arc64.udiv(dst: 4, lhs: 1, rhs: 3),
              Arc64.mul(dst: 4, lhs: 4, rhs: 3),
              Arc64.subReg(dst: 1, lhs: 1, rhs: 4),
              Arc64.cmpImm(src: 1, imm: 0)])
        branch(.cond(1), "evictNext")   // b.ne: pending — work outstanding, leave it
        branch(.plain, "initRow")   // evict: reuse this row (its cursor is already [sp,152])
        label("evictNext")
        emit([Arc64.ldr(dst: 2, base: 31, offset: 152),
              Arc64.addImmBytes(dst: 2, src: 2, imm: AgentBlob.opEntryBytes),
              Arc64.str(src: 2, base: 31, offset: 152),
              Arc64.ldr(dst: 15, base: 31, offset: 144),
              Arc64.subImmBytes(dst: 15, src: 15, imm: 1),
              Arc64.str(src: 15, base: 31, offset: 144)])
        branch(.cbz(src: 15, nonzero: false), "ackTableFull")
        branch(.plain, "evictScan")
        label("rowFound")
        // Latest-wins compares against DESIREDgen — the newest accepted request — not doneGen
        // (codex P1c review: a gen between doneGen and a pending desiredGen must not
        // overtake the newer pending request). Equal gen: the row already carries this
        // request — answer its result, UNLESS it is still pending: the work has not run,
        // and answering lastStatus would report completion before it happens (codex P1c
        // review 6: a pending row replays deferred, so gen polling never lies).
        emit([Arc64.str(src: 2, base: 31, offset: 120),
              Arc64.ldr(dst: 0, base: 31, offset: 80),
              Arc64.ldr(dst: 1, base: 2, offset: AgentBlob.rowDesiredGen),
              Arc64.cmpReg(lhs: 0, rhs: 1)])
        branch(.cond(0), "genEqual")
        emit([Arc64.cmpReg(lhs: 0, rhs: 1)])
        branch(.cond(11), "ackSuperseded")  // b.lt: an older generation cannot replace a newer
        branch(.plain, "rowAccept")
        label("genEqual")
        // bit 3 of flags, division parity: pending = the request is accepted, not yet run.
        emit([Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.movz(dst: 3, value: 8),
              Arc64.udiv(dst: 1, lhs: 0, rhs: 3),
              Arc64.movz(dst: 3, value: 2),
              Arc64.udiv(dst: 4, lhs: 1, rhs: 3),
              Arc64.mul(dst: 4, lhs: 4, rhs: 3),
              Arc64.subReg(dst: 1, lhs: 1, rhs: 4),
              Arc64.cmpImm(src: 1, imm: 0)])
        branch(.cond(1), "ackDeferred")   // b.ne: pending — the honest answer is "deferred"
        branch(.plain, "ackLastStatus")   // same generation, completed: the existing result
        label("rowAccept")
        emit([Arc64.cmpReg(lhs: 0, rhs: 1)])
        branch(.cond(11), "ackSuperseded")  // b.lt: an older generation cannot replace a newer
        emit([Arc64.ldr(dst: 0, base: 31, offset: 80),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowDesiredGen),
              Arc64.ldr(dst: 0, base: 31, offset: 96),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowOp),
              Arc64.ldr(dst: 0, base: 31, offset: 104),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowButtons)])
        label("modeGate")
        // The gate: the run loop's REAL current mode must be kCFRunLoopDefaultMode and the
        // mutation depth 0 (codex P1b). The mode string is released on every path (1000 sends
        // must not leak — the resource-stability gate measures it).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: tMain),
              Arc64.movz(dst: 0, value: 0),
              Arc64.blr(16),
              Arc64.str(src: 0, base: 31, offset: 144),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: tCopyMode),
              Arc64.ldr(dst: 0, base: 31, offset: 144),
              Arc64.blr(16),
              Arc64.str(src: 0, base: 31, offset: 144),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: tDefaultMode),
              Arc64.ldr(dst: 16, base: 16, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 144),
              Arc64.cmpReg(lhs: 0, rhs: 16)])
        branch(.cond(1), "modeDefer")
        // Release the mode string, then the depth gate.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: tRelease),
              Arc64.ldr(dst: 0, base: 31, offset: 144),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.depthSlot),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(1), "depthDefer")
        branch(.plain, "mutate")
        // The mode string is released on the deferral path too — a 1000-send run must not leak
        // one CFString per deferral (the resource-stability gate measures exactly this).
        label("modeDefer")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: tRelease),
              Arc64.ldr(dst: 0, base: 31, offset: 144),
              Arc64.blr(16)])
        label("depthDefer")
        label("deferred")
        // Mark the row pending (once) and answer deferred. The bit-3 test is division parity
        // — (flags/8) mod 2 — the same trick as the capture gate (codex P1c review: the old
        // scaled-compare marked pending repeatedly and underflowed on success).
        emit([Arc64.ldr(dst: 2, base: 31, offset: 120),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.movz(dst: 3, value: 8),
              Arc64.udiv(dst: 1, lhs: 0, rhs: 3),
              Arc64.movz(dst: 3, value: 2),
              Arc64.udiv(dst: 4, lhs: 1, rhs: 3),
              Arc64.mul(dst: 4, lhs: 4, rhs: 3),
              Arc64.subReg(dst: 1, lhs: 1, rhs: 4),
              Arc64.cmpImm(src: 1, imm: 0)])
        // b.ne: bit 3 set (already pending) — go through armWake anyway: its slot gate makes
        // it a no-op when armed, and it RE-ARMS when the previous create failed (codex P1c
        // review 5: skipping armWake with an empty slot strands the row forever).
        branch(.cond(1), "armWake")
        emit([Arc64.addImmBytes(dst: 0, src: 0, imm: 8),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowFlags)])
        branch(.plain, "armWake")
        // Arm the coalesced wake timer (P1c; codex design: one main-loop DEFAULT-mode
        // one-shot, now + 0.05 s, armed only while the slot is empty — an already-armed
        // timer is never postponed). The context struct is staged on the stack;
        // CFRunLoopTimerCreate copies it deeply (the info pointer is the state page). The
        // Create reference is OURS (stored in wakeTimer); AddTimer takes its own.
        label("armWake")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.wakeTimerSlot),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(1), "armDone")   // b.ne: a timer is already armed — coalesced
        emit([Arc64.ldr(dst: 16, base: 17, offset: tTimeNow),
              Arc64.blr(16),                               // d0 = CFAbsoluteTimeGetCurrent()
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldrd(dst: 1, base: 17, offset: AgentBlob.wakeDelaySlot),
              Arc64.faddD(dst: 0, lhs: 0, rhs: 1),         // d0 = fire date
              // context at [sp,#0..39]: {version 0, info = state, retain, release, copy} = 0s.
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 0),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.stp(dst: 17, dst2: 31, base: 31, offset: 8),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 24),
              Arc64.strZero(base: 31, offset: 32),
              // (alloc x0, fire d0, interval d1, flags x1, order x2, callback x3, context x4)
              Arc64.movz(dst: 0, value: 0),
              Arc64.movz(dst: 1, value: 0),
              Arc64.movz(dst: 2, value: 0),
              Arc64.ldr(dst: 3, base: 17, offset: AgentBlob.timerCbAddrSlot),
              Arc64.addImm(dst: 4, src: 31, imm: 0),
              Arc64.ldrd(dst: 1, base: 17, offset: AgentBlob.cornerOffSlot),   // interval 0.0
              Arc64.ldr(dst: 16, base: 17, offset: tTimerCreate),
              Arc64.blr(16),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(0), "armDone")   // create said no: pending rows ride the next request
        // The slot publishes AFTER AddTimer returns (codex P1c review 7: publishing before
        // the add means an absorbed registration fault leaves the slot armed-looking with no
        // timer scheduled, and the coalesce gate then never creates one again — the unadded
        // timer leaks, which an absorbed fault permits; recovery of the WAKE matters more).
        emit([Arc64.str(src: 0, base: 31, offset: 144),    // the mode slot is free here
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: tMain),
              Arc64.movz(dst: 0, value: 0),
              Arc64.blr(16),                               // x0 = the main run loop
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 1, base: 31, offset: 144),    // the timer
              Arc64.ldr(dst: 16, base: 17, offset: tDefaultMode),
              Arc64.ldr(dst: 16, base: 16, offset: 0),     // kCFRunLoopDefaultMode (the var's value)
              Arc64.movReg(dst: 2, src: 16),
              Arc64.ldr(dst: 16, base: 17, offset: tAddTimer),
              Arc64.blr(16),                               // AddTimer retains its own ref
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 144),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.wakeTimerSlot)])
        label("armDone")
        branch(.plain, "ackDeferred")
        // The drain (P1c): the timer's APPLY_PENDING. Scan for a row with the pending bit;
        // re-arm first (the drain self-schedules: one row per fire, 50 ms apart, so a
        // mutation that pumps cannot block the rest), then run the row through the SAME
        // gate and mutation path as a tool request — a blocked gate lands on the deferred
        // label, which leaves pending set and re-arms (codex: "rearm if blocked work
        // remains"). The drain flag answers nothing (codex Q: the tool learns by replaying
        // the generation — a duplicate gen returns the row's lastStatus).
        label("drainPending")
        emit([Arc64.cmpImm(src: 2, imm: 24)])
        branch(.cond(3), "ret")   // b.lo: a short APPLY_PENDING is ignored, counted
        emit([Arc64.movz(dst: 16, value: 1),
              Arc64.str(src: 16, base: 31, offset: 56),
              Arc64.movz(dst: 15, value: UInt16(AgentBlob.opTableCount)),
              Arc64.str(src: 15, base: 31, offset: 144),
              Arc64.movz(dst: 2, value: UInt16(AgentBlob.opTableSlot)),
              Arc64.addReg(dst: 2, lhs: 2, rhs: 17),
              Arc64.str(src: 2, base: 31, offset: 136)])
        label("drainScan")
        emit([Arc64.ldr(dst: 2, base: 31, offset: 136),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.movz(dst: 3, value: 8),
              Arc64.udiv(dst: 1, lhs: 0, rhs: 3),
              Arc64.movz(dst: 3, value: 2),
              Arc64.udiv(dst: 4, lhs: 1, rhs: 3),
              Arc64.mul(dst: 4, lhs: 4, rhs: 3),
              Arc64.subReg(dst: 1, lhs: 1, rhs: 4),
              Arc64.cmpImm(src: 1, imm: 0)])
        branch(.cond(1), "drainFound")   // b.ne: bit 3 set — this row is pending
        emit([Arc64.ldr(dst: 2, base: 31, offset: 136),
              Arc64.addImmBytes(dst: 2, src: 2, imm: AgentBlob.opEntryBytes),
              Arc64.str(src: 2, base: 31, offset: 136),
              Arc64.ldr(dst: 15, base: 31, offset: 144),
              Arc64.subImmBytes(dst: 15, src: 15, imm: 1),
              Arc64.str(src: 15, base: 31, offset: 144)])
        branch(.cbz(src: 15, nonzero: false), "drainEmpty")
        branch(.plain, "drainScan")
        label("drainEmpty")
        // Nothing pending (the common case: the timer outlived the work): disarm is done —
        // the fired one-shot already released its slot in the timer entry.
        emit([Arc64.strZero(base: 31, offset: 56)])
        branch(.plain, "ret")
        label("drainFound")
        emit([Arc64.str(src: 2, base: 31, offset: 120),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowDesiredGen),
              Arc64.str(src: 0, base: 31, offset: 80),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowWid),
              Arc64.str(src: 0, base: 31, offset: 88),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowOp),
              Arc64.str(src: 0, base: 31, offset: 96),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowButtons),
              Arc64.str(src: 0, base: 31, offset: 104),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.tokenSlot),
              Arc64.str(src: 0, base: 31, offset: 112),
              // Re-arm before running: if the gate defers, the deferred label arms on an
              // empty slot (the fired timer cleared it); if this mutation pumps, the
              // remaining rows get a fresh timer the moment this callback returns.
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.wakeTimerSlot),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(1), "modeGate")   // b.ne: already armed
        emit([Arc64.ldr(dst: 16, base: 17, offset: tTimeNow),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldrd(dst: 1, base: 17, offset: AgentBlob.wakeDelaySlot),
              Arc64.faddD(dst: 0, lhs: 0, rhs: 1),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 0),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.stp(dst: 17, dst2: 31, base: 31, offset: 8),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 24),
              Arc64.strZero(base: 31, offset: 32),
              Arc64.movz(dst: 0, value: 0),
              Arc64.movz(dst: 1, value: 0),
              Arc64.movz(dst: 2, value: 0),
              Arc64.ldr(dst: 3, base: 17, offset: AgentBlob.timerCbAddrSlot),
              Arc64.addImm(dst: 4, src: 31, imm: 0),
              Arc64.ldrd(dst: 1, base: 17, offset: AgentBlob.cornerOffSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tTimerCreate),
              Arc64.blr(16),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(0), "modeGate")
        // Slot publishes after AddTimer (codex P1c review 7, same as armWake).
        emit([Arc64.str(src: 0, base: 31, offset: 144),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: tMain),
              Arc64.movz(dst: 0, value: 0),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 1, base: 31, offset: 144),
              Arc64.ldr(dst: 16, base: 17, offset: tDefaultMode),
              Arc64.ldr(dst: 16, base: 16, offset: 0),
              Arc64.movReg(dst: 2, src: 16),
              Arc64.ldr(dst: 16, base: 17, offset: tAddTimer),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 144),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.wakeTimerSlot)])
        branch(.plain, "modeGate")
        // The mutation sequence. x17 is state; the window is retained for the whole sequence
        // and released at every exit; depth brackets the mutations for the reentrancy gate.
        label("mutate")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.depthSlot),
              Arc64.addImmBytes(dst: 16, src: 16, imm: 1),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.depthSlot),
              // app = [NSApp sharedApplication]
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.nsAppClassSlot),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selSharedAppSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16),
              Arc64.str(src: 0, base: 31, offset: 136),
              // window = [app windowWithWindowNumber: wid]
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 136),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selWindowSlot),
              Arc64.ldr(dst: 2, base: 31, offset: 88),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "notFound")
        emit([Arc64.str(src: 0, base: 31, offset: 128),
              // retain the window for the sequence
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selRetainSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16),
              // titlebar = [window _titlebarContainerView] (nil skips decoration)
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selTitlebarSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16),
              Arc64.str(src: 0, base: 31, offset: 136)])
        // Capability gate before any mutation (codex): the setters must respond on the
        // receivers. respondsToSelector: on nil answers NO, which gates nil receivers safely.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selRespondsSlot),
              Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.selCornerSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "unsupported")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selRespondsSlot),
              Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.selShadowSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "unsupported")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selRespondsSlot),
              Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.selButtonSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "unsupported")
        // Decoration capability: the titlebar answers BOTH the setter and the getter; if the
        // getter is unsupported the decoration original stays unknown and decoration is left
        // alone on restore (the row records decoration-known).
        emit([Arc64.movz(dst: 16, value: 0),
              Arc64.str(src: 16, base: 31, offset: 144),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 136),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selRespondsSlot),
              Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.selDecoSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "buttonsCapable")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 136),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selRespondsSlot),
              Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.selDecoGetterSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "buttonsCapable")
        emit([Arc64.movz(dst: 16, value: 1),
              Arc64.str(src: 16, base: 31, offset: 144)])
        label("buttonsCapable")
        // (No window-level setHidden: gate: the setter lives on the buttons — the gate is
        // per-button below, where the receiver is the NSView that answers it.)
        // Capture originals at the row's FIRST execution (apply only; never overwrite). The
        // bit-1 test is division parity: (flags/2) mod 2, no AND encoder needed.
        emit([Arc64.ldr(dst: 0, base: 31, offset: 96),
              Arc64.cmpImm(src: 0, imm: 1)])
        branch(.cond(1), "mutateNow")   // b.ne: a restore never captures
        emit([Arc64.ldr(dst: 2, base: 31, offset: 120),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.movz(dst: 3, value: 2),
              Arc64.udiv(dst: 1, lhs: 0, rhs: 3),
              Arc64.udiv(dst: 4, lhs: 1, rhs: 3),
              Arc64.mul(dst: 4, lhs: 4, rhs: 3),
              Arc64.subReg(dst: 1, lhs: 1, rhs: 4),
              Arc64.cmpImm(src: 1, imm: 0)])
        branch(.cond(1), "mutateNow")   // b.ne: bit 1 SET (parity 1) = originals already captured
        // Getters are capability-gated like the setters (codex P1c review, confirmed by a real
        // crash 2026-10-21: NSWindow does NOT respond to cornerRadius — sending it blind threw
        // NSInvalidArgumentException in the target). A getter the receiver cannot answer leaves
        // its original at 0 — shadow NO, radius 0.0, button shown, decoration untouched — each
        // the shipped engine's own restore default, so the restore write stays faithful.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selRespondsSlot),
              Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.selHasShadowSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "capRadius")   // no hasShadow — original stays NO
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selHasShadowSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16),
              Arc64.ldr(dst: 2, base: 31, offset: 120),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowOrigShadow)])
        // cornerRadius (a double: d0, stored through the row)
        label("capRadius")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selRespondsSlot),
              Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.selCornerGetterSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "capDeco")   // no getter — radius original stays 0.0
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selCornerGetterSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16),
              Arc64.ldr(dst: 2, base: 31, offset: 120),
              Arc64.strd(src: 0, base: 2, offset: AgentBlob.rowOrigRadius)])
        // decoration original (when capable). The test is re-loaded at the label so the
        // getter-skip path never reads condition flags a call has clobbered.
        label("capDeco")
        emit([Arc64.ldr(dst: 16, base: 31, offset: 144),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(0), "captureButtons")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 136),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selDecoGetterSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16),
              Arc64.ldr(dst: 2, base: 31, offset: 120),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowOrigDecoration),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.addImmBytes(dst: 0, src: 0, imm: 4),   // decoration-known
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowFlags)])
        label("captureButtons")
        for i in 0..<3 {
            emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
                  Arc64.ldr(dst: 0, base: 31, offset: 128),
                  Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selButtonSlot),
                  Arc64.movz(dst: 2, value: UInt16(i)),
                  Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
                  Arc64.blr(16),
                  Arc64.ldr(dst: 2, base: 31, offset: 120),
                  Arc64.strZero(base: 2, offset: AgentBlob.rowOrigButton0 + 8 * i),
                  Arc64.cmpImm(src: 0, imm: 0)])
            branch(.cond(0), "capBtn\(i)")   // a nil button stores 0 (absent) and skips the getter
            // The button crosses the capability call in a frame slot; the isHidden getter is
            // gated like everything else (nil receiver answers NO, so the gate is nil-safe).
            emit([Arc64.str(src: 0, base: 31, offset: 152),
                  Arc64.ldr(dst: 17, base: 31, offset: 64),
                  Arc64.ldr(dst: 0, base: 31, offset: 152),
                  Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selRespondsSlot),
                  Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.selIsHiddenSlot),
                  Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
                  Arc64.blr(16)])
            branch(.cbz(src: 0, nonzero: false), "capBtn\(i)")   // no isHidden — original stays shown
            emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
                  Arc64.ldr(dst: 0, base: 31, offset: 152),
                  Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selIsHiddenSlot),
                  Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
                  Arc64.blr(16),
                  Arc64.ldr(dst: 2, base: 31, offset: 120),
                  Arc64.str(src: 0, base: 2, offset: AgentBlob.rowOrigButton0 + 8 * i)])
            label("capBtn\(i)")
        }
        // Mark captured.
        emit([Arc64.ldr(dst: 2, base: 31, offset: 120),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.addImmBytes(dst: 0, src: 0, imm: 2),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowFlags)])
        // The mutations. Apply is the shipped set; restore returns every captured original.
        label("mutateNow")
        // shadow
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selShadowSlot),
              Arc64.ldr(dst: 16, base: 31, offset: 96),
              Arc64.cmpImm(src: 16, imm: 1)])
        branch(.cond(0), "shadowApply")
        // Restore: the app's own latest request while applied (rowAppShadow, request + 1, recorded by
        // the setHasShadow: override), else the apply-time snapshot (review #6). Clearing it as it is
        // consumed means each request is honored once — a later apply/restore with no new app request
        // falls back to the snapshot, not a stale value (review #2).
        emit([Arc64.ldr(dst: 3, base: 31, offset: 120),
              Arc64.ldr(dst: 2, base: 3, offset: AgentBlob.rowAppShadow),
              Arc64.strZero(base: 3, offset: AgentBlob.rowAppShadow)])
        branch(.cbz(src: 2, nonzero: false), "shadowSnapshot")
        emit([Arc64.subImmBytes(dst: 2, src: 2, imm: 1)])
        branch(.plain, "shadowSend")
        label("shadowSnapshot")
        emit([Arc64.ldr(dst: 2, base: 3, offset: AgentBlob.rowOrigShadow)])
        branch(.plain, "shadowSend")
        label("shadowApply")
        emit([Arc64.movz(dst: 2, value: 0)])
        label("shadowSend")
        emit([Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16),
              // corner: d0 reloaded immediately before the send (caller-clobbered)
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 31, offset: 96),
              Arc64.cmpImm(src: 16, imm: 1)])
        branch(.cond(0), "cornerApply")
        emit([Arc64.ldr(dst: 3, base: 31, offset: 120),
              Arc64.ldrd(dst: 0, base: 3, offset: AgentBlob.rowOrigRadius)])
        branch(.plain, "cornerSend")
        label("cornerApply")
        emit([Arc64.ldrd(dst: 0, base: 17, offset: AgentBlob.cornerOnSlot)])
        label("cornerSend")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selCornerSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        // decoration (only when the pair was capable)
        emit([Arc64.ldr(dst: 16, base: 31, offset: 144),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(0), "decoDone")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 136),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selDecoSlot),
              Arc64.ldr(dst: 16, base: 31, offset: 96),
              Arc64.cmpImm(src: 16, imm: 1)])
        branch(.cond(0), "decoApply")
        emit([Arc64.ldr(dst: 3, base: 31, offset: 120),
              Arc64.ldr(dst: 2, base: 3, offset: AgentBlob.rowOrigDecoration)])
        branch(.plain, "decoSend")
        label("decoApply")
        emit([Arc64.movz(dst: 2, value: 0)])
        label("decoSend")
        emit([Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        label("decoDone")
        // buttons: per mask bit, setHidden: to 1 (apply) / the captured original (restore)
        for i in 0..<3 {
            emit([Arc64.ldr(dst: 1, base: 31, offset: 104),
                  Arc64.movz(dst: 3, value: UInt16(1 << i)),
                  Arc64.udiv(dst: 2, lhs: 1, rhs: 3),
                  Arc64.movz(dst: 4, value: 2),
                  Arc64.udiv(dst: 5, lhs: 2, rhs: 4),
                  Arc64.mul(dst: 5, lhs: 5, rhs: 4),
                  Arc64.subReg(dst: 2, lhs: 2, rhs: 5),
                  Arc64.cmpImm(src: 2, imm: 0)])
            branch(.cond(0), "btn\(i)Done")   // b.eq: bit clear
            emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
                  Arc64.ldr(dst: 0, base: 31, offset: 128),
                  Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selButtonSlot),
                  Arc64.movz(dst: 2, value: UInt16(i)),
                  Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
                  Arc64.blr(16),
                  Arc64.str(src: 0, base: 31, offset: 152),
                  Arc64.cmpImm(src: 0, imm: 0)])
            branch(.cond(0), "btn\(i)Done")   // b.eq: the button is gone — skip
            emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
                  Arc64.ldr(dst: 0, base: 31, offset: 152),
                  Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selRespondsSlot),
                  Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.selHiddenSlot),
                  Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
                  Arc64.blr(16)])
            branch(.cbz(src: 0, nonzero: false), "btn\(i)Done")   // no setter — skip, never msgSend blind
            emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
                  Arc64.ldr(dst: 0, base: 31, offset: 152),
                  Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selHiddenSlot),
                  Arc64.ldr(dst: 16, base: 31, offset: 96),
                  Arc64.cmpImm(src: 16, imm: 1)])
            branch(.cond(0), "btn\(i)Hide")
            emit([Arc64.ldr(dst: 3, base: 31, offset: 120),
                  Arc64.ldr(dst: 2, base: 3, offset: AgentBlob.rowOrigButton0 + 8 * i)])
            branch(.plain, "btn\(i)Send")
            label("btn\(i)Hide")
            emit([Arc64.movz(dst: 2, value: 1)])
            label("btn\(i)Send")
            emit([Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
                  Arc64.blr(16)])
            label("btn\(i)Done")
        }
        // Success: record the row, release the window, depth down, ACK applied/restored.
        // (Every value crosses a call in a slot; the status register is chosen here, after the
        // row writes, so [sp,#144] — the status slot — is written, not read.)
        emit([Arc64.ldr(dst: 2, base: 31, offset: 120),
              Arc64.ldr(dst: 0, base: 31, offset: 80),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowDoneGen),
              Arc64.ldr(dst: 0, base: 31, offset: 96),
              Arc64.cmpImm(src: 0, imm: 1)])
        branch(.cond(0), "successApplied")
        emit([Arc64.movz(dst: 16, value: UInt16(AgentBlob.statusRestored))])
        branch(.plain, "successRecord")
        label("successApplied")
        emit([Arc64.movz(dst: 16, value: UInt16(AgentBlob.statusApplied))])
        label("successRecord")
        emit([Arc64.ldr(dst: 2, base: 31, offset: 120),
              Arc64.str(src: 16, base: 2, offset: AgentBlob.rowLastStatus),
              Arc64.str(src: 16, base: 31, offset: 144),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowObject),
              // A newer request accepted DURING this mutation (the depth gate defers it; it
              // raised desiredGen) keeps the row pending — clearing here would drop it on the
              // floor (codex P1c review 2). doneGen < desiredGen: leave bit 3 set, arm, and
              // answer deferred; the drain runs the newer generation.
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowDesiredGen),
              Arc64.ldr(dst: 1, base: 2, offset: AgentBlob.rowDoneGen),
              Arc64.cmpReg(lhs: 0, rhs: 1)])
        branch(.cond(1), "armWake")   // b.ne: newer generation pending — the wake must fire
        emit([
              // clear pending (bit 3) — division parity, set-only-when-clear (codex P1c review)
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.movz(dst: 3, value: 8),
              Arc64.udiv(dst: 1, lhs: 0, rhs: 3),
              Arc64.movz(dst: 3, value: 2),
              Arc64.udiv(dst: 4, lhs: 1, rhs: 3),
              Arc64.mul(dst: 4, lhs: 4, rhs: 3),
              Arc64.subReg(dst: 1, lhs: 1, rhs: 4),
              Arc64.cmpImm(src: 1, imm: 0)])
        branch(.cond(0), "releaseWindow")   // b.eq: bit 3 clear — nothing to clear
        emit([Arc64.subImmBytes(dst: 0, src: 0, imm: 8),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowFlags)])
        branch(.plain, "releaseWindow")
        // The exits. notFound retained nothing — depth down, no release. unsupported releases
        // the window first. Both bracket the depth the mutate path opened.
        label("notFound")
        emit([Arc64.movz(dst: 16, value: UInt16(AgentBlob.statusNotFound)),
              Arc64.str(src: 16, base: 31, offset: 144),
              // A drain-selected row that fails (its window closed, say) must clear pending
              // (codex P1c review 3): a row that stays pending is re-selected first on every
              // drain and starves every later pending row forever. Tool-request rows are
              // untouched — the drain flag says whose work this is (the tool-path notFound
              // has no row at all: the row slot is the scan cursor, not a selection).
              Arc64.ldr(dst: 9, base: 31, offset: 56),
              Arc64.cmpImm(src: 9, imm: 0)])
        branch(.cond(0), "depthDown")   // b.eq: not a drain — status only
        emit([Arc64.ldr(dst: 2, base: 31, offset: 120),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.movz(dst: 3, value: 8),
              Arc64.udiv(dst: 1, lhs: 0, rhs: 3),
              Arc64.movz(dst: 3, value: 2),
              Arc64.udiv(dst: 4, lhs: 1, rhs: 3),
              Arc64.mul(dst: 4, lhs: 4, rhs: 3),
              Arc64.subReg(dst: 1, lhs: 1, rhs: 4),
              Arc64.cmpImm(src: 1, imm: 0)])
        branch(.cond(0), "depthDown")   // b.eq: bit 3 clear — nothing to clear
        emit([Arc64.subImmBytes(dst: 0, src: 0, imm: 8),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowFlags)])
        branch(.plain, "depthDown")
        label("unsupported")
        emit([Arc64.movz(dst: 16, value: UInt16(AgentBlob.statusUnsupported)),
              Arc64.str(src: 16, base: 31, offset: 144),
              Arc64.ldr(dst: 9, base: 31, offset: 56),
              Arc64.cmpImm(src: 9, imm: 0)])
        branch(.cond(0), "releaseWindow")   // b.eq: not a drain — status only
        emit([Arc64.ldr(dst: 2, base: 31, offset: 120),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.movz(dst: 3, value: 8),
              Arc64.udiv(dst: 1, lhs: 0, rhs: 3),
              Arc64.movz(dst: 3, value: 2),
              Arc64.udiv(dst: 4, lhs: 1, rhs: 3),
              Arc64.mul(dst: 4, lhs: 4, rhs: 3),
              Arc64.subReg(dst: 1, lhs: 1, rhs: 4),
              Arc64.cmpImm(src: 1, imm: 0)])
        branch(.cond(0), "releaseWindow")   // b.eq: bit 3 clear
        emit([Arc64.subImmBytes(dst: 0, src: 0, imm: 8),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowFlags)])
        branch(.plain, "releaseWindow")
        label("releaseWindow")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 0, base: 31, offset: 128),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selReleaseSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        label("depthDown")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.depthSlot),
              Arc64.subImmBytes(dst: 16, src: 16, imm: 1),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.depthSlot)])
        branch(.plain, "ack")
        // The status-only ACKs.
        label("ackLastStatus")
        emit([Arc64.ldr(dst: 2, base: 31, offset: 120),
              Arc64.ldr(dst: 16, base: 2, offset: AgentBlob.rowLastStatus),
              Arc64.str(src: 16, base: 31, offset: 144)])
        branch(.plain, "ack")
        label("ackSuperseded")
        emit([Arc64.movz(dst: 16, value: UInt16(AgentBlob.statusSuperseded)),
              Arc64.str(src: 16, base: 31, offset: 144)])
        branch(.plain, "ack")
        label("ackTableFull")
        emit([Arc64.movz(dst: 16, value: UInt16(AgentBlob.statusTableFull)),
              Arc64.str(src: 16, base: 31, offset: 144)])
        branch(.plain, "ack")
        label("ackNoOriginal")
        emit([Arc64.movz(dst: 16, value: UInt16(AgentBlob.statusNoOriginal)),
              Arc64.str(src: 16, base: 31, offset: 144)])
        branch(.plain, "ack")
        label("ackDeferred")
        emit([Arc64.movz(dst: 16, value: UInt16(AgentBlob.statusDeferred)),
              Arc64.str(src: 16, base: 31, offset: 144)])
        branch(.plain, "ack")
        // The op ACK: 56 bytes, plain 0x13, msgh_id 3010, {gen, wid, status, session}. The send
        // carries the TIMEOUT option with timeout 0 — it never blocks the main thread (verdict 6
        // Q5, same shape as the ping ACK).
        label("ack")
        // The drain answers nothing: the tool learns a drain's result by replaying the
        // generation (a duplicate gen returns the row's lastStatus — codex Q5's polling
        // contract, no unsolicited ACK).
        emit([Arc64.ldr(dst: 16, base: 31, offset: 56),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(1), "ret")   // b.ne: draining
        emit([Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 0),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 16),
              Arc64.movz(dst: 16, value: 0x13),
              Arc64.str(src: 16, base: 31, offset: 0),
              Arc64.movz(dst: 16, value: 56),
              Arc64.str32(src: 16, base: 31, offset: 4),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.toolPortSlot),
              Arc64.str(src: 16, base: 31, offset: 8),
              Arc64.movz(dst: 16, value: 3010),
              Arc64.str32(src: 16, base: 31, offset: 20),
              Arc64.ldr(dst: 16, base: 31, offset: 80),
              Arc64.str(src: 16, base: 31, offset: 24),
              Arc64.ldr(dst: 16, base: 31, offset: 88),
              Arc64.str(src: 16, base: 31, offset: 32),
              Arc64.ldr(dst: 16, base: 31, offset: 144),
              Arc64.str(src: 16, base: 31, offset: 40),
              Arc64.ldr(dst: 16, base: 31, offset: 112),
              Arc64.str(src: 16, base: 31, offset: 48),
              Arc64.ldr(dst: 16, base: 17, offset: tMsg),
              Arc64.addImm(dst: 0, src: 31, imm: 0),
              Arc64.movz(dst: 1, value: 0x11),
              Arc64.movz(dst: 2, value: 56),
              Arc64.movz(dst: 3, value: 0),
              Arc64.movz(dst: 4, value: 0),
              Arc64.movz(dst: 5, value: 0),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 64),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.errAckSlot)])
        label("ret")
        emit([Arc64.ldp(dst: 29, dst2: 30, base: 31, offset: 160),
              Arc64.addImm(dst: 31, src: 31, imm: 176),
              Arc64.ret()])
    }

    // MARK: the wake timer entry (P1c)

    /// The CFRunLoopTimer callback, C ABI: x0 = the timer, x1 = context.info = the state
    /// page (codex P1c: the Mach callback must not be the timer callback — the register
    /// meanings differ). The timer is the coalesced one-shot the design mandates: main run
    /// loop, DEFAULT mode (tracking/modal loops intentionally do not wake it — mutation is
    /// forbidden there), fire = now + 0.05 s, interval 0. Its entire job is the one
    /// non-blocking self-send the design specifies — the internal APPLY_PENDING (msgh_id
    /// 4001, 24 bytes) to the agent port; the CFMachPort callback drains pending rows under
    /// the same mode/depth gate as every op. It touches no AppKit and no window.
    ///
    /// Ownership (codex Q3, verified against CFRunLoop.c): Create returned OUR reference and
    /// AddTimer retained its own; a one-shot's firing removes and releases the RUN LOOP's
    /// reference only. So: save the timer, clear the slot, invalidate, release our reference
    /// exactly once — in that order, before the send (a send fault must not strand the slot).
    mutating func assembleTimer() {
        // The frame is 96 bytes: timer [0], state [8], re-arm context staging [16..55],
        // the 24-byte self-send [40..63], scratch [64..79], saved pair [80..95]. The
        // header's fields (bits, size, remote@8 = 8 bytes covering local, voucher, id@20)
        // land inside the message ONLY — the 48-byte layout put id at [sp,36] over the
        // saved x29 at [32..39] and left msgh_local_port on uninitialised stack bytes
        // (codex P1c review 1: corrupted saved x29 + a send-kr lottery).
        emit([Arc64.subImm(dst: 31, src: 31, imm: 96),
              Arc64.stp(dst: 29, dst2: 30, base: 31, offset: 80),
              Arc64.str(src: 0, base: 31, offset: 0),      // the timer
              Arc64.str(src: 1, base: 31, offset: 8),      // context.info = the state page
              Arc64.ldr(dst: 17, base: 31, offset: 8),
              Arc64.strZero(base: 17, offset: AgentBlob.wakeTimerSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tTimerInvalidate),
              Arc64.ldr(dst: 0, base: 31, offset: 0),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 8),
              Arc64.ldr(dst: 16, base: 17, offset: tRelease),
              Arc64.ldr(dst: 0, base: 31, offset: 0),
              Arc64.blr(16),
              // The 24-byte self-send at [sp,#40..63], fully zeroed first: plain 0x13
              // (COPY_SEND on the CFMachPort's send-parity name), msgh_id 4001, local 0.
              // TIMEOUT option, timeout 0 — never blocks the main thread.
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 40),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 48),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 56),
              Arc64.movz(dst: 16, value: 0x13),
              Arc64.str32(src: 16, base: 31, offset: 40),
              Arc64.movz(dst: 16, value: 24),
              Arc64.str32(src: 16, base: 31, offset: 44),
              Arc64.ldr(dst: 17, base: 31, offset: 8),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.agentPortSlot),
              Arc64.str(src: 16, base: 31, offset: 48),    // remote (+8..15), local zeroed
              Arc64.movz(dst: 16, value: 4001),
              Arc64.str32(src: 16, base: 31, offset: 60),
              Arc64.ldr(dst: 16, base: 17, offset: tMsg),
              Arc64.addImm(dst: 0, src: 31, imm: 40),
              Arc64.movz(dst: 1, value: 0x11),
              Arc64.movz(dst: 2, value: 24),
              Arc64.movz(dst: 3, value: 0),
              Arc64.movz(dst: 4, value: 0),
              Arc64.movz(dst: 5, value: 0),
              Arc64.blr(16),
              // The send's kr lands in the debug slot; a LOST send (queue full, timeout 0)
              // re-arms a fresh one-shot (codex P1c review 4: a lost self-send with the
              // slot already cleared strands every pending row with no wake scheduled).
              Arc64.ldr(dst: 17, base: 31, offset: 8),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.dbgSizeSlot),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(1), "timerRearm")  // b.ne: kr != 0 — the wake was lost, re-arm
        branch(.plain, "timerDone")
        // Re-arm on a lost send: the same create/add sequence the callback uses (the slot is
        // empty — this entry cleared it), staged context at [sp,16..55], timer stashed [64].
        // One shared epilogue: the audit walks the block linearly (an early ret + a second
        // epilogue reads as an unbalanced frame).
        label("timerRearm")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 8),
              Arc64.ldr(dst: 16, base: 17, offset: tTimeNow),
              Arc64.blr(16),                                // d0 = now
              Arc64.ldr(dst: 17, base: 31, offset: 8),
              Arc64.ldrd(dst: 1, base: 17, offset: AgentBlob.wakeDelaySlot),
              Arc64.faddD(dst: 0, lhs: 0, rhs: 1),          // d0 = fire date
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 16),
              Arc64.ldr(dst: 17, base: 31, offset: 8),
              Arc64.stp(dst: 17, dst2: 31, base: 31, offset: 24),
              Arc64.stp(dst: 31, dst2: 31, base: 31, offset: 40),
              Arc64.movz(dst: 0, value: 0),
              Arc64.movz(dst: 1, value: 0),
              Arc64.movz(dst: 2, value: 0),
              Arc64.ldr(dst: 3, base: 17, offset: AgentBlob.timerCbAddrSlot),
              Arc64.addImm(dst: 4, src: 31, imm: 16),
              Arc64.ldr(dst: 17, base: 31, offset: 8),
              Arc64.ldrd(dst: 1, base: 17, offset: AgentBlob.cornerOffSlot),   // interval 0.0
              Arc64.ldr(dst: 16, base: 17, offset: tTimerCreate),
              Arc64.blr(16),
              Arc64.cmpImm(src: 0, imm: 0)])
        branch(.cond(0), "timerDone")   // create said no: the rows ride the next request
        emit([Arc64.str(src: 0, base: 31, offset: 64),
              Arc64.ldr(dst: 17, base: 31, offset: 8),
              Arc64.ldr(dst: 16, base: 17, offset: tMain),
              Arc64.movz(dst: 0, value: 0),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 8),
              Arc64.ldr(dst: 1, base: 31, offset: 64),
              Arc64.ldr(dst: 16, base: 17, offset: tDefaultMode),
              Arc64.ldr(dst: 16, base: 16, offset: 0),
              Arc64.movReg(dst: 2, src: 16),
              Arc64.ldr(dst: 16, base: 17, offset: tAddTimer),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 8),
              Arc64.ldr(dst: 0, base: 31, offset: 64),
              Arc64.str(src: 0, base: 17, offset: AgentBlob.wakeTimerSlot)])
        label("timerDone")
        emit([Arc64.ldp(dst: 29, dst2: 30, base: 31, offset: 80),
              Arc64.addImm(dst: 31, src: 31, imm: 96),
              Arc64.ret()])
    }

    // MARK: the border observer (P1e)

    /// The CFRunLoopObserver callback, C ABI: x0 = the observer, x1 = the activity, x2 = the
    /// context.info = the state page. Added to the main run loop in DEFAULT mode on
    /// kCFRunLoopBeforeWaiting, so it fires once the app has finished a redraw batch (a tab or
    /// window switch) and is about to sleep. For each occupied apply-row whose decoration original
    /// was captured, it first installs the P1f setHasShadow: override on the window's class (the
    /// zero-flash path: iTerm's border outline is the window shadow's edge, re-enabled on every tab
    /// switch), then — as a backstop for a class the override cannot take — reads `hasShadow` and,
    /// only if it regressed to YES, re-applies the window-level visual state: decoration off,
    /// shadow off, corner 0.01. A row whose override is installed (flags bit 4) is skipped whole.
    /// No row/generation/ACK bookkeeping and no button work — those stay the op path's. Gated on
    /// depth==0 (default mode only means no mode re-check is needed); nil receivers skip through
    /// cbz. Touches no callee-saved register; every live value crosses a call in a frame slot.
    mutating func assembleObserver() {
        // Frame 80: state@0, loop count@8, row cursor@16, app@24, window@32, titlebar@40, class@48,
        // pair@64. Every live value crosses an ObjC call in a frame slot; x0-x4/x9-x11/x15-x17 and
        // d0 are the only registers touched, all caller-saved.
        emit([Arc64.subImm(dst: 31, src: 31, imm: 80),
              Arc64.stp(dst: 29, dst2: 30, base: 31, offset: 64),
              Arc64.addImm(dst: 29, src: 31, imm: 64),
              Arc64.str(src: 2, base: 31, offset: 0)])        // context.info = the state page
        // Reentrancy gate: a mutation already in flight (depth>0) owns the window; do nothing.
        // The observer is added in DEFAULT mode only, so the mode is never a tracking/modal loop
        // here and no mode re-check is needed (mutation is mode-safe at BeforeWaiting in default).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.depthSlot),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(1), "obsRet")   // b.ne: depth>0
        // Row loop over the op table.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.movz(dst: 15, value: UInt16(AgentBlob.opTableCount)),
              Arc64.str(src: 15, base: 31, offset: 8),
              Arc64.movz(dst: 2, value: UInt16(AgentBlob.opTableSlot)),
              Arc64.addReg(dst: 2, lhs: 2, rhs: 17),
              Arc64.str(src: 2, base: 31, offset: 16)])
        label("obsRowScan")
        // occupied? flags bit 0 — division parity (flags mod 2), the blob's AND-free idiom.
        emit([Arc64.ldr(dst: 2, base: 31, offset: 16),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.movz(dst: 3, value: 2),
              Arc64.udiv(dst: 1, lhs: 0, rhs: 3),
              Arc64.mul(dst: 1, lhs: 1, rhs: 3),
              Arc64.subReg(dst: 1, lhs: 0, rhs: 1),
              Arc64.cmpImm(src: 1, imm: 0)])
        branch(.cond(0), "obsRowNext")   // b.eq: bit 0 clear — free row
        // apply rows only (rowOp == 1): a restore row's border is meant to be back.
        emit([Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowOp),
              Arc64.cmpImm(src: 0, imm: 1)])
        branch(.cond(1), "obsRowNext")   // b.ne: not an apply row
        // decoration-known? flags bit 2 — (flags/4) mod 2. Without a captured decoration original
        // the window never had its decoration touched, so there is nothing for the observer to
        // re-remove (and the getter was never proven capable).
        emit([Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.movz(dst: 3, value: 4),
              Arc64.udiv(dst: 1, lhs: 0, rhs: 3),
              Arc64.movz(dst: 3, value: 2),
              Arc64.udiv(dst: 4, lhs: 1, rhs: 3),
              Arc64.mul(dst: 4, lhs: 4, rhs: 3),
              Arc64.subReg(dst: 1, lhs: 1, rhs: 4),
              Arc64.cmpImm(src: 1, imm: 0)])
        branch(.cond(0), "obsRowNext")   // b.eq: decoration original not captured
        // Fast path: once the setHasShadow: override is ensured for this row (flags bit 4), the
        // shadow can never turn on again, so skip every msgSend — the observer costs only this
        // cheap flag read per fire after install (answers the "is this a poll?" cost concern).
        emit([Arc64.ldr(dst: 2, base: 31, offset: 16),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.movz(dst: 3, value: 16),
              Arc64.udiv(dst: 1, lhs: 0, rhs: 3),
              Arc64.movz(dst: 3, value: 2),
              Arc64.udiv(dst: 4, lhs: 1, rhs: 3),
              Arc64.mul(dst: 4, lhs: 4, rhs: 3),
              Arc64.subReg(dst: 1, lhs: 1, rhs: 4),   // (flags / 16) mod 2
              Arc64.cmpImm(src: 1, imm: 0)])
        branch(.cond(1), "obsRowNext")   // b.ne: override ensured — nothing to do
        // app = [NSApp sharedApplication]
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.nsAppClassSlot),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selSharedAppSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16),
              Arc64.str(src: 0, base: 31, offset: 24)])
        // window = [app windowWithWindowNumber: wid]  (wid from the row)
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 24),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selWindowSlot),
              Arc64.ldr(dst: 2, base: 31, offset: 16),
              Arc64.ldr(dst: 2, base: 2, offset: AgentBlob.rowWid),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "obsRowNext")   // the window is gone
        emit([Arc64.str(src: 0, base: 31, offset: 32)])
        // P1f: ensure the setHasShadow: override is installed on this window's class, so iTerm's
        // setHasShadow:YES is forced NO for our windows — zero flash. A class already in the table
        // is ensured; otherwise the install runs only with room to record it and only over
        // NSWindow's inherited IMP (or our own leftover), and marks the row ensured once it lands.
        // Guarded on shadowOrig being resolved (0 if the entry's P1f resolution did not run — then
        // we skip, leaving the reactive re-apply as the backstop).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.shadowOrigSlot),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(0), "obsShadowDone")   // b.eq: no orig IMP — override unavailable
        // cls = [window class]  (the real class, not object_getClass's KVO subclass)
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 32),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selClassSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16),
              Arc64.str(src: 0, base: 31, offset: 48)])   // cls
        // Never add the override to NSWindow itself — that would suppress the shadow on every
        // window in the app, managed or not. (iTerm's windows are subclasses; this guards the
        // general case and the hostapp's plain windows.)
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.nsWindowClassSlot),
              Arc64.ldr(dst: 0, base: 31, offset: 48),
              Arc64.cmpReg(lhs: 16, rhs: 0)])
        branch(.cond(0), "obsShadowDone")   // b.eq: cls == NSWindow — leave it alone
        // Dedup: if cls is already in the override-class table, it is ensured — skip (this is also
        // the per-fire fast path once installed). The scan reads the table through x3.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 9, base: 17, offset: AgentBlob.shadowClassCountSlot),
              Arc64.addImm(dst: 3, src: 17, imm: AgentBlob.shadowClassTableSlot)])
        label("obsDedup")
        branch(.cbz(src: 9, nonzero: false), "obsInstall")   // scanned all — not found, install
        emit([Arc64.ldr(dst: 11, base: 3, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 48),
              Arc64.cmpReg(lhs: 11, rhs: 0)])
        branch(.cond(0), "obsEnsured")   // b.eq: already overridden this class — mark the row ensured
        emit([Arc64.addImmBytes(dst: 3, src: 3, imm: 8),
              Arc64.subImmBytes(dst: 9, src: 9, imm: 1)])
        branch(.plain, "obsDedup")
        label("obsInstall")
        // Table full BEFORE touching the class: if we cannot record it, we must not install it —
        // teardown only restores recorded classes, so an installed-but-unrecorded class would point
        // at freed pages after vm_deallocate and crash on its next setHasShadow:. Leave it to the
        // reactive backstop (no ensured bit).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 9, base: 17, offset: AgentBlob.shadowClassCountSlot),
              Arc64.cmpImm(src: 9, imm: AgentBlob.shadowClassTableCount)])
        branch(.cond(2), "obsShadowDone")   // b.hs: table full — do not install; keep the backstop
        // IMP guard: install only when cls's current setHasShadow: is NSWindow's inherited IMP (or
        // our own leftover from a prior teardown). Never clobber a class that defines its own
        // setHasShadow: (this agent runs in apps other than iTerm). m = class_getInstanceMethod(cls,
        // setHasShadow:); curImp = method_getImplementation(m).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 48),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selShadowSlot),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.classGetInstanceMethodSlot),
              Arc64.blr(16),                                     // x0 = Method
              Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.methodGetImpSlot),
              Arc64.blr(16)])                                    // x0 = curImp
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.shadowImpAddrSlot),
              Arc64.cmpReg(lhs: 0, rhs: 16)])
        branch(.cond(0), "obsEnsured")   // b.eq: already our IMP — just mark ensured
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.shadowOrigSlot),
              Arc64.cmpReg(lhs: 0, rhs: 16)])
        branch(.cond(0), "obsDoInstall")   // b.eq: NSWindow's inherited IMP — install over it
        // Not inherited, not our current IMP: is it a NoBorder override left by a PRIOR instance (a
        // force-kill/crash strands it — teardown never ran)? Such an IMP carries the agent magic in
        // the 8 bytes before its entry. If so, reclaim it (force our live IMP); else it is a foreign
        // app's own setHasShadow: — leave it alone. Reading [curImp-8] stays inside that method's
        // code page (our stranded IMP, or — vanishingly rare — a foreign method not at a page start).
        emit([Arc64.subImmBytes(dst: 1, src: 0, imm: 8),
              Arc64.ldr(dst: 1, base: 1, offset: 0),        // the 8 bytes before curImp
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.magicSlot),
              Arc64.cmpReg(lhs: 1, rhs: 16)])
        branch(.cond(1), "obsShadowDone")   // b.ne: foreign setHasShadow: — do not touch it
        label("obsDoInstall")
        // Safe: class_addMethod gives cls its OWN method (so method_setImplementation targets cls,
        // not the inherited NSWindow method); then force our IMP (reinstall-safe — a prior teardown
        // left cls's method = NSWindow's IMP, which class_addMethod will not replace).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 48),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selShadowSlot),
              Arc64.ldr(dst: 2, base: 17, offset: AgentBlob.shadowImpAddrSlot),
              Arc64.addImm(dst: 3, src: 17, imm: AgentBlob.shadowTypesSlot),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.classAddMethodSlot),
              Arc64.blr(16)])
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 48),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selShadowSlot),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.classGetInstanceMethodSlot),
              Arc64.blr(16)])   // x0 = Method
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.shadowImpAddrSlot),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.methodSetImpSlot),
              Arc64.blr(16)])
        // Record cls for teardown (count < 4 guaranteed by the full check above).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 9, base: 17, offset: AgentBlob.shadowClassCountSlot),
              Arc64.addImm(dst: 3, src: 17, imm: AgentBlob.shadowClassTableSlot),
              Arc64.movz(dst: 11, value: 8),
              Arc64.mul(dst: 10, lhs: 9, rhs: 11),   // x10 = count * 8
              Arc64.addReg(dst: 3, lhs: 3, rhs: 10),  // x3 = &table[count]
              Arc64.ldr(dst: 0, base: 31, offset: 48),
              Arc64.str(src: 0, base: 3, offset: 0),  // table[count] = cls
              Arc64.addImmBytes(dst: 9, src: 9, imm: 1),
              Arc64.str(src: 9, base: 17, offset: AgentBlob.shadowClassCountSlot)])
        // Mark the row ensured (flags bit 4) so later fires skip it — reached only when bit 4 was
        // clear (the fast path above returned otherwise), so this adds the bit exactly once.
        label("obsEnsured")
        emit([Arc64.ldr(dst: 2, base: 31, offset: 16),
              Arc64.ldr(dst: 0, base: 2, offset: AgentBlob.rowFlags),
              Arc64.addImmBytes(dst: 0, src: 0, imm: 16),
              Arc64.str(src: 0, base: 2, offset: AgentBlob.rowFlags)])
        label("obsShadowDone")
        // titlebar = [window _titlebarContainerView]  (the decoration view's container)
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 32),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selTitlebarSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "obsRowNext")   // no titlebar
        emit([Arc64.str(src: 0, base: 31, offset: 40)])
        // Regression gate: hasShadow. iTerm re-enables the window shadow when it redraws the border
        // on a tab/window switch (measured 2026-10-22 on iTerm: hasShadow flips YES on every
        // switch; drawsDecorationView never does — origDeco was captured YES but the redraw does
        // not re-set it). Our apply sets hasShadow NO, so this is a SELF-CLEARING signal: once the
        // observer re-applies, hasShadow reads NO and it stops — no needs-display feedback loop
        // (an unconditional re-apply spun iTerm to 70% CPU at ~1930 fires/s; the gate holds it
        // at idle).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 32),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selHasShadowSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        branch(.cbz(src: 0, nonzero: false), "obsRowNext")   // shadow NO — not regressed
        // Regressed: re-apply the window-level visual state the border lives in. depth++ brackets
        // the mutation so a nested BeforeWaiting the AppKit calls might pump cannot recurse here.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.depthSlot),
              Arc64.addImmBytes(dst: 16, src: 16, imm: 1),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.depthSlot)])
        // [titlebar setDrawsDecorationView: NO]
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 40),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selDecoSlot),
              Arc64.movz(dst: 2, value: 0),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        // [window setHasShadow: NO]  (also clears the gate so the observer stops next fire)
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 32),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selShadowSlot),
              Arc64.movz(dst: 2, value: 0),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        // [window _setCornerRadius: 0.01]  (d0 = the applied radius bits)
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 32),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selCornerSlot),
              Arc64.ldrd(dst: 0, base: 17, offset: AgentBlob.cornerOnSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        // Collapse the one-frame lag: setHasShadow:NO only marks the shadow stale, so force it to
        // recompute this cycle; displayIfNeeded forces the decoration redraw. Both run only on a
        // real regression (gated), so the cost is per-switch, not per-fire.
        // [window invalidateShadow]
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 32),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selInvalidateShadowSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        // [window displayIfNeeded]
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 32),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selDisplaySlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16)])
        // depth--
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.depthSlot),
              Arc64.subImmBytes(dst: 16, src: 16, imm: 1),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.depthSlot)])
        label("obsRowNext")
        emit([Arc64.ldr(dst: 2, base: 31, offset: 16),
              Arc64.addImmBytes(dst: 2, src: 2, imm: AgentBlob.opEntryBytes),
              Arc64.str(src: 2, base: 31, offset: 16),
              Arc64.ldr(dst: 15, base: 31, offset: 8),
              Arc64.subImmBytes(dst: 15, src: 15, imm: 1),
              Arc64.str(src: 15, base: 31, offset: 8)])
        branch(.cbz(src: 15, nonzero: true), "obsRowScan")
        label("obsRet")
        emit([Arc64.ldp(dst: 29, dst2: 30, base: 31, offset: 64),
              Arc64.addImm(dst: 31, src: 31, imm: 80),
              Arc64.ret()])
    }

    // MARK: the teardown subroutine (P1d/P1e)

    /// The resident agent's teardown, `blr`-callable with x0 = the state page. It runs as the body
    /// of the dispatched remove block (healthy main-queue CF state, no callback in flight), and
    /// does every un-publish the agent needs before its pages are freed:
    ///   - if an observer was created: CFRunLoopObserverInvalidate + CFRelease it (a live observer
    ///     pointing into freed pages faults on the next run-loop tick);
    ///   - if a wake timer is armed: CFRunLoopTimerInvalidate + CFRelease it (the P1c one-shot is
    ///     armed only on a deferral, so this is conditional — a removal racing an armed timer was
    ///     the pre-existing crash the side-agent note flagged);
    ///   - P1f: restore every class we added the setHasShadow: override to (method_setImplementation
    ///     back to the original IMP) — else every window of that class jumps into the freed blob on
    ///     its next shadow change. method_setImplementation answers the IMP it replaced: anything but
    ///     our override is a swizzle stacked on ours, whose saved original is our IMP — that IMP is
    ///     put back and `keepPagesSlot` is set, so the installer leaves the pages mapped;
    ///   - always: CFMachPortInvalidate the port (removes the source from every run loop) then
    ///     CFRelease the port and the source references.
    /// The conditionals live here because the Assembler has label/cbz branching; the Trampoline
    /// remove block (straight-line, absolute-address codegen) cannot express them, so it now just
    /// calls this. Frame 48: state@0, loop index@8, Method@16, pair@32. x0-x2/x9-x11/x16/x17 are
    /// touched; state is reloaded from the frame after every call (x16/x17 are ABI scratch).
    mutating func assembleTeardown() {
        emit([Arc64.subImm(dst: 31, src: 31, imm: 48),
              Arc64.stp(dst: 29, dst2: 30, base: 31, offset: 32),
              Arc64.addImm(dst: 29, src: 31, imm: 32),
              Arc64.str(src: 0, base: 31, offset: 0)])        // the state base, reloaded after calls
        // P1f: restore the setHasShadow: override on every recorded class before anything is freed.
        emit([Arc64.strZero(base: 31, offset: 8)])            // loop index i = 0
        label("tdShadowLoop")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 9, base: 31, offset: 8),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.shadowClassCountSlot),
              Arc64.cmpReg(lhs: 9, rhs: 16)])
        branch(.cond(2), "tdShadowDone")   // b.hs: i >= count — done
        // m = class_getInstanceMethod(table[i], setHasShadow:)
        emit([Arc64.addImm(dst: 2, src: 17, imm: AgentBlob.shadowClassTableSlot),
              Arc64.movz(dst: 11, value: 8),
              Arc64.mul(dst: 10, lhs: 9, rhs: 11),
              Arc64.addReg(dst: 2, lhs: 2, rhs: 10),
              Arc64.ldr(dst: 0, base: 2, offset: 0),           // cls = table[i]
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selShadowSlot),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.classGetInstanceMethodSlot),
              Arc64.blr(16),
              Arc64.str(src: 0, base: 31, offset: 16)])        // m, for a put-back
        // prev = method_setImplementation(m, shadowOrig)
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.shadowOrigSlot),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.methodSetImpSlot),
              Arc64.blr(16)])
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.shadowImpAddrSlot),
              Arc64.cmpReg(lhs: 0, rhs: 16)])
        branch(.cond(0), "tdShadowNext")   // b.eq: it was our override — restored
        // A swizzle stacked on ours: method_setImplementation(m, prev) puts it back, and the pages
        // stay (its saved original is our IMP).
        emit([Arc64.movReg(dst: 1, src: 0),
              Arc64.ldr(dst: 0, base: 31, offset: 16),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.methodSetImpSlot),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.movz(dst: 16, value: 1),
              Arc64.str(src: 16, base: 17, offset: AgentBlob.keepPagesSlot)])
        label("tdShadowNext")
        emit([Arc64.ldr(dst: 9, base: 31, offset: 8),
              Arc64.addImmBytes(dst: 9, src: 9, imm: 1),
              Arc64.str(src: 9, base: 31, offset: 8)])
        branch(.plain, "tdShadowLoop")
        label("tdShadowDone")
        // Retire every op-table row (zero rowOp). When the pages are freed this is a harmless no-op;
        // when they are kept (a stacked swizzle still calls our IMP, keepPages), it turns the IMP
        // into a pure pass-through so no stale op==1 row keeps forcing a window's shadow off (#3).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.movz(dst: 9, value: UInt16(AgentBlob.opTableCount)),
              Arc64.movz(dst: 2, value: UInt16(AgentBlob.opTableSlot)),
              Arc64.addReg(dst: 2, lhs: 2, rhs: 17)])
        label("tdRetireLoop")
        emit([Arc64.strZero(base: 2, offset: AgentBlob.rowOp),
              Arc64.addImmBytes(dst: 2, src: 2, imm: AgentBlob.opEntryBytes),
              Arc64.subImmBytes(dst: 9, src: 9, imm: 1)])
        branch(.cbz(src: 9, nonzero: true), "tdRetireLoop")
        // The observer, when one was created. Each released slot is zeroed after its release, so a
        // second teardown on kept pages cannot double-free (#4).
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.observerRefSlot),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(0), "tdTimer")   // b.eq: no observer
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.observerInvalidateSlot),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.observerRefSlot),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: tRelease),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.observerRefSlot),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.strZero(base: 17, offset: AgentBlob.observerRefSlot)])
        // The wake timer, when one is armed (P1c one-shot; conditional — the side-agent crash).
        label("tdTimer")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.wakeTimerSlot),
              Arc64.cmpImm(src: 16, imm: 0)])
        branch(.cond(0), "tdPort")   // b.eq: no timer armed
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: tTimerInvalidate),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.wakeTimerSlot),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: tRelease),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.wakeTimerSlot),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.strZero(base: 17, offset: AgentBlob.wakeTimerSlot)])
        // The CFMachPort and its source — always live for a ready agent (removeAgent runs only
        // when ready==1). Invalidate first so no callback can be scheduled, then release both refs.
        label("tdPort")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: tInvalidate),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.machPortRefSlot),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.ldr(dst: 16, base: 17, offset: tRelease),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.machPortRefSlot),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.strZero(base: 17, offset: AgentBlob.machPortRefSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tRelease),
              Arc64.ldr(dst: 0, base: 17, offset: AgentBlob.srcRefSlot),
              Arc64.blr(16),
              Arc64.ldr(dst: 17, base: 31, offset: 0),
              Arc64.strZero(base: 17, offset: AgentBlob.srcRefSlot)])
        emit([Arc64.ldp(dst: 29, dst2: 30, base: 31, offset: 32),
              Arc64.addImm(dst: 31, src: 31, imm: 48),
              Arc64.ret()])
    }

    // MARK: the setHasShadow: override IMP (P1f)

    /// The replacement implementation of `-[NSWindow setHasShadow:]` the observer adds to each
    /// managed window's class. Called by the ObjC runtime with x0=self, x1=_cmd, w2=flag — a method
    /// IMP gets NO context pointer, so the state-page base is baked into the first four words (a
    /// movImm64 placeholder the installer patches). If `self` is one of our applied windows (op==1
    /// in the op table) AND its live windowNumber still matches the row's wid, it forces the flag to
    /// NO so iTerm's `setHasShadow:YES` never turns the shadow on — the only flash-free fix (a
    /// reactive removal always loses one frame to the window server). The windowNumber check guards
    /// the case where a closed window's address was reused by a new window (object-identity match,
    /// different window): the new window keeps its shadow. Before forcing, a call made outside our own
    /// mutations (depth 0 — the app's, not the op path's or the backstop's) records the request in
    /// `rowAppShadow`, so restore hands the app back what it last asked for, not the apply-time
    /// snapshot (review #6). Then it restores x0-x2 and TAIL-CALLS
    /// (`br`) NSWindow's original IMP, so unmanaged windows (and managed ones, now with flag NO)
    /// behave normally. Writes only caller-saved registers + the saved frame pair; teardown restores
    /// this method to the original IMP before the pages are freed.
    ///
    /// Frame 80: self@0, _cmd@8, flag@16, state@24, rowWid@32, row@40, count@48, pair@64. The state
    /// base, the row cursor, and the scan count are saved so they survive the windowNumber msgSend
    /// (x9/x10/x17 are ABI scratch) — the count so a mismatch keeps scanning the other rows (#1).
    mutating func assembleShadowImp() {
        // x17 = the state-page base (installer-patched movImm64 — MUST be the first four words,
        // before the prologue; the prologue does not touch x17).
        emit(Arc64.movImm64(dst: 17, value: 0))
        emit([Arc64.subImm(dst: 31, src: 31, imm: 80),
              Arc64.stp(dst: 29, dst2: 30, base: 31, offset: 64),
              Arc64.addImm(dst: 29, src: 31, imm: 64),
              Arc64.str(src: 0, base: 31, offset: 0),       // self
              Arc64.str(src: 1, base: 31, offset: 8),       // _cmd
              Arc64.str(src: 2, base: 31, offset: 16),      // flag
              Arc64.str(src: 17, base: 31, offset: 24)])    // state base (reloaded after the call)
        emit([Arc64.movz(dst: 9, value: UInt16(AgentBlob.opTableCount)),
              Arc64.movz(dst: 10, value: UInt16(AgentBlob.opTableSlot)),
              Arc64.addReg(dst: 10, lhs: 10, rhs: 17)])   // x10 = state + opTableSlot (row cursor)
        label("shScan")
        emit([Arc64.ldr(dst: 11, base: 10, offset: AgentBlob.rowObject),
              Arc64.ldr(dst: 0, base: 31, offset: 0),       // self
              Arc64.cmpReg(lhs: 11, rhs: 0)])
        branch(.cond(1), "shNext")   // b.ne: not this window
        emit([Arc64.ldr(dst: 11, base: 10, offset: AgentBlob.rowOp),
              Arc64.cmpImm(src: 11, imm: 1)])
        branch(.cond(1), "shNext")   // b.ne: not an applied row (a restore row must pass through)
        // Object identity matched — confirm it is still the same window by number (guards an
        // address reused by a new window). rowWid is stashed; the msgSend clobbers x10/x11/x16/x17.
        emit([Arc64.ldr(dst: 11, base: 10, offset: AgentBlob.rowWid),
              Arc64.str(src: 11, base: 31, offset: 32),     // rowWid
              Arc64.str(src: 10, base: 31, offset: 40),     // row
              Arc64.str(src: 9, base: 31, offset: 48),      // scan count (the call clobbers x9)
              Arc64.ldr(dst: 17, base: 31, offset: 24),     // state
              Arc64.ldr(dst: 0, base: 31, offset: 0),       // self
              Arc64.ldr(dst: 1, base: 17, offset: AgentBlob.selWindowNumberSlot),
              Arc64.ldr(dst: 16, base: 17, offset: tMsgSend),
              Arc64.blr(16),                                // x0 = [self windowNumber]
              Arc64.ldr(dst: 11, base: 31, offset: 32),     // rowWid
              Arc64.cmpReg(lhs: 0, rhs: 11)])
        branch(.cond(0), "shRecord")   // b.eq: confirmed our window
        // Same address, a different window (the row is stale): restore the scan cursor and count the
        // call clobbered and keep scanning — another row may hold the real managed window (#1).
        emit([Arc64.ldr(dst: 10, base: 31, offset: 40),
              Arc64.ldr(dst: 9, base: 31, offset: 48)])
        branch(.plain, "shNext")
        // Confirmed our window. The app's own call (depth 0) records its request: the flag's low
        // byte (a BOOL's whole value; the upper bits of w2 are unspecified) + 1.
        label("shRecord")
        emit([Arc64.ldr(dst: 17, base: 31, offset: 24),
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.depthSlot)])
        branch(.cbz(src: 16, nonzero: true), "shForce")   // depth > 0: our own mutation — not intent
        emit([Arc64.ldrb(dst: 11, base: 31, offset: 16),
              Arc64.addImmBytes(dst: 11, src: 11, imm: 1),
              Arc64.ldr(dst: 10, base: 31, offset: 40),
              Arc64.str(src: 11, base: 10, offset: AgentBlob.rowAppShadow)])
        // Force the flag to NO.
        label("shForce")
        emit([Arc64.strZero(base: 31, offset: 16)])         // flag = NO
        branch(.plain, "shDone")
        label("shNext")
        emit([Arc64.addImmBytes(dst: 10, src: 10, imm: AgentBlob.opEntryBytes),
              Arc64.subImmBytes(dst: 9, src: 9, imm: 1)])
        branch(.cbz(src: 9, nonzero: true), "shScan")
        label("shDone")
        // Restore the ObjC arguments (flag may now be NO), tear the frame down, tail-call the
        // original NSWindow setHasShadow:.
        emit([Arc64.ldr(dst: 17, base: 31, offset: 24),     // state
              Arc64.ldr(dst: 0, base: 31, offset: 0),       // self
              Arc64.ldr(dst: 1, base: 31, offset: 8),       // _cmd
              Arc64.ldr(dst: 2, base: 31, offset: 16),      // flag
              Arc64.ldr(dst: 16, base: 17, offset: AgentBlob.shadowOrigSlot),
              Arc64.ldp(dst: 29, dst2: 30, base: 31, offset: 64),
              Arc64.addImm(dst: 31, src: 31, imm: 80),
              Arc64.br(16)])   // tail-call NSWindow's setHasShadow:(self, _cmd, flag)
    }
}
