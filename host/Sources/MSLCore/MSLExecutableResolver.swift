import Foundation

public enum MSLExecutableResolver {
    public static func resolve(
        currentExecutablePath: String,
        fileManager: FileManager = .default
    ) -> String {
        assert(!currentExecutablePath.isEmpty)
        guard !currentExecutablePath.isEmpty else { return "msl" }
        let currentURL = URL(fileURLWithPath: currentExecutablePath)
        assert(!currentURL.lastPathComponent.isEmpty)
        guard currentURL.lastPathComponent != "msl" else { return currentExecutablePath }

        let macOSDirectory = currentURL.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        let appDirectory = contentsDirectory.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS",
            contentsDirectory.lastPathComponent == "Contents",
            appDirectory.pathExtension == "app"
        else {
            return currentExecutablePath
        }

        let siblingPath = macOSDirectory.appendingPathComponent("msl").path
        let siblingExists = fileManager.fileExists(atPath: siblingPath)
        let siblingAttributes = try? fileManager.attributesOfItem(atPath: siblingPath)
        let siblingType = siblingAttributes?[.type] as? FileAttributeType
        let siblingIsSymbolicLink =
            (try? fileManager.destinationOfSymbolicLink(atPath: siblingPath)) != nil
        let siblingIsExecutable = fileManager.isExecutableFile(atPath: siblingPath)
        guard siblingExists, siblingType == .typeRegular, !siblingIsSymbolicLink,
            siblingIsExecutable
        else {
            return currentExecutablePath
        }
        return siblingPath
    }
}
