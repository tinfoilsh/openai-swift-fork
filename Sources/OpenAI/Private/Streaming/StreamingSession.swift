//
//  StreamingSession.swift
//
//
//  Created by Sergii Kryvoblotskyi on 18/04/2023.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StreamingSession<Interpreter: StreamInterpreter>: NSObject, Identifiable, URLSessionDataDelegateProtocol, @unchecked Sendable {
    typealias ResultType = Interpreter.ResultType
    
    private let urlSessionFactory: URLSessionFactory
    private let urlRequest: URLRequest
    private let interpreter: Interpreter
    private let sslDelegate: SSLDelegateProtocol?
    private let middlewares: [OpenAIMiddleware]
    private let executionSerializer: ExecutionSerializer
    private let onReceiveContent: (@Sendable (StreamingSession, ResultType) -> Void)?
    private let onProcessingError: (@Sendable (StreamingSession, Error) -> Void)?
    private let onComplete: (@Sendable (StreamingSession, Error?) -> Void)?
    private var errorResponse: HTTPURLResponse?
    private var errorResponseData = Data()
    private let speechResponseValidator: AudioSpeechResponseValidator?
    private var speechResponseReceived = false
    private var speechReceivedAudio = false
    private var speechCompleted = false
    private let speechCancellationLock = NSLock()
    private var speechCancellationRequested = false

    init(
        urlSessionFactory: URLSessionFactory = FoundationURLSessionFactory(),
        urlRequest: URLRequest,
        interpreter: Interpreter,
        sslDelegate: SSLDelegateProtocol?,
        middlewares: [OpenAIMiddleware],
        executionSerializer: ExecutionSerializer = GCDQueueAsyncExecutionSerializer(queue: .userInitiated),
        speechResponseValidator: AudioSpeechResponseValidator? = nil,
        onReceiveContent: @escaping @Sendable (StreamingSession, ResultType) -> Void,
        onProcessingError: @escaping @Sendable (StreamingSession, Error) -> Void,
        onComplete: @escaping @Sendable (StreamingSession, Error?) -> Void
    ) {
        self.urlSessionFactory = urlSessionFactory
        self.urlRequest = urlRequest
        self.interpreter = interpreter
        self.sslDelegate = sslDelegate
        self.middlewares = middlewares
        self.executionSerializer = executionSerializer
        self.speechResponseValidator = speechResponseValidator
        self.onReceiveContent = onReceiveContent
        self.onProcessingError = onProcessingError
        self.onComplete = onComplete
        super.init()
        subscribeToParser()
    }
    
    func makeSession() -> PerformableSession & InvalidatableSession {
        let urlSession = urlSessionFactory.makeUrlSession(delegate: self)
        return DataTaskPerformingURLSession(urlRequest: urlRequest, urlSession: urlSession)
    }
    
    func urlSession(_ session: any URLSessionProtocol, task: any URLSessionTaskProtocol, didCompleteWithError error: (any Error)?) {
        executionSerializer.dispatch {
            if self.speechResponseValidator != nil {
                guard self.canProcessSpeech() else { return }
                if let error {
                    self.finishSpeech(error: error)
                } else if let response = self.errorResponse {
                    let responseError = JSONResponseErrorDecoder(decoder: JSONDecoder())
                        .decodeErrorResponse(data: self.errorResponseData)
                    self.finishSpeech(error: responseError ?? OpenAIError.statusError(response: response, statusCode: response.statusCode))
                } else if !self.speechResponseReceived {
                    self.finishSpeech(error: AudioSpeechStreamError.invalidResponse)
                } else {
                    self.finishSpeech(error: self.speechReceivedAudio ? nil : OpenAIError.emptyData)
                }
                return
            }
            if error == nil, let errorResponse = self.errorResponse {
                let responseError: any Error
                if let decodedError = JSONResponseErrorDecoder(decoder: JSONDecoder())
                    .decodeErrorResponse(data: self.errorResponseData) {
                    responseError = decodedError
                } else {
                    responseError = OpenAIError.statusError(
                        response: errorResponse,
                        statusCode: errorResponse.statusCode
                    )
                }
                self.onProcessingError?(self, responseError)
            }
            self.onComplete?(self, error)
        }
    }
    
    func urlSession(_ session: any URLSessionProtocol, dataTask: any URLSessionDataTaskProtocol, didReceive data: Data) {
        executionSerializer.dispatch {
            if self.speechResponseValidator != nil {
                guard self.canProcessSpeech() else { return }
                guard self.speechResponseReceived else {
                    self.finishSpeech(error: AudioSpeechStreamError.invalidResponse)
                    dataTask.cancel()
                    return
                }
            }
            let data = self.middlewares.reduce(data) { current, middleware in
                middleware.interceptStreamingData(request: dataTask.originalRequest, current)
            }

            if self.errorResponse != nil {
                if self.speechResponseValidator != nil {
                    let remaining = AudioSpeechResponseValidator.maximumErrorBodyBytes - self.errorResponseData.count
                    self.errorResponseData.append(data.prefix(remaining))
                    if data.count > remaining, let response = self.errorResponse {
                        self.finishSpeech(error: OpenAIError.statusError(response: response, statusCode: response.statusCode))
                        dataTask.cancel()
                    }
                } else {
                    self.errorResponseData.append(data)
                }
            } else {
                if !data.isEmpty { self.speechReceivedAudio = true }
                self.interpreter.processData(data)
            }
        }
    }

    func urlSession(
        _ session: URLSessionProtocol,
        dataTask: URLSessionDataTaskProtocol,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        executionSerializer.dispatch {
            if let validator = self.speechResponseValidator {
                guard self.canProcessSpeech() else {
                    completionHandler(.cancel)
                    return
                }
                self.speechResponseReceived = true
                if let response = response as? HTTPURLResponse,
                   response.statusCode >= AudioSpeechResponseValidator.minimumErrorStatusCode {
                    self.errorResponse = response
                    completionHandler(.allow)
                    return
                }
                do {
                    try validator.validate(response)
                } catch {
                    self.finishSpeech(error: error)
                    completionHandler(.cancel)
                    return
                }
            }
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                self.errorResponse = httpResponse
            }
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let sslDelegate else { return completionHandler(.performDefaultHandling, nil) }
        sslDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func cancelSpeech() {
        speechCancellationLock.lock()
        speechCancellationRequested = true
        speechCancellationLock.unlock()
        executionSerializer.dispatch {
            self.finishSpeech(error: URLError(.cancelled))
        }
    }

    private func canProcessSpeech() -> Bool {
        guard !speechCompleted else { return false }
        speechCancellationLock.lock()
        let canceled = speechCancellationRequested
        speechCancellationLock.unlock()
        if canceled {
            finishSpeech(error: URLError(.cancelled))
        }
        return !canceled
    }

    private func finishSpeech(error: Error?) {
        guard !speechCompleted else { return }
        speechCompleted = true
        errorResponseData.removeAll()
        if let error { onProcessingError?(self, error) }
        onComplete?(self, error)
    }

    private func subscribeToParser() {
        interpreter.setCallbackClosures { [weak self] content in
            guard let self else { return }
            if self.speechResponseValidator != nil, !self.canProcessSpeech() { return }
            self.onReceiveContent?(self, content)
        } onError: { [weak self] error in
            guard let self else { return }
            self.onProcessingError?(self, error)
        }
    }
}
