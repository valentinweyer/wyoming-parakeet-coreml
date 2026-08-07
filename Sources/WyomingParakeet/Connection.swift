// Per-connection Wyoming state machine.
//
//   idle ──describe──▶ send info ──▶ idle
//   idle ──transcribe(name?, language?)──▶ armed
//   armed ──audio-start(rate,width,channels)──▶ recording
//   recording ──audio-chunk × N──▶ accumulate raw bytes
//   recording ──audio-stop──▶ transcribe → send transcript ──▶ idle
//
// Permissive on purpose: HA sometimes sends audio-start without a preceding
// transcribe, so audio-start alone is enough to (re-)arm recording. The
// connection stays open after a transcript — HA reuses it for the next
// utterance.

import Foundation
import Network

private enum ConnState {
    case idle
    case recording(format: AudioFormat)
}

actor Connection {
    private let id: Int
    private let nwConnection: NWConnection
    private let transcriptionService: TranscriptionService
    private let registry: ConnectionRegistry
    private let model: ModelInfo

    private let parser = WyomingParser()
    private var state: ConnState = .idle
    private var audioBytes = Data()

    init(
        id: Int, nwConnection: NWConnection, transcriptionService: TranscriptionService,
        registry: ConnectionRegistry, model: ModelInfo
    ) {
        self.id = id
        self.nwConnection = nwConnection
        self.transcriptionService = transcriptionService
        self.registry = registry
        self.model = model
    }

    func start() {
        nwConnection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task { await self.handleStateUpdate(newState) }
        }
        nwConnection.start(queue: networkQueue)
        receiveLoop()
    }

    private func handleStateUpdate(_ newState: NWConnection.State) {
        switch newState {
        case .failed(let error):
            log("conn \(id) failed: \(error)")
            close()
        default:
            break
        }
    }

    // Only used for logging from non-isolated closure contexts (Network.framework
    // completion handlers execute off the actor).
    nonisolated var idSync: Int { id }

    private func receiveLoop() {
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty {
                    await self.handleReceived(data)
                }
                if let error {
                    log("conn \(self.idSync) receive error: \(error)")
                    await self.close()
                    return
                }
                if isComplete {
                    await self.close()
                    return
                }
                await self.receiveLoop()
            }
        }
    }

    private func handleReceived(_ data: Data) {
        let events: [WyomingEvent]
        do {
            events = try parser.feed(data)
        } catch {
            log("conn \(id) framing error: \(error) — closing")
            close()
            return
        }
        for event in events {
            Task { await self.handle(event) }
        }
    }

    private func handle(_ event: WyomingEvent) async {
        switch event.type {
        case WyomingEventType.describe:
            await sendInfo()

        case WyomingEventType.transcribe:
            // No format known yet until audio-start; just acknowledges the
            // client's intent to start a new utterance. name/language in
            // event.data are accepted but not required — the model is
            // German-only by design, so there is nothing to switch on.
            state = .idle
            audioBytes = Data()

        case WyomingEventType.audioStart:
            let format = AudioFormat(from: event.data) ?? .expected
            if format != .expected {
                log(
                    "conn \(id) audio-start with unexpected format rate=\(format.rate) "
                        + "width=\(format.width) channels=\(format.channels), expected 16kHz/16-bit/mono — "
                        + "proceeding anyway, decode will likely be garbage")
            }
            state = .recording(format: format)
            audioBytes = Data()

        case WyomingEventType.audioChunk:
            guard case .recording = state else {
                // Be permissive: treat a chunk arriving without a prior
                // audio-start as an implicit start at the expected format.
                state = .recording(format: .expected)
                audioBytes = Data()
                if let payload = event.payload { audioBytes.append(payload) }
                return
            }
            if let payload = event.payload {
                audioBytes.append(payload)
            }

        case WyomingEventType.audioStop:
            guard case .recording(let format) = state else {
                await sendTranscript(text: "")
                return
            }
            let samples = pcm16LEToFloat(audioBytes, channels: format.channels)
            state = .idle
            audioBytes = Data()

            do {
                let text = try await transcriptionService.transcribe(samples)
                await sendTranscript(text: text)
            } catch {
                log("conn \(id) transcription error: \(error)")
                await sendError(text: "transcription failed: \(error)")
            }

        default:
            // Unrecognized event types (e.g. ping) are silently ignored —
            // not every Wyoming client sends only the events we care about.
            break
        }
    }

    private func sendInfo() async {
        await send(type: WyomingEventType.info, data: buildInfoData(model))
    }

    private func sendTranscript(text: String) async {
        await send(type: WyomingEventType.transcript, data: ["text": text, "language": model.language])
    }

    private func sendError(text: String) async {
        await send(type: WyomingEventType.error, data: ["text": text, "code": "transcription-error"])
    }

    private func send(type: String, data: [String: Any]) async {
        guard let bytes = try? encodeWyomingEvent(type: type, data: data) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            nwConnection.send(
                content: bytes,
                completion: .contentProcessed { error in
                    if let error {
                        log("conn \(self.idSync) send error: \(error)")
                    }
                    continuation.resume()
                })
        }
    }

    private func close() {
        nwConnection.cancel()
        Task { await registry.remove(id: id) }
    }
}

/// Int16LE PCM -> mono Float32 in [-1, 1]. Multi-channel input is
/// downmixed by averaging, though HA is only ever expected to send mono.
private func pcm16LEToFloat(_ data: Data, channels: Int) -> [Float] {
    let bytesPerFrame = 2 * max(channels, 1)
    let frameCount = data.count / bytesPerFrame
    guard frameCount > 0 else { return [] }

    var out = [Float](repeating: 0, count: frameCount)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for frame in 0..<frameCount {
            var sum: Int32 = 0
            for ch in 0..<channels {
                let offset = frame * bytesPerFrame + ch * 2
                let sample = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                sum += Int32(sample)
            }
            out[frame] = Float(sum) / Float(channels) / 32768.0
        }
    }
    return out
}
