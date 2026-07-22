//
//  StreamingSessionTests.swift
//  OpenAI
//
//  Created by Oleksii Nezhyborets on 11.03.2025.
//

import XCTest
@testable import OpenAI

final class StreamingSessionTests: XCTestCase {
    private let streamInterpreter = MockDataStreamInterpreter()
    
    private var onReceivedContentCallCount = 0
    
    private lazy var streamingSession = StreamingSession(
        urlSessionFactory: MockURLSessionFactory(),
        urlRequest: .init(url: .init(string: "/")!),
        interpreter: streamInterpreter,
        sslDelegate: nil,
        middlewares: [],
        executionSerializer: NoDispatchExecutionSerializer(),
        onReceiveContent: { _, _ in
            self.onReceivedContentCallCount += 1
        },
        onProcessingError: { _, _ in },
        onComplete: { _,_ in }
    )

    @MainActor
    func testDataProcessedCallback() async throws {
        _ = streamingSession
        streamInterpreter.processData(.init())
        XCTAssertEqual(onReceivedContentCallCount, 1)
    }

    func testErrorResponseBodyDecodedAfterStreamingCompletes() throws {
        let recorder = StreamingSessionCallbackRecorder()
        let session = StreamingSession(
            urlSessionFactory: MockURLSessionFactory(),
            urlRequest: .init(url: .init(string: "/")!),
            interpreter: streamInterpreter,
            sslDelegate: nil,
            middlewares: [],
            executionSerializer: NoDispatchExecutionSerializer(),
            onReceiveContent: { _, _ in },
            onProcessingError: { _, error in
                recorder.processingError = error
            },
            onComplete: { _, error in
                recorder.completionError = error
                recorder.completionCallCount += 1
            }
        )
        let urlSession = URLSessionMock()
        let dataTask = DataTaskMock()
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com/v1/chat/completions")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: nil
        ))

        session.urlSession(
            urlSession,
            dataTask: dataTask,
            didReceive: response
        ) {
            recorder.disposition = $0
        }

        XCTAssertEqual(recorder.disposition, .allow)
        XCTAssertNil(recorder.processingError)

        let errorData = Data(
            """
            {"error":{"message":"model not available","type":"invalid_request_error","param":null,"code":"model_not_available"}}
            """.utf8
        )
        let splitIndex = errorData.count / 2
        session.urlSession(
            urlSession,
            dataTask: dataTask,
            didReceive: errorData.prefix(splitIndex)
        )
        session.urlSession(
            urlSession,
            dataTask: dataTask,
            didReceive: errorData.dropFirst(splitIndex)
        )
        session.urlSession(urlSession, task: dataTask, didCompleteWithError: nil)

        let errorResponse = try XCTUnwrap(recorder.processingError as? APIErrorResponse)
        XCTAssertEqual(errorResponse.error.message, "model not available")
        XCTAssertEqual(errorResponse.error.code, "model_not_available")
        XCTAssertNil(recorder.completionError)
        XCTAssertEqual(recorder.completionCallCount, 1)
    }
}

class MockDataStreamInterpreter: StreamInterpreter, @unchecked Sendable {
    typealias ResultType = Data
    
    private var onEventDispatched: ((Data) -> Void)?
    private var onError: ((any Error) -> Void)?
    
    func setCallbackClosures(onEventDispatched: @escaping (Data) -> Void, onError: @escaping (any Error) -> Void) {
        self.onEventDispatched = onEventDispatched
        self.onError = onError
    }
    
    func processData(_ data: Data) {
        onEventDispatched?(data)
    }
}

private final class StreamingSessionCallbackRecorder: @unchecked Sendable {
    var processingError: Error?
    var completionError: Error?
    var completionCallCount = 0
    var disposition: URLSession.ResponseDisposition?
}
