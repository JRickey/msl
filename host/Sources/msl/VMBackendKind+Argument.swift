import ArgumentParser
import MSLCore

/// Let `msl boot --backend <vz|krun>` parse a `VMBackendKind` directly. The
/// conformance lives in the CLI target so MSLCore stays free of ArgumentParser;
/// `VMBackendKind` is `String`-backed, so ArgumentParser's `RawRepresentable`
/// default supplies `init?(argument:)` and this body stays empty.
extension VMBackendKind: @retroactive ExpressibleByArgument {}
