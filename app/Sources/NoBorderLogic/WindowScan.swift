import AppKit
import Darwin

/// One on-screen layer-0 window: what to change, in whose process, and where it is.
///
/// `frame` is in CG window coordinates — origin at the primary screen's top-left, y down — which is
/// the space the window list reports. Screen rectangles have to be converted into it before they can
/// be compared (see `WindowScan.cgFrame`).
public struct NormalWindow: Equatable {
    public let wid: UInt32
    public let pid: pid_t
    public let frame: CGRect

    public init(wid: UInt32, pid: pid_t, frame: CGRect) {
        self.wid = wid
        self.pid = pid
        self.frame = frame
    }
}

/// Which windows are on screen, and which of them fill their screen's usable area.
///
/// The window list and the maximized test, with no shadow tag: the WindowServer tag is never read
/// (a window we changed keeps reporting a shadow), so reading it would only cost a call per window.
/// Layer 0 is what AppKit puts ordinary app windows in; every panel, menu, and wallpaper window has
/// another layer and is not ours to change.
///
/// The scan does not decide maximized: the caller pairs these frames with `visibleFramesAsCG()` and
/// `isMaximized` when it turns them into `ScannedWindow`s, so the decision is one the tests can make
/// with any pair of screens.
///
/// Both live readers need a connection to the window server, which any process in a user session has.
/// `NSScreen`'s list is refreshed from screen-change notifications: in an app with a run loop it is
/// current, and in a short-lived tool it is what the screen looked like at launch.
public enum WindowScan {
    /// The window list. Layer 0 only, on-screen only, and in front-to-back order as WindowServer
    /// gives it. A window whose bounds the list does not carry is skipped: there is no frame to
    /// judge, and a window we cannot place is not one we may change.
    public static func normalWindows() -> [NormalWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var windows: [NormalWindow] = []
        for info in list {
            guard let layer = number(in: info, kCGWindowLayer), layer.intValue == 0,
                  let wid = number(in: info, kCGWindowNumber),
                  let pid = number(in: info, kCGWindowOwnerPID),
                  let bounds = bounds(in: info)
            else { continue }
            windows.append(NormalWindow(wid: wid.uint32Value, pid: pid.int32Value, frame: bounds))
        }
        return windows
    }

    /// The usable area of every screen, in the window list's coordinates.
    public static func visibleFramesAsCG() -> [CGRect] {
        // NSScreen's usable areas come from AppKit's screen notifications, which are delivered to an
        // application. In a process that has none — a command-line tool, a test bundle — every display
        // except the primary reports its whole frame, and a window maximized on it is then 25 pt short
        // of the area measured, i.e. never maximized. Asking for the shared application is the port of
        // [NSApplication sharedApplication]; it is a no-op in the app, which has one, and
        // the app's own activation policy is left untouched.
        _ = NSApplication.shared
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height
        return screens.map { cgFrame(fromAppKitVisibleFrame: $0.visibleFrame, primaryHeight: primaryHeight) }
    }

    /// Is `frame` a window filling one of these usable areas?
    ///
    /// The test is on four numbers — origin x, origin y, width, height — each within `tolerance`.
    /// Comparing the edges as four independent numbers is what the shipped scanner does, and it is
    /// not the same as "the frame is inside the area": a window the user pulled in on every side is
    /// 4 pt off in width and height at 2 pt per edge, and is a resized window, not a maximized one.
    /// A window is only ever compared to the whole set, so a maximized window on a secondary screen
    /// is found by that screen's entry; a window filling the wrong screen matches nothing.
    public static func isMaximized(_ frame: CGRect, in visible: [CGRect], tolerance: CGFloat = 2) -> Bool {
        visible.contains { area in
            abs(frame.minX - area.minX) <= tolerance
                && abs(frame.minY - area.minY) <= tolerance
                && abs(frame.width - area.width) <= tolerance
                && abs(frame.height - area.height) <= tolerance
        }
    }

    /// AppKit's visibleFrame → the same rectangle in the window list's coordinates.
    ///
    /// AppKit measures from the primary screen's bottom-left with y up; the window list from its
    /// top-left with y down. The x of a screen beside the primary is already in a shared space and
    /// is kept; only y is flipped, by the primary's height and the rectangle's own top edge.
    public static func cgFrame(fromAppKitVisibleFrame visibleFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: visibleFrame.minX,
               y: primaryHeight - visibleFrame.maxY,
               width: visibleFrame.width,
               height: visibleFrame.height)
    }

    /// The scan of a whole screen, reduced to what the tracker decides with: every normal window and
    /// whether it fills one of the usable areas. This is the pairing the plan puts in the scan loop,
    /// kept here so the geometry lives in one file; the loop takes it as an injected closure, which is
    /// what lets the loop's tests supply their own screen.
    public static func scan() -> [ScannedWindow] {
        let visible = visibleFramesAsCG()
        return normalWindows().map { window in
            ScannedWindow(wid: window.wid, pid: window.pid,
                          maximized: isMaximized(window.frame, in: visible))
        }
    }

    private static func number(in info: [String: Any], _ key: CFString) -> NSNumber? {
        info[key as String] as? NSNumber
    }

    private static func bounds(in info: [String: Any]) -> CGRect? {
        guard let raw = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: raw as CFDictionary)
    }
}
