import Foundation
import UniformTypeIdentifiers

/// The `.msl` distribution type this app exports (ADR 0010). Resolves the
/// declared identifier when LaunchServices knows it, else falls back to the
/// filename extension so the open panel filters correctly regardless.
enum MSLBundleType {
    static let identifier = "dev.msl.msl-distribution"
    static let fileExtension = "msl"

    static var contentType: UTType {
        if let declared = UTType(identifier) { return declared }
        if let byExtension = UTType(filenameExtension: fileExtension, conformingTo: .data) {
            return byExtension
        }
        return .data
    }
}
