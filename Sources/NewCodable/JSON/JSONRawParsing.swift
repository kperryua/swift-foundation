//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// MARK: - Shared JSON raw-byte parsing helpers
//
// These free functions operate on `RawSpan` and are used by both
// `JSONStreamingPrimitive` and `JSONPrescannedPrimitive` to avoid duplicating
// low-level parsing logic.

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif FOUNDATION_FRAMEWORK
import Foundation
#endif

package import BasicContainers

// MARK: - Value Kind Detection

/// Determines the JSON value kind from the byte at the given offset.
@usableFromInline
func _jsonKindOfValue(
    in bytes: RawSpan, at offset: Int
) throws(JSONError) -> JSONValueKind {
    let byte = bytes._loadByteUnchecked(offset)
    switch byte {
    case ._quote: return .string
    case ._openbrace: return .object
    case ._openbracket: return .array
    case UInt8(ascii: "t"), UInt8(ascii: "f"): return .bool
    case UInt8(ascii: "n"): return .null
    case ._minus, _asciiNumbers: return .number
    default:
        throw .unexpectedCharacter(
            ascii: byte,
            location: .init(byteOffset: offset)
        )
    }
}

// MARK: - Whitespace Skipping

/// Skips whitespace bytes and returns the offset of the first non-whitespace byte.
@usableFromInline
func _jsonSkipWhitespace(in bytes: RawSpan, from offset: Int) -> Int {
    var i = offset
    while i < bytes.byteCount {
        switch bytes._loadByteUnchecked(i) {
        case ._space, ._tab, ._newline, ._return:
            i &+= 1
        default:
            return i
        }
    }
    return i
}

// MARK: - Literal Validation

/// Validates that the bytes at `offset` spell out the given literal.
@inline(__always)
private func _jsonValidateLiteral(
    _ literal: StaticString,
    in bytes: RawSpan,
    at offset: Int
) throws(JSONError) {
    try literal.withUTF8SpanForCodable { (expected: UTF8Span) throws(JSONError) in
        let count = expected.count
        guard offset + count <= bytes.byteCount else {
            throw JSONError.unexpectedEndOfFile
        }
        let expectedBytes = expected.span.bytes
        for i in 0 ..< count {
            let actual = bytes._loadByteUnchecked(offset + i)
            let exp = expectedBytes._loadByteUnchecked(i)
            guard actual == exp else {
                throw JSONError.unexpectedCharacter(
                    context: "in literal",
                    ascii: actual,
                    location: .init(byteOffset: offset + i)
                )
            }
        }
    }
}

/// Validates that the bytes at `offset` spell out `true`.
@usableFromInline
func _jsonValidateTrue(
    in bytes: RawSpan, at offset: Int
) throws(JSONError) {
    try _jsonValidateLiteral("true", in: bytes, at: offset)
}

/// Validates that the bytes at `offset` spell out `false`.
@usableFromInline
func _jsonValidateFalse(
    in bytes: RawSpan, at offset: Int
) throws(JSONError) {
    try _jsonValidateLiteral("false", in: bytes, at: offset)
}

/// Validates that the bytes at `offset` spell out `null`.
@usableFromInline
func _jsonValidateNull(
    in bytes: RawSpan, at offset: Int
) throws(JSONError) {
    try _jsonValidateLiteral("null", in: bytes, at: offset)
}

// MARK: - Number Parsing

/// Finds the end offset of a JSON number starting at `offset`.
@usableFromInline
func _jsonFindEndOfNumber(in bytes: RawSpan, from offset: Int) -> Int {
    var i = offset
    // Optional leading minus
    if i < bytes.byteCount && bytes._loadByteUnchecked(i) == ._minus {
        i &+= 1
    }
    while i < bytes.byteCount {
        let byte = bytes._loadByteUnchecked(i)
        switch byte {
        case _asciiNumbers, ._period, ._e, ._E, ._plus, ._minus:
            // Note: ._plus/._minus here only valid after e/E but we're
            // doing structural scanning, not validation.
            i &+= 1
        default:
            return i
        }
    }
    return i
}

/// Validates that the bytes in `span` form a well-formed JSON number per
/// RFC 8259: `[ minus ] int [ frac ] [ exp ]` where
/// `int = "0" / digit1-9 *DIGIT`, `frac = "." 1*DIGIT`, `exp = e [+-] 1*DIGIT`.
@usableFromInline
func _jsonValidateNumber(
    _ span: RawSpan, at sourceOffset: Int
) throws(JSONError) {
    var i = 0
    let count = span.byteCount
    guard count > 0 else {
        throw .unexpectedEndOfFile
    }

    // Optional leading minus
    if span._loadByteUnchecked(i) == ._minus {
        i &+= 1
        guard i < count else {
            throw .unexpectedCharacter(
                context: "in number",
                ascii: ._minus,
                location: .init(byteOffset: sourceOffset)
            )
        }
    }

    // Integer part
    let firstDigit = span._loadByteUnchecked(i)
    guard case _asciiNumbers = firstDigit else {
        throw .unexpectedCharacter(
            context: "in number",
            ascii: firstDigit,
            location: .init(byteOffset: sourceOffset + i)
        )
    }
    if firstDigit == UInt8(ascii: "0") {
        i &+= 1
        // Leading zero must not be followed by another digit.
        if i < count, case _asciiNumbers = span._loadByteUnchecked(i) {
            throw .numberWithLeadingZero(
                location: .init(byteOffset: sourceOffset)
            )
        }
    } else {
        // digit1-9 followed by any digits
        i &+= 1
        while i < count, case _asciiNumbers = span._loadByteUnchecked(i) {
            i &+= 1
        }
    }

    // Optional fractional part
    if i < count, span._loadByteUnchecked(i) == ._period {
        i &+= 1
        // Must have at least one digit after '.'
        guard i < count, case _asciiNumbers = span._loadByteUnchecked(i) else {
            let ascii = i < count ? span._loadByteUnchecked(i) : ._period
            throw .unexpectedCharacter(
                context: "after '.' in number",
                ascii: ascii,
                location: .init(byteOffset: sourceOffset + i)
            )
        }
        while i < count, case _asciiNumbers = span._loadByteUnchecked(i) {
            i &+= 1
        }
    }

    // Optional exponent part
    if i < count {
        let expByte = span._loadByteUnchecked(i)
        if expByte == ._e || expByte == ._E {
            i &+= 1
            // Optional sign
            if i < count {
                let signByte = span._loadByteUnchecked(i)
                if signByte == ._plus || signByte == ._minus {
                    i &+= 1
                }
            }
            // Must have at least one digit after exponent
            guard i < count, case _asciiNumbers = span._loadByteUnchecked(i) else {
                let ascii = i < count ? span._loadByteUnchecked(i) : expByte
                throw .unexpectedCharacter(
                    context: "after exponent in number",
                    ascii: ascii,
                    location: .init(byteOffset: sourceOffset + i)
                )
            }
            while i < count, case _asciiNumbers = span._loadByteUnchecked(i) {
                i &+= 1
            }
        }
    }

    // Must have consumed all bytes
    guard i == count else {
        throw .unexpectedCharacter(
            context: "in number",
            ascii: span._loadByteUnchecked(i),
            location: .init(byteOffset: sourceOffset + i)
        )
    }
}

// MARK: - String Scanning

/// Finds the offset of the closing quote for a string starting at
/// `contentStart` (the byte after the opening quote).
@usableFromInline
func _jsonFindClosingQuote(
    in bytes: RawSpan, from contentStart: Int
) throws(JSONError) -> Int {
    var i = contentStart
    while i < bytes.byteCount {
        let byte = bytes._loadByteUnchecked(i)
        switch byte {
        case ._quote:
            return i
        case ._backslash:
            i &+= 2 // skip backslash and escaped character
        default:
            i &+= 1
        }
    }
    throw .unexpectedEndOfFile
}

// MARK: - String Comparison

/// Compares a `RawSpan` of UTF-8 bytes against a `String` for equality.
@usableFromInline
func _jsonRawSpanEqualsUTF8(_ span: RawSpan, _ string: String) -> Bool {
    var utf8 = string.utf8.makeIterator()
    guard span.byteCount == string.utf8.count else { return false }
    for i in 0 ..< span.byteCount {
        guard let expected = utf8.next(),
              span._loadByteUnchecked(i) == expected else {
            return false
        }
    }
    return true
}

// MARK: - Escape Processing

/// Dispatches a single JSON escape sequence. `escaped` is the byte after the
/// backslash (e.g. `n`, `t`, `u`, etc.). For `\uXXXX` sequences, `offset`
/// points to the first hex digit and is advanced past the escape (including
/// surrogate pairs). For all other escapes, `offset` is not modified.
func _jsonDispatchEscapeSequence(
    escaped: UInt8,
    in rawSpan: RawSpan,
    at offset: inout Int,
    into buffer: inout UniqueArray<UInt8>
) throws(JSONError) {
    switch escaped {
    case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
    case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
    case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
    case UInt8(ascii: "b"): buffer.append(0x08)
    case UInt8(ascii: "f"): buffer.append(0x0C)
    case UInt8(ascii: "n"): buffer.append(0x0A)
    case UInt8(ascii: "r"): buffer.append(0x0D)
    case UInt8(ascii: "t"): buffer.append(0x09)
    case UInt8(ascii: "u"):
        try _jsonProcessUnicodeEscape(from: rawSpan, at: &offset, into: &buffer)
    default:
        throw .unexpectedEscapedCharacter(
            ascii: escaped,
            location: .init(byteOffset: offset)
        )
    }
}

/// Processes JSON escape sequences in `rawSpan`, appending the decoded
/// UTF-8 bytes into `buffer`.
func _jsonProcessEscapes(
    from rawSpan: RawSpan, into buffer: inout UniqueArray<UInt8>
) throws(JSONError) {
    var i = 0
    let count = rawSpan.byteCount
    var chunkStart = 0

    while i < count {
        let byte = rawSpan._loadByteUnchecked(i)
        if byte == ._backslash {
            // Copy the literal chunk before this escape
            if i > chunkStart {
                let chunk = rawSpan.extracting(chunkStart ..< i)
                chunk.withUnsafeBytes { ptr in
                    for j in 0 ..< ptr.count {
                        buffer.append(ptr.load(fromByteOffset: j, as: UInt8.self))
                    }
                }
            }
            i &+= 1
            guard i < count else { throw .unexpectedEndOfFile }
            let escaped = rawSpan._loadByteUnchecked(i)
            i &+= 1 // advance past the escaped character
            try _jsonDispatchEscapeSequence(
                escaped: escaped, in: rawSpan, at: &i, into: &buffer
            )
            chunkStart = i
        } else {
            i &+= 1
        }
    }

    // Copy any remaining literal chunk
    if chunkStart < count {
        let chunk = rawSpan.extracting(chunkStart ..< count)
        chunk.withUnsafeBytes { ptr in
            for j in 0 ..< ptr.count {
                buffer.append(ptr.load(fromByteOffset: j, as: UInt8.self))
            }
        }
    }
}

/// Parses a `\uXXXX` (and optional surrogate pair) escape at the current
/// position, appends the resulting UTF-8 bytes, and advances `i` past
/// the escape.
func _jsonProcessUnicodeEscape(
    from rawSpan: RawSpan, at i: inout Int, into buffer: inout UniqueArray<UInt8>
) throws(JSONError) {
    guard i + 4 <= rawSpan.byteCount else { throw .unexpectedEndOfFile }
    let codeUnit = try _jsonParseHex4(from: rawSpan, at: i)
    i &+= 4

    var scalar: Unicode.Scalar
    if UTF16.isLeadSurrogate(codeUnit) {
        // Expect \uXXXX for the low surrogate
        guard i + 6 <= rawSpan.byteCount,
              rawSpan._loadByteUnchecked(i) == ._backslash,
              rawSpan._loadByteUnchecked(i + 1) == UInt8(ascii: "u") else {
            throw .expectedLowSurrogateUTF8SequenceAfterHighSurrogate(
                location: .init(byteOffset: i)
            )
        }
        i &+= 2
        let lowUnit = try _jsonParseHex4(from: rawSpan, at: i)
        i &+= 4
        guard UTF16.isTrailSurrogate(lowUnit) else {
            throw .expectedLowSurrogateUTF8SequenceAfterHighSurrogate(
                location: .init(byteOffset: i)
            )
        }
        let encodedScalar = UTF16.EncodedScalar([codeUnit, lowUnit])
        scalar = UTF16.decode(encodedScalar)
    } else if UTF16.isTrailSurrogate(codeUnit) {
        throw .expectedLowSurrogateUTF8SequenceAfterHighSurrogate(
            location: .init(byteOffset: i)
        )
    } else {
        guard let s = Unicode.Scalar(codeUnit) else {
            throw .couldNotCreateUnicodeScalarFromUInt32(
                location: .init(byteOffset: i), unicodeScalarValue: UInt32(codeUnit)
            )
        }
        scalar = s
    }

    // Encode the scalar as UTF-8
    UTF8.encode(scalar) { codeUnit in
        buffer.append(codeUnit)
    }
}

/// Parses 4 hex digits from `rawSpan` at position `offset`.
@usableFromInline
func _jsonParseHex4(from rawSpan: RawSpan, at offset: Int) throws(JSONError) -> UInt16 {
    var value: UInt16 = 0
    for j in 0 ..< 4 {
        let byte = rawSpan._loadByteUnchecked(offset + j)
        let nibble: UInt16
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            nibble = UInt16(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a") ... UInt8(ascii: "f"):
            nibble = UInt16(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A") ... UInt8(ascii: "F"):
            nibble = UInt16(byte - UInt8(ascii: "A") + 10)
        default:
            let hexString = String(
                decoding: (0..<4).map { rawSpan._loadByteUnchecked(offset + $0) },
                as: UTF8.self
            )
            throw .invalidHexDigitSequence(
                hexString, location: .init(byteOffset: offset + j)
            )
        }
        value = (value << 4) | nibble
    }
    return value
}

// MARK: - Value Skipping

/// Skips past the JSON value at `offset`, returning the offset just after it.
/// This handles nested structures by tracking bracket/brace depth.
@usableFromInline
func _jsonSkipValue(
    in bytes: RawSpan, from offset: Int
) throws(JSONError) -> Int {
    guard offset < bytes.byteCount else {
        throw .unexpectedEndOfFile
    }
    let byte = bytes._loadByteUnchecked(offset)
    switch byte {
    case ._quote:
        // String: skip to closing quote
        let contentEnd = try _jsonFindClosingQuote(in: bytes, from: offset + 1)
        return contentEnd + 1 // past closing quote

    case ._openbracket:
        // Array: skip all elements
        return try _jsonSkipCollection(
            in: bytes, from: offset + 1,
            closeDelimiter: ._closebracket
        )

    case ._openbrace:
        // Object: skip all key-value pairs
        return try _jsonSkipCollection(
            in: bytes, from: offset + 1,
            closeDelimiter: ._closebrace
        )

    case UInt8(ascii: "t"):
        try _jsonValidateTrue(in: bytes, at: offset)
        return offset + 4

    case UInt8(ascii: "f"):
        try _jsonValidateFalse(in: bytes, at: offset)
        return offset + 5

    case UInt8(ascii: "n"):
        try _jsonValidateNull(in: bytes, at: offset)
        return offset + 4

    case ._minus, _asciiNumbers:
        return _jsonFindEndOfNumber(in: bytes, from: offset)

    default:
        throw .unexpectedCharacter(
            ascii: byte,
            location: .init(byteOffset: offset)
        )
    }
}

/// Skips a collection (array or object) body, starting after the open
/// delimiter, and returns the offset after the close delimiter.
@usableFromInline
func _jsonSkipCollection(
    in bytes: RawSpan, from start: Int, closeDelimiter: UInt8
) throws(JSONError) -> Int {
    var depth = 1
    var i = start
    while i < bytes.byteCount && depth > 0 {
        let byte = bytes._loadByteUnchecked(i)
        switch byte {
        case ._openbracket, ._openbrace:
            depth += 1
            i &+= 1
        case ._closebracket, ._closebrace:
            depth -= 1
            i &+= 1
        case ._quote:
            // Skip string contents (may contain brackets/braces)
            i &+= 1
            i = try _jsonFindClosingQuote(in: bytes, from: i) + 1
        default:
            i &+= 1
        }
    }
    guard depth == 0 else {
        throw .unexpectedEndOfFile
    }
    return i
}

// MARK: - UTF-8 String Processing

/// Processes the raw string bytes of a JSON value (handling escape sequences
/// if necessary), validates UTF-8, and calls `body` with the resulting
/// `UTF8Span`. The `UTF8Span` is only valid for the duration of the closure.
///
/// - Parameters:
///   - rawSpan: The raw bytes between the quotes (escape sequences still present).
///   - isSimple: Whether the string has no escape sequences.
///   - body: A closure to call with the validated `UTF8Span`.
@usableFromInline
func _jsonWithUTF8String<T>(
    rawSpan: RawSpan, isSimple: Bool,
    _ body: (UTF8Span) throws -> T
) throws(JSONError) -> T {
    if isSimple {
        // Fast path: no escapes, just validate UTF-8 directly from source.
        do {
            let utf8Span = try UTF8Span(validating: Span<UInt8>(_bytes: rawSpan))
            return try body(utf8Span)
        } catch {
            throw .cannotConvertEntireInputDataToUTF8
        }
    } else {
        // Slow path: process escape sequences into temporary buffer.
        var buffer = UniqueArray<UInt8>()
        try _jsonProcessEscapes(from: rawSpan, into: &buffer)
        do {
            let utf8Span = try UTF8Span(validating: buffer.span)
            return try body(utf8Span)
        } catch {
            throw .cannotConvertEntireInputDataToUTF8
        }
    }
}
