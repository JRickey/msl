import CryptoKit
import Foundation

public enum CatalogDownloadProgress: Equatable, Sendable {
    case checkingCache(path: String)
    case cacheHit(path: String)
    case startingDownload(url: String, bytes: UInt64)
    case downloading(received: UInt64, total: UInt64?)
    case verifying(path: String, sha256: String)
    case ready(path: String)
}

public typealias CatalogDownloadProgressHandler = @Sendable (CatalogDownloadProgress) -> Void

public struct CatalogDownloader: Sendable {
    private let home: MSLHome

    public init(home: MSLHome) {
        self.home = home
    }

    public func fetch(
        _ resolved: CatalogResolved, progress: CatalogDownloadProgressHandler? = nil
    ) throws -> URL {
        try home.ensureDirectories()
        let destination = try destinationURL(for: resolved)
        progress?(.checkingCache(path: destination.path))
        if try verifyIfPresent(destination, sha256: resolved.artifact.sha256) {
            progress?(.cacheHit(path: destination.path))
            return destination
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        progress?(.startingDownload(url: resolved.artifact.url, bytes: resolved.artifact.sizeBytes))
        try download(
            url: resolved.artifact.url, output: partial, expectedBytes: resolved.artifact.sizeBytes,
            progress: progress)
        progress?(.verifying(path: partial.path, sha256: resolved.artifact.sha256))
        guard try sha256Hex(partial) == resolved.artifact.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw MSLError.configuration("download SHA256 mismatch for \(resolved.selector)")
        }
        try replace(partial, destination)
        progress?(.ready(path: destination.path))
        return destination
    }

    private func destinationURL(for resolved: CatalogResolved) throws -> URL {
        let basename = URL(string: resolved.artifact.url)?.lastPathComponent ?? ""
        guard !basename.isEmpty, basename != ".", basename != "..", !basename.contains("/") else {
            throw MSLError.configuration("catalog artifact basename invalid")
        }
        return home.catalogCacheDirectory
            .appendingPathComponent(resolved.family.name)
            .appendingPathComponent(resolved.version.version)
            .appendingPathComponent(resolved.artifact.sha256)
            .appendingPathComponent(basename)
    }

    private func verifyIfPresent(_ url: URL, sha256: String) throws -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        if try sha256Hex(url) == sha256 { return true }
        try? FileManager.default.removeItem(at: url)
        return false
    }

    private func download(
        url: String, output: URL, expectedBytes: UInt64,
        progress: CatalogDownloadProgressHandler?
    ) throws {
        guard let source = URL(string: url), source.scheme == "https" else {
            throw MSLError.configuration("catalog URL must be HTTPS: \(url)")
        }
        let delegate = CatalogDownloadDelegate(
            output: output, expectedBytes: expectedBytes, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.downloadTask(with: source).resume()
        try delegate.wait()
    }

    private func replace(_ source: URL, _ destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func sha256Hex(_ url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw MSLError.io("cannot read \(url.path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct CatalogIconStore: Sendable {
    private let home: MSLHome

    public init(home: MSLHome) {
        self.home = home
    }

    public func icon(
        for resolved: CatalogResolved, progress: CatalogDownloadProgressHandler? = nil
    ) throws -> URL? {
        guard let icon = resolved.version.icon else { return nil }
        return try self.icon(icon, label: resolved.selector, progress: progress)
    }

    public func icon(
        _ icon: CatalogIcon, label: String, progress: CatalogDownloadProgressHandler? = nil
    ) throws -> URL {
        try home.ensureDirectories()
        let original = try originalURL(for: icon)
        progress?(.checkingCache(path: original.path))
        if !(try verifyIfPresent(original, sha256: icon.sha256)) {
            try FileManager.default.createDirectory(
                at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = original.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: partial)
            progress?(.startingDownload(url: icon.url, bytes: icon.sizeBytes))
            try download(
                url: icon.url, output: partial, expectedBytes: icon.sizeBytes, progress: progress)
            progress?(.verifying(path: partial.path, sha256: icon.sha256))
            guard try sha256Hex(partial) == icon.sha256 else {
                try? FileManager.default.removeItem(at: partial)
                throw MSLError.configuration("icon SHA256 mismatch for \(label)")
            }
            try replace(partial, original)
        } else {
            progress?(.cacheHit(path: original.path))
        }
        let converted = try convertedURL(for: original, icon: icon)
        progress?(.ready(path: converted.path))
        return converted
    }

    private func originalURL(for icon: CatalogIcon) throws -> URL {
        var basename = URL(string: icon.url)?.lastPathComponent ?? ""
        if icon.kind == .svg, !basename.hasSuffix(".svg") {
            basename += ".svg"
        }
        guard !basename.isEmpty, basename != ".", basename != "..", !basename.contains("/") else {
            throw MSLError.configuration("catalog icon basename invalid")
        }
        return home.catalogIconCacheDirectory
            .appendingPathComponent(icon.sha256)
            .appendingPathComponent(basename)
    }

    private func convertedURL(for original: URL, icon: CatalogIcon) throws -> URL {
        switch icon.kind {
        case .icns:
            try LauncherIcon.validateICNS(at: original)
            return original
        case .png:
            let target = convertedTarget(for: original, icon: icon)
            if isValidICNS(target) {
                return target
            }
            let png = try Data(contentsOf: original)
            try LauncherIcon.writeICNS(
                pngData: CatalogIconStyler.styledPNG(png, icon: icon), to: target)
            return target
        case .svg:
            let target = convertedTarget(for: original, icon: icon)
            if isValidICNS(target) {
                return target
            }
            let png = try rasterizeSVG(original, icon: icon)
            try LauncherIcon.writeICNS(
                pngData: CatalogIconStyler.styledPNG(png, icon: icon), to: target)
            return target
        }
    }

    private func convertedTarget(for original: URL, icon: CatalogIcon) -> URL {
        guard let backgroundHex = icon.backgroundHex else {
            return original.deletingPathExtension().appendingPathExtension("icns")
        }
        return original.deletingPathExtension().appendingPathExtension("\(backgroundHex).v3.icns")
    }

    private func rasterizeSVG(_ original: URL, icon: CatalogIcon) throws -> Data {
        try validateSVG(original)
        let source = try styledSVGURL(original, icon: icon)
        defer {
            if source != original {
                try? FileManager.default.removeItem(at: source)
            }
        }
        let png = source.appendingPathExtension("png")
        try? FileManager.default.removeItem(at: png)
        try runProcess(
            "/usr/bin/qlmanage",
            ["-t", "-s", "1024", "-o", source.deletingLastPathComponent().path, source.path])
        guard FileManager.default.isReadableFile(atPath: png.path) else {
            throw MSLError.io("Quick Look did not render \(source.path)")
        }
        defer { try? FileManager.default.removeItem(at: png) }
        return try Data(contentsOf: png)
    }

    private func styledSVGURL(_ original: URL, icon: CatalogIcon) throws -> URL {
        guard icon.backgroundHex != nil else { return original }
        let data = try Data(contentsOf: original, options: .mappedIfSafe)
        let styled = try CatalogIconStyler.styledSVG(data, icon: icon)
        let target = original.deletingPathExtension().appendingPathExtension("styled.svg")
        try styled.write(to: target, options: .atomic)
        return target
    }

    private func validateSVG(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 5_000_000 else {
            throw MSLError.configuration("icon SVG is too large: \(url.path)")
        }
        guard let text = String(data: data.prefix(4096), encoding: .utf8),
            text.range(of: #"<svg\b"#, options: .regularExpression) != nil
        else {
            throw MSLError.configuration("icon is not an SVG file: \(url.path)")
        }
    }

    private func isValidICNS(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        return (try? LauncherIcon.validateICNS(at: url)) != nil
    }

    private func verifyIfPresent(_ url: URL, sha256: String) throws -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        if try sha256Hex(url) == sha256 { return true }
        try? FileManager.default.removeItem(at: url)
        return false
    }

    private func download(
        url: String, output: URL, expectedBytes: UInt64,
        progress: CatalogDownloadProgressHandler?
    ) throws {
        guard let source = URL(string: url), source.scheme == "https" else {
            throw MSLError.configuration("catalog icon URL must be HTTPS: \(url)")
        }
        let delegate = CatalogDownloadDelegate(
            output: output, expectedBytes: expectedBytes, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 10 * 60
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.downloadTask(with: source).resume()
        try delegate.wait()
    }

    private func replace(_ source: URL, _ destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func runProcess(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MSLError.io("\(executable) failed with status \(process.terminationStatus)")
        }
    }

    private func sha256Hex(_ url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw MSLError.io("cannot read \(url.path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
