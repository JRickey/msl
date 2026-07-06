import FSKit

/// ExtensionKit entry point for the `mslfs` FSKit module. FSKit discovers this
/// through `EXAppExtensionAttributes` in the appex `Info.plist`; the runtime
/// instantiates the extension and routes probe/load calls to `fileSystem`.
/// `fileSystem` must be a computed property so the `FSUnaryFileSystem` is built
/// while `AppExtension.main()` assembles its configuration on the main actor —
/// an eager stored instance is created before the runtime is ready and the
/// extension process exits without serving.
@main
struct MSLFileSystemExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        MSLFileSystem()
    }
}
