//
//  ResponseObjectCodingTests.swift
//  OpenAI
//

// Swift Testing ships with Swift 6 toolchains. The package still supports Swift 5.10, where these tests do not exist.
#if canImport(Testing)
import Testing
@testable import OpenAI
import Foundation

struct ResponseObjectCodingTests {
    private let minimalJSON = """
    {
        "id": "resp-abc123",
        "object": "response",
        "model": "gpt-4o",
        "created_at": 1717459200,
        "output": [],
        "tools": [],
        "tool_choice": "auto",
        "metadata": {},
        "parallel_tool_calls": false
    }
    """

    @Test func decodeMinimalResponse() throws {
        let response = try decode(minimalJSON)
        #expect(response.id == "resp-abc123")
        #expect(response.object == "response")
        #expect(response.model == "gpt-4o")
        #expect(response.output.isEmpty)
        #expect(response.tools.isEmpty)
    }

    @Test func decodeCreatedAtAsDouble() throws {
        let response = try decode(minimalJSON)
        #expect(response.createdAt == 1717459200.0)
    }

    @Test func decodeIncompleteDetailsAbsent() throws {
        let response = try decode(minimalJSON)
        #expect(response.incompleteDetails == nil)
    }

    @Test func decodeIncompleteDetailsNull() throws {
        let json = """
        {
            "id": "resp-abc123",
            "object": "response",
            "model": "gpt-4o",
            "created_at": 1717459200,
            "output": [],
            "tools": [],
            "tool_choice": "auto",
            "metadata": {},
            "parallel_tool_calls": false,
            "incomplete_details": null
        }
        """
        let response = try decode(json)
        #expect(response.incompleteDetails == nil)
    }

    @Test func decodeIncompleteDetailsPresent() throws {
        let json = """
        {
            "id": "resp-abc123",
            "object": "response",
            "model": "gpt-4o",
            "created_at": 1717459200,
            "output": [],
            "tools": [],
            "tool_choice": "auto",
            "metadata": {},
            "parallel_tool_calls": false,
            "incomplete_details": { "reason": "max_output_tokens" }
        }
        """
        let response = try decode(json)
        #expect(response.incompleteDetails != nil)
    }

    // Servers attach their own codes to failed responses (OpenAI adds codes
    // without a spec bump; OpenAI-compatible servers use codes such as
    // `upstream_error`). A failed response must decode whatever the code is,
    // so callers see the human-readable message instead of a decoding error.
    @Test(arguments: [
        ("server_error", Components.Schemas.ResponseErrorCode.serverError),
        ("rate_limit_exceeded", .rateLimitExceeded),
        ("upstream_error", .other("upstream_error")),
        ("server_is_overloaded", .other("server_is_overloaded")),
        ("model_unavailable", .other("model_unavailable")),
    ])
    func decodeFailedResponseWithAnyErrorCode(raw: String, expected: Components.Schemas.ResponseErrorCode) throws {
        let json = """
        {
            "id": "resp-abc123",
            "object": "response",
            "model": "gpt-4o",
            "created_at": 1717459200,
            "status": "failed",
            "output": [],
            "tools": [],
            "metadata": {},
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "error": { "code": "\(raw)", "message": "The server had an error while processing your request." }
        }
        """
        let response = try decode(json)
        #expect(response.error?.code == expected)
        #expect(response.error?.code.rawValue == raw)
        #expect(response.error?.message == "The server had an error while processing your request.")
    }

    @Test func decodeFailedResponseEventWithUnknownErrorCode() throws {
        let json = """
        {
            "type": "response.failed",
            "sequence_number": 7,
            "response": {
                "id": "resp-abc123",
                "object": "response",
                "model": "gpt-4o",
                "created_at": 1717459200,
                "status": "failed",
                "output": [],
                "tools": [],
                "metadata": {},
                "tool_choice": "auto",
                "parallel_tool_calls": false,
                "error": { "code": "upstream_error", "message": "boom" }
            }
        }
        """
        let event = try JSONDecoder().decode(Components.Schemas.ResponseFailedEvent.self, from: Data(json.utf8))
        #expect(event.response.value3.error?.code == .other("upstream_error"))
        #expect(event.response.value3.error?.message == "boom")
    }

    @Test func responseErrorCodeRoundTripsUnknownValues() throws {
        let code = Components.Schemas.ResponseErrorCode(rawValue: "brand_new_code")
        #expect(code == .other("brand_new_code"))
        let encoded = try JSONEncoder().encode(code)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"brand_new_code\"")
        #expect(try JSONDecoder().decode(Components.Schemas.ResponseErrorCode.self, from: encoded) == code)
    }

    private func decode(_ json: String) throws -> ResponseObject {
        try JSONDecoder().decode(ResponseObject.self, from: Data(json.utf8))
    }
}
#endif
