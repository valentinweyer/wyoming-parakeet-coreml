// Single process-wide actor holding the one loaded German AsrManager.
// Loading the four CoreML models costs seconds and hundreds of MB, so this
// is loaded once at startup and shared across every connection — FluidAudio's
// AsrManager is itself an actor, so concurrent calls already serialize
// correctly, but owning it here keeps connections themselves trivially
// Sendable (they hold no model state, just their own buffer).

import CoreML
import FluidAudio
import Foundation

enum TranscriptionError: Error {
    case notReady
    case timedOut
}

actor TranscriptionService {
    private var manager: AsrManager?
    let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)

    func load(from directory: URL, encoderComputeUnits: MLComputeUnits?) async throws {
        let models = try await AsrModels.load(
            from: directory,
            version: .v3,
            encoderPrecision: .int8,
            encoderComputeUnits: encoderComputeUnits
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    /// Transcribes one full utterance. Decoder state is created fresh here
    /// and discarded at the end of the call — reusing state across
    /// utterances would leak context between unrelated voice commands.
    /// Samples shorter than FluidAudio's minimum are zero-padded (the model
    /// pads to a fixed 240k-sample window internally anyway, so this is
    /// semantically free) rather than rejected, since HA's VAD can hand us
    /// clips under 0.3s.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriptionError.notReady }
        guard !samples.isEmpty else { return "" }

        // `let`, not `var` — a mutable var can't be captured into the
        // escaping/concurrent closure below.
        let padded: [Float]
        if samples.count < minimumSamples {
            padded = samples + [Float](repeating: 0, count: minimumSamples - samples.count)
        } else {
            padded = samples
        }

        // Decoder state is created inside the timeout closure, not captured
        // by inout from outside — Swift doesn't allow capturing a local var
        // by inout into an escaping closure at all, timeout aside.
        let result = try await withTimeout(seconds: 30) {
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(padded, decoderState: &state)
        }
        return result.text
    }
}

/// Races the given async work against a timeout, throwing
/// `TranscriptionError.timedOut` if the timeout wins. Used so a single
/// pathological inference call can't hang a connection (and the pipeline on
/// the HA side) forever.
func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TranscriptionError.timedOut
        }
        guard let result = try await group.next() else { throw TranscriptionError.timedOut }
        group.cancelAll()
        return result
    }
}
