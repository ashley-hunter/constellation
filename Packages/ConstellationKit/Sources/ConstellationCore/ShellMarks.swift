import Foundation

/// An OSC 133 shell-integration mark: where a prompt starts, a command starts, or a command ends.
public enum ShellMark: Equatable, Sendable {
    case promptStarted
    case commandStarted
    case commandFinished(exitCode: Int32?)
}

/// Finds OSC 133 marks in a terminal's output stream. Sequences may be split across reads, so the
/// scanner keeps its place between calls. Everything else in the stream is ignored.
public struct ShellMarkScanner: Sendable {
    private enum State: Sendable {
        case ground, escape, osc, oscEscape, skippingOSC
    }

    private static let prefix = Array("133;".utf8)
    private static let maxPayload = 64

    private var state = State.ground
    private var payload: [UInt8] = []

    public init() {}

    public mutating func scan(_ bytes: some Sequence<UInt8>) -> [ShellMark] {
        var marks: [ShellMark] = []
        for byte in bytes {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }
            case .escape:
                if byte == 0x5D {
                    state = .osc
                    payload.removeAll(keepingCapacity: true)
                } else if byte != 0x1B {
                    state = .ground
                }
            case .osc:
                switch byte {
                case 0x07:
                    finish(into: &marks)
                case 0x1B:
                    state = .oscEscape
                default:
                    payload.append(byte)
                    let checked = min(payload.count, Self.prefix.count)
                    if payload.prefix(checked).elementsEqual(Self.prefix.prefix(checked)), payload.count <= Self.maxPayload {
                        break
                    }
                    state = .skippingOSC
                }
            case .oscEscape:
                if byte == 0x5C {
                    finish(into: &marks)
                } else {
                    state = byte == 0x1B ? .escape : .ground
                }
            case .skippingOSC:
                if byte == 0x07 { state = .ground } else if byte == 0x1B { state = .escape }
            }
        }
        return marks
    }

    private mutating func finish(into marks: inout [ShellMark]) {
        state = .ground
        guard payload.starts(with: Self.prefix), let text = String(bytes: payload, encoding: .utf8) else { return }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false).dropFirst()
        switch fields.first {
        case "A": marks.append(.promptStarted)
        case "C": marks.append(.commandStarted)
        case "D": marks.append(.commandFinished(exitCode: fields.dropFirst().first.flatMap { Int32($0) }))
        default: break
        }
    }
}

extension Terminal {
    /// Running from a command's start to its end; a fresh prompt also means idle.
    public mutating func apply(_ mark: ShellMark) {
        switch mark {
        case .commandStarted:
            state = .running
        case .commandFinished(let exitCode):
            state = .idle
            lastExitCode = exitCode
        case .promptStarted:
            state = .idle
        }
    }
}
