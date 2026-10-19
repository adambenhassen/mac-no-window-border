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

    public init(windowNumbers: [UInt32], hasShadow: Bool?, cornerRadius: Double?, drawsDecoration: Bool?) {
        self.windowNumbers = windowNumbers
        self.hasShadow = hasShadow
        self.cornerRadius = cornerRadius
        self.drawsDecoration = drawsDecoration
    }

    /// The three changes: no outline/shadow, square corners, no titlebar rim.
    public static func applied(windowNumbers: [UInt32]) -> RemoteScript {
        RemoteScript(windowNumbers: windowNumbers, hasShadow: false, cornerRadius: 0.01, drawsDecoration: false)
    }

    /// Back to exactly what AppKit had before: shadow on, default corner radius, rim drawn.
    public static func restored(windowNumbers: [UInt32]) -> RemoteScript {
        RemoteScript(windowNumbers: windowNumbers, hasShadow: true, cornerRadius: 0.0, drawsDecoration: true)
    }
}

/// Addresses in the target process. The dyld shared cache is mapped at one address for the whole
/// boot, so an address resolved here is the same address in the target.
public struct AddressTable: Equatable {
    public var msgSend: UInt64
    public var selRegisterName: UInt64
    public var nsAppGlobal: UInt64

    public init(msgSend: UInt64, selRegisterName: UInt64, nsAppGlobal: UInt64) {
        self.msgSend = msgSend
        self.selRegisterName = selRegisterName
        self.nsAppGlobal = nsAppGlobal
    }
}
