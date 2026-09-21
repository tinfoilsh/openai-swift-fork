import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AudioSpeechResponseValidator: Sendable {
    static let maximumErrorBodyBytes = 64 * 1024
    static let successStatusCodes = 200..<300
    static let minimumErrorStatusCode = 400
    private static let binaryContentType = "application/octet-stream"
    private static let audioContentTypePrefix = "audio/"

    let options: AudioSpeechStreamOptions

    func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw AudioSpeechStreamError.invalidResponse
        }
        guard Self.successStatusCodes.contains(response.statusCode) else {
            throw OpenAIError.statusError(response: response, statusCode: response.statusCode)
        }
        let rawContentType = response.value(forHTTPHeaderField: "Content-Type")
        guard let rawContentType else {
            throw AudioSpeechStreamError.unexpectedContentType(nil)
        }
        let contentType = Self.normalizedContentType(rawContentType)
        let isAudio = contentType.hasPrefix(Self.audioContentTypePrefix)
            && contentType.count > Self.audioContentTypePrefix.count
        guard isAudio || contentType == Self.binaryContentType else {
            throw AudioSpeechStreamError.unexpectedContentType(rawContentType)
        }
        if let expected = options.expectedContentType,
           contentType != Self.normalizedContentType(expected) {
            throw AudioSpeechStreamError.unexpectedContentType(rawContentType)
        }
    }

    private static func normalizedContentType(_ value: String) -> String {
        value.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
