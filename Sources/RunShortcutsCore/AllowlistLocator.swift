// SPDX-License-Identifier: Apache-2.0
//
//  AllowlistLocator.swift
//  RunShortcutsMCP
//
//  Resolves where to load the allowlist from, honoring (in priority order) an
//  explicit `--allowlist <path>` argument, the `RUNSHORTCUTS_ALLOWLIST`
//  environment variable, an auto-discovered config file (the per-user
//  Application Support location first, then a copy next to the app bundle), and
//  finally a default filename.
//

import Foundation

/// Pure logic for deciding which allowlist file path to use. Namespaced as an
/// `enum` with only static members (no instances).
public enum AllowlistLocator {
    /// (`String`) Environment variable consulted when no `--allowlist` argument is given.
    public static let environmentKey = "RUNSHORTCUTS_ALLOWLIST"

    /// (`String`) Default filename used when nothing else resolves (relative to the working directory).
    public static let defaultFilename = "allowlist.json"

    /// (`String`) The expected config filename: the running executable's name plus `.config` (e.g. `RunShortcutsMCP.config`).
    public static var configFileName: String {
        "\(ProcessInfo.processInfo.processName).config"
    }

    /// Resolves the allowlist path from CLI arguments, environment, and (optionally) an
    /// auto-discovered config file.
    ///
    /// Precedence: `--allowlist <path>` argument → `RUNSHORTCUTS_ALLOWLIST`
    /// environment variable → `discoveredConfig()` (an existing config found on disk) →
    /// the default `"allowlist.json"`.
    /// - Parameters:
    ///   - arguments: (`[String]`) Process arguments (excluding the executable name).
    ///   - environment: (`[String: String]`) The process environment map.
    ///   - discoveredConfig: (`() -> String?`) Supplies the path of an auto-discovered
    ///     config **only if it exists**, otherwise `nil`. Injected so the core stays
    ///     pure/testable; defaults to a closure returning `nil`.
    /// - Returns: (`String`) The chosen allowlist path; never empty.
    public static func resolve(
        arguments: [String],
        environment: [String: String],
        discoveredConfig: () -> String? = { nil }
    ) -> String {
        if let index = arguments.firstIndex(of: "--allowlist"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        if let path = environment[environmentKey], !path.isEmpty {
            return path
        }
        if let found = discoveredConfig() {
            return found
        }
        return defaultFilename
    }

    /// The auto-discovered config path: the per-user Application Support location if
    /// present, otherwise a copy sitting next to the app bundle.
    /// - Parameter fileManager: (`FileManager`) File system used for existence checks; defaults to `.default`.
    /// - Returns: (`String?`) The first existing config path, or `nil` if neither is present.
    public static func discoveredConfig(fileManager: FileManager = .default) -> String? {
        userConfigIfPresent(fileManager: fileManager) ?? adjacentConfigIfPresent(fileManager: fileManager)
    }

    /// The proper per-user config location:
    /// `~/Library/Application Support/<bundle-id>/<AppName>.config`, returned only if it exists.
    ///
    /// The bundle identifier comes from the running bundle (falling back to the process
    /// name when unbundled), so the folder always matches the app's signed identity.
    /// - Parameter fileManager: (`FileManager`) File system used to locate Application Support and test existence; defaults to `.default`.
    /// - Returns: (`String?`) The absolute path if the file exists, otherwise `nil`.
    public static func userConfigIfPresent(fileManager: FileManager = .default) -> String? {
        let bundleID = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let candidate = appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(configFileName)
        return fileManager.fileExists(atPath: candidate.path) ? candidate.path : nil
    }

    /// A convenience fallback: `<AppName>.config` sitting next to the app bundle (or next
    /// to the bare executable when unbundled), returned only if it exists.
    /// - Parameter fileManager: (`FileManager`) File system used for the existence check; defaults to `.default`.
    /// - Returns: (`String?`) The absolute path to the adjacent config if present, otherwise `nil`.
    public static func adjacentConfigIfPresent(fileManager: FileManager = .default) -> String? {
        let containingDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidate = containingDirectory.appendingPathComponent(configFileName)
        return fileManager.fileExists(atPath: candidate.path) ? candidate.path : nil
    }
}
