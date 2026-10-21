import Testing
@testable import WyomingParakeet

@Test func batchRecognitionRequiresExternalEndOfSpeechDetection() throws {
    // A satellite keeps streaming until HA or the recognizer detects silence.
    // This batch recognizer waits for audio-stop, so HA must end that stream.
    let programs = try #require(buildInfoData(ModelInfo())["asr"] as? [[String: Any]])
    let program = try #require(programs.first)
    #expect(program["requires_external_vad"] as? Bool == true)
    #expect(program["supports_transcript_streaming"] as? Bool == false)
}
