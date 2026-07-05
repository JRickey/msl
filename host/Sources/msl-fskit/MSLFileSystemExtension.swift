import FSKit

/// ExtensionKit entry point for the `mslfs` FSKit module. FSKit discovers this
/// through `EXAppExtensionAttributes` in the appex `Info.plist`; the runtime
/// instantiates the extension and routes probe/load calls to `fileSystem`.
@main
struct MSLFileSystemExtension: UnaryFileSystemExtension {
    let fileSystem = MSLFileSystem()

    init() {}
}
