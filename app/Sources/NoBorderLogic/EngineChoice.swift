import Foundation

/// Which engine the app runs: the Phase 1 LLDB path, or the native one.
///
/// The switch is a launch argument and a `defaults` key, not a menu item, and it exists because of
/// how this phase is being carried out: the native engine is not allowed to become the default until
/// the benchmark says it stops an app's main loop less than 5 ms, so the shipped app must be able to
/// run either one while that is settled. The default is `.legacy` — the engine shipping in v1.1.
///
/// Strict on purpose: a value that is not one of these two names is not a typo to be forgiven, it is
/// somebody having set something else, and the safe answer is the engine that is known to work.
public enum EngineChoice: String {
    case legacy
    case native

    /// The launch argument the switch is read from, in the `-key value` form the system passes to a
    /// GUI app and records in the app's own defaults.
    public static let argumentKey = "noborderEngine"
    /// The `defaults` key, for `defaults write com.example.noborder engine native`.
    public static let defaultsKey = "engine"

    /// The launch argument wins over the `defaults` key: it is the deliberate, this-run choice.
    /// A later occurrence of the argument wins over an earlier one, as the system's own parsing does.
    public static func current(defaults: UserDefaults = .standard,
                              args: [String] = CommandLine.arguments) -> EngineChoice {
        let spelling = argumentValue(in: args) ?? defaults.string(forKey: defaultsKey)
        return spelling.flatMap(EngineChoice.init(rawValue:)) ?? .legacy
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
