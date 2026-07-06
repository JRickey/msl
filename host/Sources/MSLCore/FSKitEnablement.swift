import Foundation
import MSLFSWire

public enum FSKitEnablement {
    public static func plistPath(homeDirectory: String = NSHomeDirectory()) -> String {
        precondition(!homeDirectory.isEmpty, "home directory must not be empty")
        return URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent("group.com.apple.fskit.settings")
            .appendingPathComponent("enabledModules.plist").path
    }

    public static func isEnabled(
        moduleID: String = FSProto.appexBundleID, homeDirectory: String = NSHomeDirectory()
    ) throws -> Bool {
        return try isEnabled(
            moduleID: moduleID, at: URL(fileURLWithPath: plistPath(homeDirectory: homeDirectory)))
    }

    public static func isEnabled(
        moduleID: String = FSProto.appexBundleID, at url: URL
    ) throws -> Bool {
        precondition(!moduleID.isEmpty, "module id must not be empty")
        precondition(url.isFileURL, "settings plist must be a file URL")
        return try loadModules(from: url).contains(moduleID)
    }

    @discardableResult
    public static func enable(
        moduleID: String = FSProto.appexBundleID, homeDirectory: String = NSHomeDirectory()
    ) throws -> Bool {
        return try enable(
            moduleID: moduleID, at: URL(fileURLWithPath: plistPath(homeDirectory: homeDirectory)))
    }

    @discardableResult
    public static func enable(
        moduleID: String = FSProto.appexBundleID, at url: URL
    ) throws -> Bool {
        precondition(!moduleID.isEmpty, "module id must not be empty")
        precondition(url.isFileURL, "settings plist must be a file URL")
        var modules = try loadModules(from: url)
        guard !modules.contains(moduleID) else { return false }
        modules.append(moduleID)
        try saveModules(modules, to: url)
        return true
    }

    @discardableResult
    public static func disable(
        moduleID: String = FSProto.appexBundleID, homeDirectory: String = NSHomeDirectory()
    ) throws -> Bool {
        return try disable(
            moduleID: moduleID, at: URL(fileURLWithPath: plistPath(homeDirectory: homeDirectory)))
    }

    @discardableResult
    public static func disable(
        moduleID: String = FSProto.appexBundleID, at url: URL
    ) throws -> Bool {
        precondition(!moduleID.isEmpty, "module id must not be empty")
        precondition(url.isFileURL, "settings plist must be a file URL")
        let modules = try loadModules(from: url)
        let filtered = modules.filter { $0 != moduleID }
        guard filtered.count != modules.count else { return false }
        try saveModules(filtered, to: url)
        return true
    }

    private static func loadModules(from url: URL) throws -> [String] {
        assert(url.isFileURL, "settings plist must be a file URL")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let modules = plist as? [String] else {
            throw MSLError.configuration("\(url.path) must be a plist array of module identifiers")
        }
        return modules
    }

    private static func saveModules(_ modules: [String], to url: URL) throws {
        assert(url.isFileURL, "settings plist must be a file URL")
        assert(modules.allSatisfy { !$0.isEmpty }, "module identifiers must be non-empty")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: modules, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
