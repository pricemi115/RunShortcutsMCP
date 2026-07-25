// SPDX-License-Identifier: Apache-2.0
//
//  ConfigProvisioner.swift
//  RunShortcutsMCP
//
//  First-run provisioning of the per-user configuration directory. Creates the
//  Application Support folder, seeds an empty (default-deny) allowlist if none
//  exists, and drops the user manual and example config alongside it — so a
//  freshly installed app sets up its own editable config without any installer
//  scripting.
//

import Foundation

/// Pure-logic helper that provisions the per-user config directory on first run.
/// Namespaced as an `enum` with only static members (no instances).
public enum ConfigProvisioner {
    /// (`String`) Default contents written for a brand-new config: an empty,
    /// default-deny allowlist the user then fills in.
    public static let emptyConfigContents = "{\n  \"shortcuts\": {}\n}\n"

    /// Computes the per-user Application Support directory for a bundle identifier
    /// (`~/Library/Application Support/<bundle-id>/`).
    /// - Parameters:
    ///   - bundleID: (`String`) The app's bundle identifier, used as the subfolder name.
    ///   - fileManager: (`FileManager`) File system used to locate Application Support; defaults to `.default`.
    /// - Returns: (`URL?`) The directory URL, or `nil` if Application Support can't be located.
    public static func applicationSupportDirectory(bundleID: String, fileManager: FileManager = .default) -> URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    /// Ensures the destination directory exists, seeds the config file with
    /// `defaultConfigContents` **only if it does not already exist** (never
    /// overwrites the user's config), and refreshes the manual/example copies.
    /// - Parameters:
    ///   - destinationDirectory: (`URL`) Folder to provision (typically the Application Support subfolder).
    ///   - configFileName: (`String`) Name of the live config file to seed (e.g. `RunShortcutsMCP.config`).
    ///   - defaultConfigContents: (`String`) Text written when the config is absent.
    ///   - assets: (`[URL]`) Bundled reference files (manual, example config, example shortcut, …) copied alongside the config and refreshed on each run. Empty to skip.
    ///   - fileManager: (`FileManager`) File system to use; defaults to `.default`.
    /// - Returns: (`URL`) The path of the live config file.
    /// - Throws: An error if the destination directory cannot be created or the initial config cannot be written.
    @discardableResult
    public static func provision(
        into destinationDirectory: URL,
        configFileName: String,
        defaultConfigContents: String,
        assets: [URL] = [],
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let configURL = destinationDirectory.appendingPathComponent(configFileName)
        if !fileManager.fileExists(atPath: configURL.path) {
            try Data(defaultConfigContents.utf8).write(to: configURL)
        }

        // Refresh the bundled reference files each run so app updates ship current
        // copies. Best-effort: failures here must not block startup.
        for source in assets {
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            try? fileManager.removeItem(at: destination)
            try? fileManager.copyItem(at: source, to: destination)
        }

        return configURL
    }
}
