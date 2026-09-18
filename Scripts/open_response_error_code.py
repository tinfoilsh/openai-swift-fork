#!/usr/bin/env python3
"""Make the generated `ResponseErrorCode` enum decode unknown values.

Symptom:
    A `response.failed` stream event whose `response.error.code` is not one of
    the values enumerated in the spec fails to decode, so the client surfaces a
    `DecodingError` instead of the failed response and its human-readable
    message.

Cause:
    The spec declares `ResponseErrorCode` as a closed string enum and the
    generator emits a `@frozen` Swift enum with one case per value. OpenAI adds
    codes without a spec bump, and OpenAI-compatible servers emit their own
    codes such as `server_is_overloaded`, `model_unavailable`, and
    `upstream_error`. Any value outside the list is a hard decode failure.

Fix:
    Rewrite the generated enum in Components.swift: drop `@frozen` and
    `CaseIterable`, keep every spec case, add an `other(Swift.String)` case,
    and give the enum a hand-written `RawRepresentable` + `Codable`
    implementation that routes unknown strings into `other`. Existing pattern
    matches on the named cases keep compiling; exhaustive switches must add a
    `case .other` or `default` arm, which non-frozen enums require anyway.

Removal condition:
    Remove this workaround if the upstream spec stops enumerating the codes or
    if the generator gains an open-enum option.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


ENUM_START_RE = re.compile(
    r"^(?P<indent>\s+)@frozen public enum ResponseErrorCode: "
    r"String, Codable, Hashable, Sendable, CaseIterable \{[ \t]*(?:\r?\n)?$"
)
CASE_RE = re.compile(r'^\s+case (?P<name>\w+) = "(?P<value>[^"]+)"[ \t]*(?:\r?\n)?$')


def open_response_error_code(document: str) -> tuple[str, int]:
    """Return the document with ResponseErrorCode rewritten as an open enum."""

    lines = document.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if ENUM_START_RE.match(line)]
    if not starts:
        return document, 0
    if len(starts) != 1:
        raise ValueError(
            f"Expected exactly one closed ResponseErrorCode enum; found {len(starts)}."
        )

    start = starts[0]
    indent = ENUM_START_RE.match(lines[start]).group("indent")
    cases: list[tuple[str, str]] = []
    end = start + 1
    while end < len(lines):
        match = CASE_RE.match(lines[end])
        if match is None:
            break
        cases.append((match.group("name"), match.group("value")))
        end += 1
    if end >= len(lines) or lines[end].strip() != "}":
        raise ValueError("ResponseErrorCode enum did not end where expected.")
    if not cases:
        raise ValueError("ResponseErrorCode enum has no cases.")

    body_indent = indent + "    "
    inner_indent = body_indent + "    "
    out: list[str] = []
    out.append(f"{indent}public enum ResponseErrorCode: RawRepresentable, Codable, Hashable, Sendable {{\n")
    for name, value in cases:
        out.append(f"{body_indent}case {name}\n")
    out.append(f"{body_indent}/// A code outside the values enumerated by the spec. Servers add codes\n")
    out.append(f"{body_indent}/// without a spec bump, so unknown values are preserved rather than\n")
    out.append(f"{body_indent}/// failing to decode.\n")
    out.append(f"{body_indent}case other(Swift.String)\n")
    out.append(f"{body_indent}public typealias RawValue = Swift.String\n")
    out.append(f"{body_indent}public init(rawValue: Swift.String) {{\n")
    out.append(f"{inner_indent}switch rawValue {{\n")
    for name, value in cases:
        out.append(f'{inner_indent}case "{value}": self = .{name}\n')
    out.append(f"{inner_indent}default: self = .other(rawValue)\n")
    out.append(f"{inner_indent}}}\n")
    out.append(f"{body_indent}}}\n")
    out.append(f"{body_indent}public var rawValue: Swift.String {{\n")
    out.append(f"{inner_indent}switch self {{\n")
    for name, value in cases:
        out.append(f'{inner_indent}case .{name}: return "{value}"\n')
    out.append(f"{inner_indent}case .other(let value): return value\n")
    out.append(f"{inner_indent}}}\n")
    out.append(f"{body_indent}}}\n")
    out.append(f"{body_indent}public init(from decoder: any Decoder) throws {{\n")
    out.append(f"{inner_indent}self.init(rawValue: try decoder.singleValueContainer().decode(Swift.String.self))\n")
    out.append(f"{body_indent}}}\n")
    out.append(f"{body_indent}public func encode(to encoder: any Encoder) throws {{\n")
    out.append(f"{inner_indent}var container = encoder.singleValueContainer()\n")
    out.append(f"{inner_indent}try container.encode(rawValue)\n")
    out.append(f"{body_indent}}}\n")
    out.append(f"{indent}}}\n")

    lines[start : end + 1] = out
    return "".join(lines), len(cases)


def report_result(case_count: int) -> None:
    if case_count:
        print(
            f"open_response_error_code: rewrote ResponseErrorCode as an open enum "
            f"({case_count} spec cases + other)"
        )
    else:
        print("open_response_error_code: no closed ResponseErrorCode enum found (no-op)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    document, case_count = open_response_error_code(
        args.input.read_text(encoding="utf-8")
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(document, encoding="utf-8")
    report_result(case_count)


if __name__ == "__main__":
    main()
