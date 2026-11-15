import ConstellationCore
import ConstellationMCP

extension LiveOutput {
    /// A `request_secret` result carries the value after a marker; nothing past it is ever shown.
    static func redacted(_ text: String) -> String {
        guard let range = text.range(of: MCPServer.secretValueMarker) else { return text }
        return String(text[..<range.lowerBound])
    }
}

extension AskKind {
    var footerLabel: String {
        switch self {
        case .permission: "Permission"
        case .question: "Question"
        case .secret: "Secret"
        }
    }
}
