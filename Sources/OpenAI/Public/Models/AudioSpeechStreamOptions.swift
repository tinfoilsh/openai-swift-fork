import Foundation

/// Response validation for binary speech streaming; these options are not sent to the provider.
public struct AudioSpeechStreamOptions: Sendable {
    /// An optional MIME type to require, such as `audio/pcm` for a raw PCM player.
    /// Matching ignores case and MIME parameters. Without this option, audio MIME
    /// types and `application/octet-stream` are accepted, but JSON, HTML, and SSE are not.
    public let expectedContentType: String?

    public init(expectedContentType: String? = nil) {
        self.expectedContentType = expectedContentType
    }
}

public enum AudioSpeechStreamError: Error, Equatable, Sendable, LocalizedError {
    case invalidResponse
    case unexpectedContentType(String?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The speech service returned an invalid response."
        case .unexpectedContentType:
            return "The speech response did not contain the expected audio format."
        }
    }
}
