//
//  AudioSpeechQuery.swift
//  
//
//  Created by Ihor Makhnyk on 13.11.2023.
//

import Foundation

/// Generates audio from the input text.
/// Learn more: [OpenAI Speech – Documentation](https://platform.openai.com/docs/api-reference/audio/createSpeech)
public struct AudioSpeechQuery: Codable, Sendable {
    
    /// Encapsulates the voices available for audio generation.
    ///
    /// To get aquinted with each of the voices and listen to the samples visit:
    /// [OpenAI Text-to-Speech – Voice Options](https://platform.openai.com/docs/guides/text-to-speech/voice-options)
    /// Hear and play with these voices in https://openai.fm/
    public enum AudioSpeechVoice: RawRepresentable, Codable, CaseIterable, Sendable, Hashable {
        case alloy
        case ash
        case ballad
        case coral
        case echo
        case fable
        case onyx
        case nova
        case sage
        case shimmer
        case verse
        case custom(String)

        public static let allCases: [Self] = [
            .alloy, .ash, .ballad, .coral, .echo, .fable, .onyx, .nova, .sage, .shimmer, .verse
        ]

        public var rawValue: String {
            switch self {
            case .alloy: return "alloy"
            case .ash: return "ash"
            case .ballad: return "ballad"
            case .coral: return "coral"
            case .echo: return "echo"
            case .fable: return "fable"
            case .onyx: return "onyx"
            case .nova: return "nova"
            case .sage: return "sage"
            case .shimmer: return "shimmer"
            case .verse: return "verse"
            case .custom(let name): return name
            }
        }

        public init?(rawValue: String) {
            self = Self.allCases.first { $0.rawValue == rawValue } ?? .custom(rawValue)
        }

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self.allCases.first { $0.rawValue == value } ?? .custom(value)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Binary speech transport. SSE speech events require a separate event decoder.
    public enum AudioSpeechStreamFormat: String, Codable, Sendable {
        case audio
    }
    
    /// Encapsulates the response formats available for audio data.
    ///
    /// **Formats:**
    /// -  mp3
    /// -  opus
    /// -  aac
    /// -  flac
    /// -  wav
    /// -  pcm
    public enum AudioSpeechResponseFormat: String, Codable, CaseIterable, Sendable {
        case mp3
        case opus
        case aac
        case flac
        case wav
        case pcm
    }
    /// The text to generate audio for. The maximum length is 4096 characters.
    public let input: String
    /// Speech model identifier, forwarded unchanged to the configured provider.
    public let model: Model
    /// A built-in voice or a provider-specific voice selected with `.custom(_:)`.
    /// https://platform.openai.com/docs/guides/text-to-speech/voice-options
    public let voice: AudioSpeechVoice
    /// The audio response format: mp3, opus, aac, flac, wav, or pcm, subject to provider support.
    /// Defaults to mp3
    public let responseFormat: AudioSpeechResponseFormat?
    /// The speed of the generated audio. Select a value from **0.25** to **4.0**. **1.0** is the default.
    /// Defaults to 1
    public let speed: Double?
    ///  Control the voice of your generated audio with additional instructions. Does not work with tts-1 or tts-1-hd.
    public let instructions: String?

    /// Omitted by default so the provider chooses its default transport.
    public let streamFormat: AudioSpeechStreamFormat?

    public enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case responseFormat = "response_format"
        case speed
        case instructions
        case streamFormat = "stream_format"
    }

    public init(model: Model, input: String, voice: AudioSpeechVoice, instructions: String = "", responseFormat: AudioSpeechResponseFormat = .mp3, speed: Double = 1.0) {
        self.init(model: model, input: input, voice: voice, instructions: instructions, responseFormat: responseFormat, speed: speed, streamFormat: nil)
    }

    /// Model and voice identifiers are forwarded to the provider without a model allowlist.
    public init(model: Model, input: String, voice: AudioSpeechVoice, instructions: String = "", responseFormat: AudioSpeechResponseFormat = .mp3, speed: Double = 1.0, streamFormat: AudioSpeechStreamFormat?) {
        self.model = model
        self.speed = AudioSpeechQuery.normalizeSpeechSpeed(speed)
        self.input = input
        self.voice = voice
        self.responseFormat = responseFormat
        self.instructions = instructions
        self.streamFormat = streamFormat
    }
}

public extension AudioSpeechQuery {

    enum Speed: Double {
        case normal = 1.0
        case max = 4.0
        case min = 0.25
    }

    static func normalizeSpeechSpeed(_ inputSpeed: Double?) -> Double {
        guard let inputSpeed = inputSpeed else { return Self.Speed.normal.rawValue }
        let isSpeedOutOfBounds = inputSpeed <= Self.Speed.min.rawValue || Self.Speed.max.rawValue <= inputSpeed
        guard !isSpeedOutOfBounds else {
            print("[AudioSpeech] Speed value must be between 0.25 and 4.0. Setting value to closest valid.")
            return inputSpeed < Self.Speed.min.rawValue ? Self.Speed.min.rawValue : Self.Speed.max.rawValue
        }
        return inputSpeed
    }
}
