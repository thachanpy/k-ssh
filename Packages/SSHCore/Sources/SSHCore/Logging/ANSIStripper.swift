import Foundation

/// Removes terminal control sequences (CSI, OSC, other ESC sequences) and control characters from a
/// byte stream, keeping printable text, UTF-8 bytes, tabs and newlines.
///
/// Stateful: an escape sequence split across two `feed` calls is still removed. `\r\n` becomes `\n`,
/// a lone `\r` is dropped.
public struct ANSIStripper: Sendable {
    private enum State {
        case normal
        case escape
        case escapeIntermediate
        case csi
        /// OSC / DCS / SOS / PM / APC: runs until BEL or ESC `\`.
        case string
        case stringEscape
    }

    private var state = State.normal

    public init() {}

    /// Processes the next chunk and returns the text bytes to keep.
    public mutating func feed(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            switch state {
            case .normal:
                switch byte {
                case 0x1B: state = .escape
                case 0x0A, 0x09: out.append(byte)
                case 0x00..<0x20, 0x7F: break
                default: out.append(byte)
                }
            case .escape:
                switch byte {
                case UInt8(ascii: "["): state = .csi
                case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"),
                    UInt8(ascii: "_"):
                    state = .string
                case 0x20...0x2F: state = .escapeIntermediate
                default: state = .normal  // two-byte sequence, e.g. ESC 7, ESC =
                }
            case .escapeIntermediate:
                if (0x30...0x7E).contains(byte) { state = .normal }
            case .csi:
                if (0x40...0x7E).contains(byte) { state = .normal }
            case .string:
                if byte == 0x07 {
                    state = .normal
                } else if byte == 0x1B {
                    state = .stringEscape
                }
            case .stringEscape:
                state = byte == UInt8(ascii: "\\") ? .normal : .string
            }
        }
        return out
    }
}
