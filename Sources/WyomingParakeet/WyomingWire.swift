// Wyoming protocol wire framing: one UTF-8 JSON header line (terminated by
// \n), optionally followed by exactly `data_length` bytes of additional
// UTF-8 JSON, optionally followed by exactly `payload_length` raw bytes.
//
// Only the first `\n` is ever a delimiter — the data/payload blocks are
// length-prefixed, not delimiter-scanned, so transcript text containing
// newlines or arbitrary bytes in an audio payload can never desynchronize
// the parser.

import Foundation

struct WyomingEvent {
    let type: String
    let data: [String: Any]?
    let payload: Data?
}

enum WyomingWireError: Error {
    case invalidHeaderJSON
    case missingType
    case frameTooLarge(String)
}

/// Caps for data_length/payload_length. A single Wyoming audio-chunk from HA
/// is typically a few KB; a full utterance accumulated client-side (our
/// design) never touches this. Guards against a malformed/hostile peer
/// claiming an enormous length and stalling the connection forever.
private let maxDataLength = 4 * 1024 * 1024
private let maxPayloadLength = 8 * 1024 * 1024

/// Incremental parser for a single connection's inbound byte stream.
/// Not thread-safe by itself — callers must serialize access (the
/// `Connection` actor in this project does this by construction).
final class WyomingParser {
    private enum State {
        case awaitingHeader
        case awaitingData(header: ParsedHeader, remaining: Int)
        case awaitingPayload(header: ParsedHeader, data: [String: Any]?, remaining: Int)
    }

    private struct ParsedHeader {
        let type: String
        let dataLength: Int
        let payloadLength: Int
        let inlineData: [String: Any]?
    }

    private var buffer = Data()
    private var state: State = .awaitingHeader
    // Accumulated across awaitingData/awaitingPayload transitions since a
    // single incoming TCP read can split a length-prefixed block arbitrarily.
    private var accumulated = Data()

    /// Feed newly-received bytes; returns every fully-parsed event now
    /// available (a single `feed` call can yield zero, one, or many events).
    func feed(_ newBytes: Data) throws -> [WyomingEvent] {
        buffer.append(newBytes)
        var events: [WyomingEvent] = []

        while true {
            switch state {
            case .awaitingHeader:
                guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { return events }
                let headerBytes = buffer[buffer.startIndex..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)

                guard
                    let obj = try? JSONSerialization.jsonObject(with: Data(headerBytes)) as? [String: Any],
                    let type = obj["type"] as? String
                else {
                    throw WyomingWireError.invalidHeaderJSON
                }
                let dataLength = (obj["data_length"] as? Int) ?? 0
                let payloadLength = (obj["payload_length"] as? Int) ?? 0
                guard dataLength <= maxDataLength else {
                    throw WyomingWireError.frameTooLarge("data_length=\(dataLength)")
                }
                guard payloadLength <= maxPayloadLength else {
                    throw WyomingWireError.frameTooLarge("payload_length=\(payloadLength)")
                }
                let header = ParsedHeader(
                    type: type, dataLength: dataLength, payloadLength: payloadLength,
                    inlineData: obj["data"] as? [String: Any])

                if dataLength > 0 {
                    accumulated = Data()
                    state = .awaitingData(header: header, remaining: dataLength)
                } else if payloadLength > 0 {
                    accumulated = Data()
                    state = .awaitingPayload(header: header, data: header.inlineData, remaining: payloadLength)
                } else {
                    events.append(WyomingEvent(type: header.type, data: header.inlineData, payload: nil))
                    state = .awaitingHeader
                }

            case .awaitingData(let header, let remaining):
                guard buffer.count >= remaining else { return events }
                let chunk = buffer.prefix(remaining)
                buffer.removeFirst(remaining)
                accumulated.append(chunk)
                let parsedData = (try? JSONSerialization.jsonObject(with: accumulated)) as? [String: Any]

                if header.payloadLength > 0 {
                    accumulated = Data()
                    state = .awaitingPayload(header: header, data: parsedData, remaining: header.payloadLength)
                } else {
                    events.append(WyomingEvent(type: header.type, data: parsedData, payload: nil))
                    state = .awaitingHeader
                }

            case .awaitingPayload(let header, let data, let remaining):
                guard buffer.count >= remaining else { return events }
                let chunk = buffer.prefix(remaining)
                buffer.removeFirst(remaining)
                accumulated.append(chunk)
                events.append(WyomingEvent(type: header.type, data: data, payload: accumulated))
                accumulated = Data()
                state = .awaitingHeader
            }
        }
    }
}

/// Encodes a single Wyoming event as header+data+payload, ready to write to
/// the socket in one call. `data` is always sent as a separate length-
/// prefixed block (never inlined in the header), so the header line itself
/// never has to worry about escaping newlines out of arbitrary content.
func encodeWyomingEvent(type: String, data: [String: Any]? = nil, payload: Data? = nil) throws -> Data {
    var header: [String: Any] = ["type": type]
    var dataBytes: Data?
    if let data {
        dataBytes = try JSONSerialization.data(withJSONObject: data, options: [.withoutEscapingSlashes])
        header["data_length"] = dataBytes!.count
    }
    if let payload {
        header["payload_length"] = payload.count
    }

    var out = try JSONSerialization.data(withJSONObject: header, options: [.withoutEscapingSlashes])
    out.append(0x0A)
    if let dataBytes {
        out.append(dataBytes)
    }
    if let payload {
        out.append(payload)
    }
    return out
}
