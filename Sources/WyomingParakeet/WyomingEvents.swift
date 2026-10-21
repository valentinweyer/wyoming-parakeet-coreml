// Typed views over the generic WyomingEvent for the handful of event types
// this server needs to understand, plus builders for the events it sends.

import Foundation

enum WyomingEventType {
    static let describe = "describe"
    static let info = "info"
    static let transcribe = "transcribe"
    static let audioStart = "audio-start"
    static let audioChunk = "audio-chunk"
    static let audioStop = "audio-stop"
    static let transcript = "transcript"
    static let error = "error"
}

struct AudioFormat: Equatable {
    let rate: Int
    let width: Int
    let channels: Int

    static let expected = AudioFormat(rate: 16000, width: 2, channels: 1)

    init(rate: Int, width: Int, channels: Int) {
        self.rate = rate
        self.width = width
        self.channels = channels
    }

    init?(from data: [String: Any]?) {
        guard let data,
            let rate = data["rate"] as? Int,
            let width = data["width"] as? Int,
            let channels = data["channels"] as? Int
        else { return nil }
        self.init(rate: rate, width: width, channels: channels)
    }
}

/// Builds the `info` response's `data` dict. HA's Wyoming integration
/// iterates all seven top-level keys, so every one (even the ones this
/// server doesn't implement) must be present as an empty array.
func buildInfoData(_ model: ModelInfo) -> [String: Any] {
    let attribution: [String: Any] = [
        "name": model.attributionName,
        "url": model.attributionURL,
    ]
    let modelEntry: [String: Any] = [
        "name": model.name,
        "attribution": attribution,
        "installed": true,
        "description": model.modelDescription,
        "version": model.version,
        "languages": [model.language],
    ]
    let program: [String: Any] = [
        "name": model.name,
        "attribution": attribution,
        "installed": true,
        "description": model.programDescription,
        "version": model.version,
        "models": [modelEntry],
        "supports_transcript_streaming": false,
        // Transcription starts only after audio-stop. HA must detect silence
        // and finish satellite audio instead of waiting for server-side VAD.
        "requires_external_vad": true,
        "prefers_auto_gain_enabled": false,
        "prefers_noise_reduction_enabled": false,
    ]
    return [
        "asr": [program],
        "tts": [],
        "handle": [],
        "intent": [],
        "wake": [],
        "mic": [],
        "snd": [],
    ]
}
