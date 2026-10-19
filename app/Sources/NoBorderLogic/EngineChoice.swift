import Foundation

/// Which engine the app runs: the Phase 1 LLDB path, or the native one.
///
/// The switch is a launch argument and a `defaults` key, not a menu item, and it exists because of
/// how this phase was carried out: the native engine was not allowed to become the default until it
/// was accepted, so the shipped app had to be able to run either one while that was settled.
///
/// The default is `.native`. The benchmark's verdict was `not-beaten`: the AppKit calls a change
/// makes inside the app keep its main loop busy for hundreds of milliseconds, with gaps up to 286 ms
/// (`notes/task-7-bench.md` in the plan workspace). The human acceptance outranks that number — the
/// user ran this engine on their own desktop, on the real thing they care about, and said it works.
/// `.legacy` stays in the app and stays selectable, so the number can still be measured against it
/// and the old path can be reached on any one launch.
///
/// Strict on purpose: a value that is not one of these two names is not a typo to be forgiven, it is
/// somebody having set something that is not a choice, and the answer is the engine the app ships
/// with.
public enum EngineChoice: String {
    case legacy
    case native

    /// The launch argument the switch is read from, in the `-key value` form the system passes to a
    /// GUI app and records in the app's own defaults.
    public static let argumentKey = "noborderEngine"
    /// The `defaults` key, for `defaults write local.macos-no-window-border.app engine legacy`.
    public static let defaultsKey = "engine"

    /// The launch argument wins over the `defaults` key: it is the deliberate, this-run choice.
    /// A later occurrence of the argument wins over an earlier one, as the system's own parsing does.
    /// A spelling that is not one of the two names is not a choice, and gives the shipped default.
    public static func current(defaults: UserDefaults = .standard,
                              args: [String] = CommandLine.arguments) -> EngineChoice {
        let spelling = argumentValue(in: args) ?? defaults.string(forKey: defaultsKey)
        return spelling.flatMap(EngineChoice.init(rawValue:)) ?? .native
    }

    private static func argumentValue(in args: [String]) -> String? {
        var value: String?
        var index = 0
        let key = "-\(argumentKey)"
        while index < args.count {
            let arg = args[index]
            if arg == key {
                if index + 1 < args.count { value = args[index + 1] } else { value = nil }
            } else if arg.hasPrefix("\(key)=") {
                value = String(arg.dropFirst(key.count + 1))
            }
            index += 1
        }
        return value
    }
}
