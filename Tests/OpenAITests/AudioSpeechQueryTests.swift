import XCTest
@testable import OpenAI

final class AudioSpeechQueryTests: XCTestCase {
    func testProviderRequestEncodingAndRoundTrip() throws {
        let query = AudioSpeechQuery(
            model: "qwen3-tts",
            input: "Read this aloud.",
            voice: .custom("aiden"),
            instructions: "Speak clearly.",
            responseFormat: .pcm,
            streamFormat: .audio
        )
        let data = try JSONEncoder().encode(query)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "qwen3-tts")
        XCTAssertEqual(json["voice"] as? String, "aiden")
        XCTAssertEqual(json["input"] as? String, query.input)
        XCTAssertEqual(json["instructions"] as? String, query.instructions)
        XCTAssertEqual(json["response_format"] as? String, "pcm")
        XCTAssertEqual(json["stream_format"] as? String, "audio")
        XCTAssertEqual(json["speed"] as? Double, 1)
        XCTAssertEqual(json.count, 7)

        let decoded = try JSONDecoder().decode(AudioSpeechQuery.self, from: data)
        XCTAssertEqual(decoded.model, query.model)
        XCTAssertEqual(decoded.voice, query.voice)
        XCTAssertEqual(decoded.streamFormat, .audio)
        XCTAssertEqual(decoded.responseFormat, .pcm)
    }

    func testLegacyInitializerAndPayloadRemainAvailable() throws {
        let initializer: (Model, String, AudioSpeechQuery.AudioSpeechVoice, String, AudioSpeechQuery.AudioSpeechResponseFormat, Double) -> AudioSpeechQuery = AudioSpeechQuery.init
        let query = initializer(.tts_1, "Hello", .alloy, "", .mp3, 1)
        let data = try JSONEncoder().encode(query)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["stream_format"])
        XCTAssertEqual(json["voice"] as? String, "alloy")
        XCTAssertEqual(json["response_format"] as? String, "mp3")
        let decoded = try JSONDecoder().decode(AudioSpeechQuery.self, from: data)
        XCTAssertNil(decoded.streamFormat)
        XCTAssertEqual(decoded.voice, .alloy)
    }

    func testCustomModelIsPreservedByLegacyInitializer() {
        let query = AudioSpeechQuery(model: "provider/speech-v2", input: "Hello", voice: .alloy)
        XCTAssertEqual(query.model, "provider/speech-v2")
    }

    func testBuiltInAndCustomVoicesEncodeAsStrings() throws {
        let voices = AudioSpeechQuery.AudioSpeechVoice.allCases + [.custom("aiden"), .custom("provider/voice")]
        for voice in voices {
            let data = try JSONEncoder().encode(voice)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: data), voice.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(AudioSpeechQuery.AudioSpeechVoice.self, from: data), voice)
            XCTAssertEqual(AudioSpeechQuery.AudioSpeechVoice(rawValue: voice.rawValue), voice)
        }
        XCTAssertEqual(AudioSpeechQuery.AudioSpeechVoice.allCases.map(\.rawValue), [
            "alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer", "verse"
        ])
    }

    func testSSECannotBeSelectedForBinarySpeech() {
        XCTAssertThrowsError(try JSONDecoder().decode(AudioSpeechQuery.AudioSpeechStreamFormat.self, from: Data("\"sse\"".utf8)))
    }
}
