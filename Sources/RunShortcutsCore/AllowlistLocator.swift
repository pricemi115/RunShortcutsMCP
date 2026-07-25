//
//  AllowlistLocator.swift
//  RunShortcutsMCP
//
//  Resolves where to load the allowlist from, honoring (in priority order) an
//  explicit `--allowlist <path>` argument, the `RUNSHORTCUTS_ALLOWLIST`
//  environment variable, and finally a default filename.
//

import Foundation

/// Pure logic for deciding which allowlist file path to use. Namespaced as an
/// `enum` with only static members (no instances).
public enum AllowlistLocator {
    /// (`String`) Environment variable consulted when no `--allowlist` argument is given.
    public static let environmentKey = "RUNSHORTCUTS_ALLOWLIST"

    /// Resolves the allowlist path from CLI arguments and environment.
    ///
    /// Precedence: `--allowlist <path>` argument, then the `RUNSHORTCUTS_ALLOWLIST`
    /// environment variable, then the default `"allowlist.json"`.
    /// - Parameters:
    ///   - arguments: (`[String]`) Process arguments (excluding the executable name).
    ///   - environment: (`[String: String]`) The process environment map.
    /// - Returns: (`String`) The chosen allowlist path; never empty.
    public static func resolve(arguments: [String], environment: [String: String]) -> String {
        if let index = arguments.firstIndex(of: "--allowlist"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        if let path = environment[environmentKey], !path.isEmpty {
            return path
        }
        return "allowlist.json"
    }
}
