//
//  AudioSpeechStreamInterpreter.swift
//  OpenAI
//
//  Created by Oleksii Nezhyborets on 07.03.2025.
//

import Foundation

final class AudioSpeechStreamInterpreter: @unchecked Sendable, StreamInterpreter {
    typealias ResultType = AudioSpeechResult
    
    private var onEventDispatched: ((AudioSpeechResult) -> Void)?
    
    func setCallbackClosures(onEventDispatched: @escaping (AudioSpeechResult) -> Void, onError: @escaping (any Error) -> Void) {
        self.onEventDispatched = onEventDispatched
    }
    
    func processData(_ data: Data) {
        // The session validates the response and serializes delivery, including completion.
        // Audio bytes must not be interpreted as JSON, even if a chunk happens to parse.
        guard !data.isEmpty else { return }
        onEventDispatched?(AudioSpeechResult(audio: data))
    }
}
