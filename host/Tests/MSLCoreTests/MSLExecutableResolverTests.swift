import Foundation
import Testing

@testable import MSLCore

@Suite("MSL executable resolver")
struct MSLExecutableResolverTests {
    @Test("CLI invocation keeps the current executable")
    func cliInvocation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("msl")
        try makeFile(at: executable, executable: true)

        let resolved = MSLExecutableResolver.resolve(currentExecutablePath: executable.path)

        #expect(resolved == executable.path)
        #expect(FileManager.default.isExecutableFile(atPath: resolved))
    }

    @Test("Packaged frontend resolves its bundled CLI sibling")
    func packagedFrontend() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let macOS = root.appendingPathComponent("MSL.app/Contents/MacOS")
        let frontend = macOS.appendingPathComponent("msl-menubar")
        let cli = macOS.appendingPathComponent("msl")
        try makeFile(at: frontend, executable: true)
        try makeFile(at: cli, executable: true)

        let resolved = MSLExecutableResolver.resolve(currentExecutablePath: frontend.path)

        #expect(resolved == cli.path)
        #expect(FileManager.default.isExecutableFile(atPath: resolved))
    }

    @Test("Missing and non-executable siblings keep the current executable")
    func unusableSibling() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let macOS = root.appendingPathComponent("MSL.app/Contents/MacOS")
        let frontend = macOS.appendingPathComponent("msl-menubar")
        let cli = macOS.appendingPathComponent("msl")
        try makeFile(at: frontend, executable: true)

        let missing = MSLExecutableResolver.resolve(currentExecutablePath: frontend.path)
        try makeFile(at: cli, executable: false)
        let nonExecutable = MSLExecutableResolver.resolve(currentExecutablePath: frontend.path)

        #expect(missing == frontend.path)
        #expect(nonExecutable == frontend.path)
    }

    @Test("Development binary does not use a nearby CLI")
    func developmentBinary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let frontend = root.appendingPathComponent("msl-menubar")
        let cli = root.appendingPathComponent("msl")
        try makeFile(at: frontend, executable: true)
        try makeFile(at: cli, executable: true)

        let resolved = MSLExecutableResolver.resolve(currentExecutablePath: frontend.path)

        #expect(resolved == frontend.path)
        #expect(resolved != cli.path)
    }

    @Test("Executable directory sibling is rejected")
    func directorySibling() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let macOS = root.appendingPathComponent("MSL.app/Contents/MacOS")
        let frontend = macOS.appendingPathComponent("msl-menubar")
        let cliDirectory = macOS.appendingPathComponent("msl", isDirectory: true)
        try makeFile(at: frontend, executable: true)
        try FileManager.default.createDirectory(
            at: cliDirectory,
            withIntermediateDirectories: false
        )

        let resolved = MSLExecutableResolver.resolve(currentExecutablePath: frontend.path)

        #expect(FileManager.default.isExecutableFile(atPath: cliDirectory.path))
        #expect(resolved == frontend.path)
    }

    @Test("Bundle paths containing spaces resolve without rewriting")
    func pathWithSpaces() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let macOS = root.appendingPathComponent("MSL Preview.app/Contents/MacOS")
        let frontend = macOS.appendingPathComponent("msl-menubar")
        let cli = macOS.appendingPathComponent("msl")
        try makeFile(at: frontend, executable: true)
        try makeFile(at: cli, executable: true)

        let resolved = MSLExecutableResolver.resolve(currentExecutablePath: frontend.path)

        #expect(resolved == cli.path)
        #expect(resolved.contains("MSL Preview.app"))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(root.isFileURL)
        return root
    }

    private func makeFile(at url: URL, executable: Bool) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let created = FileManager.default.createFile(atPath: url.path, contents: Data())
        #expect(created)
        guard created else { throw CocoaError(.fileWriteUnknown) }
        let permissions = executable ? 0o755 : 0o644
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
