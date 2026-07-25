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

/// Errors raised by `ConfigProvisioner`.
public enum ConfigProvisionerError: Error, Equatable {
    /// The seeded config file could not be created. `code` is the POSIX `errno`
    /// (e.g. `ELOOP` when a symlink was planted at the target path).
    case writeFailed(path: String, code: Int32)
}

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
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let configURL = destinationDirectory.appendingPathComponent(configFileName)
        if !fileManager.fileExists(atPath: configURL.path) {
            // Owner-only, symlink-safe write so a pre-planted symlink at this path
            // can't redirect the seeded config elsewhere (CWE-59 / CWE-276).
            try writeNewFileSecurely(Data(defaultConfigContents.utf8), to: configURL)
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

    /// Writes `data` to a brand-new file at `url` with owner-only permissions (`0600`),
    /// refusing to follow a symlink at that path (`O_NOFOLLOW`) and failing if the file
    /// already exists (`O_EXCL`). A benign "already exists" is treated as a no-op so a
    /// race with another instance doesn't surface as an error.
    /// - Parameters:
    ///   - data: (`Data`) Bytes to write.
    ///   - url: (`URL`) Destination file path.
    /// - Throws: `ConfigProvisionerError.writeFailed` if the file cannot be created for
    ///   any reason other than already existing.
    private static func writeNewFileSecurely(_ data: Data, to url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        if descriptor == -1 {
            let code = errno
            // `O_EXCL` reports a symlink planted at the path as `EEXIST` (not `ELOOP`).
            // Surface that as an error rather than silently skipping, so a tampering
            // attempt isn't ignored. A benign `EEXIST` from a regular file racing in
            // (after the outer existence check) is treated as a no-op.
            if isSymlink(at: url) {
                throw ConfigProvisionerError.writeFailed(path: url.path, code: code)
            }
            if code == EEXIST { return }
            throw ConfigProvisionerError.writeFailed(path: url.path, code: code)
        }
        defer { close(descriptor) }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written <= 0 {
                    throw ConfigProvisionerError.writeFailed(path: url.path, code: errno)
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    /// Reports whether `url` is itself a symbolic link, without following it (`lstat`).
    /// - Parameter url: (`URL`) The path to test.
    /// - Returns: (`Bool`) `true` if the path exists and is a symbolic link.
    private static func isSymlink(at url: URL) -> Bool {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        return result == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }
}
