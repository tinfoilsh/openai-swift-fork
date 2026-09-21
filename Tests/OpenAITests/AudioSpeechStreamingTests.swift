import XCTest
@testable import OpenAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AudioSpeechStreamingTests: XCTestCase {
    private static let errorBody = Data("""
        {"error":{"message":"Try again later","type":"rate_limit_error","code":"provider_limit"}}
        """.utf8)

    func testPCMChunksAreDeliveredImmediatelyUnchangedAndBeforeCompletion() throws {
        let harness = SpeechHarness()
        _ = harness.start(options: .init(expectedContentType: "audio/pcm"))
        try harness.respond(contentType: "Audio/PCM; rate=24000")
        let chunks = [Data([0x00]), Data([0x80, 0xff, 0x7f]), Self.errorBody]
        for chunk in chunks { harness.send(chunk) }
        XCTAssertEqual(harness.recorder.audio, chunks)
        XCTAssertEqual(harness.recorder.completions.count, 0)
        harness.complete()
        harness.send(Data([0xff]))
        harness.complete()
        XCTAssertEqual(harness.recorder.audio, chunks)
        XCTAssertEqual(harness.recorder.events, ["audio", "audio", "audio", "complete"])
        XCTAssertTrue(harness.recorder.errors.isEmpty)
        XCTAssertEqual(harness.recorder.completions.count, 1)
        XCTAssertNil(harness.recorder.completions[0])
    }

    func testDefaultValidationAcceptsBinaryAndAudioMIMETypes() throws {
        for contentType in ["audio/mpeg", "audio/wav", "audio/opus", "application/octet-stream"] {
            let harness = SpeechHarness()
            _ = harness.start()
            try harness.respond(contentType: contentType)
            harness.send(Data([0x01, 0x02]))
            harness.complete()
            XCTAssertEqual(harness.recorder.audio, [Data([0x01, 0x02])])
            XCTAssertTrue(harness.recorder.errors.isEmpty)
        }
    }

    func testInvalidContentTypesNeverBecomeAudio() throws {
        let contentTypes: [String?] = [nil, "", "audio/", "application/json", "text/html", "text/event-stream"]
        for contentType in contentTypes {
            let harness = SpeechHarness()
            _ = harness.start()
            try harness.respond(contentType: contentType)
            harness.send(Self.errorBody)
            harness.complete(error: URLError(.cancelled))
            XCTAssertEqual(harness.recorder.disposition, .cancel)
            XCTAssertTrue(harness.recorder.audio.isEmpty)
            XCTAssertEqual(harness.recorder.errors.count, 1)
            XCTAssertEqual(harness.recorder.errors.first as? AudioSpeechStreamError, .unexpectedContentType(contentType))
            XCTAssertEqual(harness.recorder.completions.count, 1)
        }
    }

    func testStrictPCMValidationRejectsOtherAudioAndGenericBinary() throws {
        for contentType in ["audio/wav", "audio/mpeg", "application/octet-stream"] {
            let harness = SpeechHarness()
            _ = harness.start(options: .init(expectedContentType: "audio/pcm"))
            try harness.respond(contentType: contentType)
            harness.send(Data([0x01]))
            XCTAssertTrue(harness.recorder.audio.isEmpty)
            XCTAssertEqual(harness.recorder.errors.first as? AudioSpeechStreamError, .unexpectedContentType(contentType))
        }
    }

    func testFragmentedHTTPErrorIsDecodedWithoutEmittingAudio() throws {
        for status in [401, 429, 503] {
            let harness = SpeechHarness()
            _ = harness.start()
            try harness.respond(status: status, contentType: "application/json")
            let split = Self.errorBody.count / 2
            harness.send(Self.errorBody.prefix(split))
            XCTAssertTrue(harness.recorder.errors.isEmpty)
            harness.send(Self.errorBody.dropFirst(split))
            harness.complete()
            let error = try XCTUnwrap(harness.recorder.errors.first as? APIErrorResponse)
            XCTAssertEqual(error.error.code, "provider_limit")
            XCTAssertEqual(error.error.message, "Try again later")
            XCTAssertTrue(harness.recorder.audio.isEmpty)
            XCTAssertEqual(harness.recorder.completions.count, 1)
            XCTAssertEqual(harness.recorder.completions[0] as? APIErrorResponse, error)
        }
    }

    func testLargeErrorBodyIsBoundedAndCancelsTransport() throws {
        let harness = SpeechHarness()
        _ = harness.start()
        try harness.respond(status: 502, contentType: "text/html")
        harness.send(Data(repeating: 0x20, count: AudioSpeechResponseValidator.maximumErrorBodyBytes))
        XCTAssertTrue(harness.recorder.errors.isEmpty)
        harness.send(Data([0x20]))
        harness.send(Data([0x01]))
        harness.complete()
        guard case .statusError(_, let status) = harness.recorder.errors.first as? OpenAIError else {
            return XCTFail("Expected the HTTP status when the error body is too large")
        }
        XCTAssertEqual(status, 502)
        XCTAssertEqual(harness.transport.dataTask.cancelCallCount, 1)
        XCTAssertTrue(harness.recorder.audio.isEmpty)
        XCTAssertEqual(harness.recorder.completions.count, 1)
    }

    func testRedirectAndNonHTTPResponsesAreRejected() throws {
        let redirect = SpeechHarness()
        _ = redirect.start()
        try redirect.respond(status: 302, contentType: "audio/pcm")
        XCTAssertEqual(redirect.recorder.disposition, .cancel)
        guard case .statusError(_, let status) = redirect.recorder.errors.first as? OpenAIError else {
            return XCTFail("Expected a redirect status error")
        }
        XCTAssertEqual(status, 302)

        let nonHTTP = SpeechHarness()
        _ = nonHTTP.start()
        nonHTTP.respond(URLResponse(url: SpeechHarness.url, mimeType: "audio/pcm", expectedContentLength: 0, textEncodingName: nil))
        XCTAssertEqual(nonHTTP.recorder.errors.first as? AudioSpeechStreamError, .invalidResponse)
    }

    func testMissingHeadersAndEmptyResponsesFail() throws {
        let missing = SpeechHarness()
        _ = missing.start()
        missing.send(Data([0x01]))
        missing.complete()
        XCTAssertEqual(missing.recorder.errors.first as? AudioSpeechStreamError, .invalidResponse)
        XCTAssertTrue(missing.recorder.audio.isEmpty)

        let empty = SpeechHarness()
        _ = empty.start()
        try empty.respond(contentType: "audio/pcm")
        empty.send(Data())
        empty.complete()
        guard case .emptyData = empty.recorder.errors.first as? OpenAIError else {
            return XCTFail("Expected an empty audio error")
        }
        XCTAssertTrue(empty.recorder.audio.isEmpty)
    }

    func testTransportFailureStopsDeliveryWithoutReplayingAudio() throws {
        let harness = SpeechHarness()
        _ = harness.start()
        try harness.respond(contentType: "audio/pcm")
        harness.send(Data([0x01]))
        harness.complete(error: URLError(.networkConnectionLost))
        harness.send(Data([0x02]))
        harness.complete()
        XCTAssertEqual(harness.recorder.audio, [Data([0x01])])
        XCTAssertEqual((harness.recorder.errors.first as? URLError)?.code, .networkConnectionLost)
        XCTAssertEqual(harness.recorder.completions.count, 1)
        XCTAssertEqual(harness.transport.dataTaskCalls.count, 1)
    }

    func testCancellationBeforeHeadersAndDuringAudioStopsLateCallbacks() throws {
        for duringAudio in [false, true] {
            let harness = SpeechHarness()
            let request = harness.start()
            if duringAudio {
                try harness.respond(contentType: "audio/pcm")
                harness.send(Data([0x01]))
            }
            request.cancelRequest()
            request.cancelRequest()
            try harness.respond(contentType: "audio/pcm")
            harness.send(Data([0x02]))
            harness.complete(error: URLError(.cancelled))
            XCTAssertEqual(harness.recorder.audio, duringAudio ? [Data([0x01])] : [])
            XCTAssertEqual(harness.recorder.completions.count, 1)
            XCTAssertEqual((harness.recorder.errors.first as? URLError)?.code, .cancelled)
            XCTAssertGreaterThan(harness.transport.invalidateAndCancelCallCount, 0)
        }
    }

    func testPublicAsyncStreamPreservesRequestAndChunkOrderWithProductionQueues() async throws {
        let factory = MockURLSessionFactory()
        factory.urlSession.dataTask = DataTaskMock()
        let client = OpenAI(configuration: .init(token: "test-token"), customSession: URLSessionMock(), streamingURLSessionFactory: factory)
        let query = AudioSpeechQuery(model: "qwen3-tts", input: "Hello", voice: .custom("aiden"), responseFormat: .pcm, streamFormat: .audio)
        let stream = client.audioCreateSpeechStream(query: query, options: .init(expectedContentType: "audio/pcm"))
        let request = try XCTUnwrap(factory.urlSession.dataTaskCalls.first?.request)
        let encoded = try XCTUnwrap(request.httpBody)
        let sent = try JSONDecoder().decode(AudioSpeechQuery.self, from: encoded)
        XCTAssertEqual(sent.model, query.model)
        XCTAssertEqual(sent.voice, query.voice)
        XCTAssertEqual(sent.streamFormat, .audio)
        XCTAssertEqual(request.url?.path, "/v1/audio/speech")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")

        let session = factory.urlSession
        let delegate = try XCTUnwrap(session.delegate)
        let response = try XCTUnwrap(HTTPURLResponse(url: SpeechHarness.url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/pcm"]))
        delegate.urlSession(session, dataTask: session.dataTask, didReceive: response) { _ in }
        let chunks = [Data([0x00]), Data([0x80, 0xff]), Data([0x7f])]
        for chunk in chunks { delegate.urlSession(session, dataTask: session.dataTask, didReceive: chunk) }
        delegate.urlSession(session, task: session.dataTask, didCompleteWithError: nil)

        var received: [Data] = []
        for try await result in stream { received.append(result.audio) }
        XCTAssertEqual(received, chunks)
    }

    func testSuccessfulAsyncCompletionOnlyPerformsNormalSessionCleanup() async throws {
        for completesSynchronously in [false, true] {
            let harness = SpeechHarness()
            let audio = Data([0x01, 0x02])
            func deliverResponse() throws {
                try harness.respond(contentType: "audio/pcm")
                harness.send(audio)
                harness.complete()
            }
            if completesSynchronously {
                harness.transport.dataTask.completion = { _, _, _ in
                    do {
                        try deliverResponse()
                    } catch {
                        XCTFail("Failed to deliver the test response: \(error)")
                    }
                }
            }
            let stream: AsyncThrowingStream<AudioSpeechResult, Error> = harness.client.audioCreateSpeechStream(query: .mock)
            harness.transport.dataTask.completion = nil
            if !completesSynchronously { try deliverResponse() }

            var received: [Data] = []
            for try await result in stream { received.append(result.audio) }
            XCTAssertEqual(received, [audio])
            XCTAssertEqual(harness.transport.invalidateAndCancelCallCount, 1)
        }
    }

    func testAsyncFailureCancelsEvenWhenTransportFailsBeforeReturningRequest() async throws {
        let harness = SpeechHarness()
        harness.transport.dataTask.completion = { _, _, _ in
            harness.respond(URLResponse(url: SpeechHarness.url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
        let stream: AsyncThrowingStream<AudioSpeechResult, Error> = harness.client.audioCreateSpeechStream(query: .mock)
        do {
            for try await _ in stream { XCTFail("Invalid response must not yield audio") }
            XCTFail("Expected validation failure")
        } catch {
            XCTAssertEqual(error as? AudioSpeechStreamError, .invalidResponse)
        }
        XCTAssertGreaterThan(harness.transport.invalidateAndCancelCallCount, 0)
    }

    func testAsyncTaskCancellationReachesTransport() async throws {
        let harness = SpeechHarness()
        let stream: AsyncThrowingStream<AudioSpeechResult, Error> = harness.client.audioCreateSpeechStream(query: .mock)
        let task = Task {
            for try await _ in stream { XCTFail("No audio was sent") }
        }
        task.cancel()
        _ = try? await task.value
        XCTAssertGreaterThan(harness.transport.invalidateAndCancelCallCount, 0)
    }

    func testCancelFromAudioCallbackSuppressesAlreadyQueuedChunks() async throws {
        let queue = DispatchQueue(label: "speech-cancellation-test")
        let recorder = SpeechRecorder()
        let finished = expectation(description: "speech stream finished")
        let session = StreamingSession(
            urlRequest: URLRequest(url: SpeechHarness.url),
            interpreter: AudioSpeechStreamInterpreter(),
            sslDelegate: nil,
            middlewares: [],
            executionSerializer: GCDQueueAsyncExecutionSerializer(queue: queue),
            speechResponseValidator: .init(options: .init()),
            onReceiveContent: { session, result in
                recorder.audio.append(result.audio)
                session.cancelSpeech()
            },
            onProcessingError: { _, error in recorder.errors.append(error) },
            onComplete: { _, error in
                recorder.completions.append(error)
                finished.fulfill()
            }
        )
        let transport = URLSessionMock()
        let task = DataTaskMock()
        let response = try XCTUnwrap(HTTPURLResponse(url: SpeechHarness.url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/pcm"]))
        queue.suspend()
        session.urlSession(transport, dataTask: task, didReceive: response) { _ in }
        for byte: UInt8 in [1, 2, 3] {
            session.urlSession(transport, dataTask: task, didReceive: Data([byte]))
        }
        session.urlSession(transport, task: task, didCompleteWithError: nil)
        queue.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(recorder.audio, [Data([1])])
        XCTAssertEqual((recorder.completions.first.flatMap { $0 } as? URLError)?.code, .cancelled)
    }

    func testConcurrentRequestsHaveIndependentCancellationAndAudio() throws {
        let factory = MockStreamingSessionFactory()
        let transports = IndependentSpeechSessions()
        factory.urlSessionFactory = transports
        let client = OpenAI(configuration: .init(token: "test-token"), session: URLSessionMock(), streamingSessionFactory: factory, executionSerializer: NoDispatchExecutionSerializer())
        let first = SpeechRecorder()
        let second = SpeechRecorder()
        let firstRequest = client.audioCreateSpeechStream(query: .mock) { result in
            if case .success(let result) = result { first.audio.append(result.audio) }
        } completion: { error in first.completions.append(error) }
        _ = client.audioCreateSpeechStream(query: .mock) { result in
            if case .success(let result) = result { second.audio.append(result.audio) }
        } completion: { error in second.completions.append(error) }
        XCTAssertEqual(transports.sessions.count, 2)
        let response = try XCTUnwrap(HTTPURLResponse(url: SpeechHarness.url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/pcm"]))
        for transport in transports.sessions {
            transport.delegate?.urlSession(transport, dataTask: transport.dataTask, didReceive: response) { _ in }
        }
        firstRequest.cancelRequest()
        for (index, transport) in transports.sessions.enumerated() {
            transport.delegate?.urlSession(transport, dataTask: transport.dataTask, didReceive: Data([UInt8(index)]))
            transport.delegate?.urlSession(transport, task: transport.dataTask, didCompleteWithError: nil)
        }
        XCTAssertTrue(first.audio.isEmpty)
        XCTAssertEqual((first.completions[0] as? URLError)?.code, .cancelled)
        XCTAssertEqual(second.audio, [Data([1])])
        XCTAssertEqual(second.completions.count, 1)
        XCTAssertNil(second.completions[0])
    }
}

private final class IndependentSpeechSessions: MockURLSessionFactory, @unchecked Sendable {
    var sessions: [URLSessionMock] = []

    override func makeUrlSession(delegate: any URLSessionDataDelegateProtocol) -> any URLSessionProtocol {
        let session = URLSessionMock()
        session.delegate = delegate
        session.dataTask = DataTaskMock()
        sessions.append(session)
        return session
    }
}

private final class SpeechRecorder: @unchecked Sendable {
    var audio: [Data] = []
    var errors: [Error] = []
    var completions: [Error?] = []
    var events: [String] = []
    var disposition: URLSession.ResponseDisposition?
}

private final class SpeechHarness {
    static let url = URL(string: "https://example.com/v1/audio/speech")!
    let factory = MockStreamingSessionFactory()
    let recorder = SpeechRecorder()
    var transport: URLSessionMock { factory.urlSessionFactory.urlSession }
    lazy var client = OpenAI(
        configuration: .init(token: "test-token"),
        session: URLSessionMock(),
        streamingSessionFactory: factory,
        executionSerializer: NoDispatchExecutionSerializer()
    )

    init() {
        transport.dataTask = DataTaskMock()
    }

    func start(options: AudioSpeechStreamOptions = .init()) -> CancellableRequest {
        client.audioCreateSpeechStream(query: .mock, options: options) { [recorder] result in
            switch result {
            case .success(let result):
                recorder.audio.append(result.audio)
                recorder.events.append("audio")
            case .failure(let error):
                recorder.errors.append(error)
                recorder.events.append("error")
            }
        } completion: { [recorder] error in
            recorder.completions.append(error)
            recorder.events.append("complete")
        }
    }

    func respond(status: Int = 200, contentType: String?) throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: Self.url, statusCode: status, httpVersion: nil,
            headerFields: contentType.map { ["Content-Type": $0] }
        ))
        respond(response)
    }

    func respond(_ response: URLResponse) {
        transport.delegate?.urlSession(transport, dataTask: transport.dataTask, didReceive: response) { [recorder] in
            recorder.disposition = $0
        }
    }

    func send(_ data: Data) {
        transport.delegate?.urlSession(transport, dataTask: transport.dataTask, didReceive: data)
    }

    func complete(error: Error? = nil) {
        transport.delegate?.urlSession(transport, task: transport.dataTask, didCompleteWithError: error)
    }
}
