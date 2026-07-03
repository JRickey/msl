import Foundation

/// Errors surfaced by the host VMM and vsock client. Every case carries a
/// message; VZ failures embed the underlying NSError domain and code.
public enum MSLError: Error, CustomStringConvertible, Sendable {
    case invalidArgument(String)
    case configuration(String)
    case vzFailure(operation: String, domain: String, code: Int, detail: String)
    case timedOut(String)
    case io(String)
    case framing(String)
    case protocolMismatch(String)
    case remote(String)

    /// Wrap a Foundation error as a `vzFailure`, preserving domain and code as
    /// the primary debugging surface for Virtualization.framework paths.
    public static func fromVZ(_ operation: String, _ error: Error) -> MSLError {
        precondition(!operation.isEmpty, "operation label must not be empty")
        let nsError = error as NSError
        return .vzFailure(
            operation: operation,
            domain: nsError.domain,
            code: nsError.code,
            detail: nsError.localizedDescription)
    }

    public var description: String {
        switch self {
        case .invalidArgument(let message):
            return "invalid argument: \(message)"
        case .configuration(let message):
            return "configuration error: \(message)"
        case .vzFailure(let operation, let domain, let code, let detail):
            return "\(operation) failed [\(domain) code=\(code)]: \(detail)"
        case .timedOut(let message):
            return "timed out: \(message)"
        case .io(let message):
            return "i/o error: \(message)"
        case .framing(let message):
            return "framing error: \(message)"
        case .protocolMismatch(let message):
            return "protocol error: \(message)"
        case .remote(let message):
            return message
        }
    }
}
