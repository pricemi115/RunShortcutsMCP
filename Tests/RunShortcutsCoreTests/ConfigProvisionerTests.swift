// SPDX-License-Identifier: Apache-2.0
//
//  ConfigProvisionerTests.swift
//  RunShortcutsMCPTests
//
//  Unit tests for first-run config provisioning: seeding the default config,
//  never overwriting an existing config, and copying the manual/example.
//

import XCTest
@testable import RunShortcutsCore

/// Exercises `ConfigProvisioner.provision` against a temporary directory.
final class ConfigProvisionerTests: XCTestCase {
    /// (`URL`) A unique temporary directory created for each test.
    private var tempRoot: URL!

    /// Creates a fresh temporary directory before each test.
    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RunShortcutsMCPTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// Removes the temporary directory after each test.
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Verifies the default config is written when none exists.
    /// - Throws: Rethrows provisioning/file errors.
    func testSeedsDefaultConfigWhenAbsent() throws {
        let dir = tempRoot.appendingPathComponent("Support", isDirectory: true)
        let configURL = try ConfigProvisioner.provision(
            into: dir,
            configFileName: "RunShortcutsMCP.config",
            defaultConfigContents: ConfigProvisioner.emptyConfigContents
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(contents, ConfigProvisioner.emptyConfigContents)
    }

    /// Verifies an existing config is never overwritten by provisioning.
    /// - Throws: Rethrows provisioning/file errors.
    func testDoesNotOverwriteExistingConfig() throws {
        let dir = tempRoot.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configURL = dir.appendingPathComponent("RunShortcutsMCP.config")
        let userContents = "{\"shortcuts\":{\"MyShortcut\":{\"description\":\"x\"}}}"
        try Data(userContents.utf8).write(to: configURL)

        try ConfigProvisioner.provision(
            into: dir,
            configFileName: "RunShortcutsMCP.config",
            defaultConfigContents: ConfigProvisioner.emptyConfigContents
        )

        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), userContents)
    }

    /// Verifies the manual and example files are copied into the directory when provided.
    /// - Throws: Rethrows provisioning/file errors.
    func testCopiesManualAndExample() throws {
        let dir = tempRoot.appendingPathComponent("Support", isDirectory: true)
        let sources = tempRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let manual = sources.appendingPathComponent("MANUAL.md")
        let example = sources.appendingPathComponent("RunShortcutsMCP.config.example")
        try Data("manual".utf8).write(to: manual)
        try Data("example".utf8).write(to: example)

        try ConfigProvisioner.provision(
            into: dir,
            configFileName: "RunShortcutsMCP.config",
            defaultConfigContents: ConfigProvisioner.emptyConfigContents,
            assets: [manual, example]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("MANUAL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("RunShortcutsMCP.config.example").path))
    }
}
