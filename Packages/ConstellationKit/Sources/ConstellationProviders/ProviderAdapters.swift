import ConstellationCore
import Foundation

public enum ProviderError: Error, Hashable, Sendable {
    case binaryNotFound(String)
    case protocolViolation(String)
    case processExited(code: Int32)
}
