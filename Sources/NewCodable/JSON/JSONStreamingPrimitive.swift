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


#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif FOUNDATION_FRAMEWORK
import Foundation
#endif

// MARK: - JSONStreamingPrimitive

/// A lazy, non-escaping representation of a JSON value that parses the document
/// structure on-the-fly as you iterate, with no upfront scanning pass.
///
/// `JSONStreamingPrimitive` stores only a `RawSpan`, the byte offset where this
/// value begins, and the value's kind (determined by peeking at the first byte).
/// All structure discovery happens at iteration time.
///
/// Like `JSONPrescannedPrimitive`, this type is `Copyable` but `~Escapable`
/// (its lifetime is tied to the input `RawSpan`).
@usableFromInline
struct JSONStreamingPrimitive: ~Escapable {

    // MARK: Stored properties

    @usableFromInline let bytes: RawSpan
    @usableFromInline let startOffset: Int
    @usableFromInline let _kind: JSONValueKind

    @usableFromInline
    @_lifetime(copy bytes)
    init(bytes: RawSpan, startOffset: Int, kind: JSONValueKind) {
        self.bytes = bytes
        self.startOffset = startOffset
        self._kind = kind
    }

    // MARK: - Value Kind

    @usableFromInline
    var kind: JSONValueKind { _kind }

    // MARK: - Construction

    /// Creates a `JSONStreamingPrimitive` from the root value in the given bytes.
    @_lifetime(copy bytes)
    @usableFromInline
    static func from(_ bytes: RawSpan) throws(JSONError) -> JSONStreamingPrimitive {
        let offset = _jsonSkipWhitespace(in: bytes, from: 0)
        guard offset < bytes.byteCount else {
            throw .unexpectedEndOfFile
        }
        let kind = try _jsonKindOfValue(in: bytes, at: offset)
        switch kind {
        case .bool:
            if bytes._loadByteUnchecked(offset) == UInt8(ascii: "t") {
                try _jsonValidateTrue(in: bytes, at: offset)
            } else {
                try _jsonValidateFalse(in: bytes, at: offset)
            }
        case .null:
            try _jsonValidateNull(in: bytes, at: offset)
        default:
            break
        }
        return JSONStreamingPrimitive(bytes: bytes, startOffset: offset, kind: kind)
    }

    // MARK: - Leaf Accessors

    /// The raw UTF-8 bytes of a string value (content between the quotes),
    /// with escape sequences still present. For simple strings this is directly
    /// usable UTF-8. For strings with escape sequences you must process escapes
    /// before interpreting.
    @usableFromInline
    var rawStringBytes: RawSpan {
        @_lifetime(copy self)
        get throws(JSONError) {
            guard _kind == .string else {
                throw .unexpectedCharacter(
                    context: "expected string",
                    ascii: bytes._loadByteUnchecked(startOffset),
                    location: .init(byteOffset: startOffset)
                )
            }
            // startOffset points to the opening quote
            let contentStart = startOffset + 1
            let contentEnd = try _jsonFindClosingQuote(
                in: bytes, from: contentStart
            )
            return bytes.extracting(contentStart ..< contentEnd)
        }
    }

    /// Whether this string has no escape sequences.
    @usableFromInline
    var isSimpleString: Bool {
        guard _kind == .string else { return false }
        let contentStart = startOffset + 1
        var offset = contentStart
        while offset < bytes.byteCount {
            let byte = bytes._loadByteUnchecked(offset)
            if byte == ._backslash { return false }
            if byte == ._quote { return true }
            offset &+= 1
        }
        return true
    }

    /// Processes the string value (handling escape sequences if necessary),
    /// validates UTF-8, and calls `body` with the resulting `UTF8Span`.
    /// The `UTF8Span` is only valid for the duration of the closure.
    @usableFromInline
    func withUTF8String<T>(
        _ body: (UTF8Span) throws -> T
    ) throws(JSONError) -> T {
        let rawSpan = try rawStringBytes
        return try _jsonWithUTF8String(rawSpan: rawSpan, isSimple: isSimpleString, body)
    }

    /// The raw UTF-8 bytes of a number value.
    @usableFromInline
    var numberBytes: RawSpan {
        @_lifetime(copy self)
        get throws(JSONError) {
            guard _kind == .number else {
                throw .unexpectedCharacter(
                    context: "expected number",
                    ascii: bytes._loadByteUnchecked(startOffset),
                    location: .init(byteOffset: startOffset)
                )
            }
            let endOffset = _jsonFindEndOfNumber(
                in: bytes, from: startOffset
            )
            let span = bytes.extracting(startOffset ..< endOffset)
            try _jsonValidateNumber(span, at: startOffset)
            return span
        }
    }

    /// The boolean value if this is a `true` or `false` literal.
    @usableFromInline
    var boolValue: Bool {
        get throws(JSONError) {
            guard _kind == .bool else {
                throw .unexpectedEndOfFile
            }
            if bytes._loadByteUnchecked(startOffset) == UInt8(ascii: "t") {
                try _jsonValidateTrue(in: bytes, at: startOffset)
                return true
            } else {
                try _jsonValidateFalse(in: bytes, at: startOffset)
                return false
            }
        }
    }

    /// Whether this value is a JSON `null`.
    /// Note: This does not validate the full literal. Call `validateNull()`
    /// if full validation is needed.
    @usableFromInline
    var isNull: Bool {
        _kind == .null
    }

    /// Validates that this value is a well-formed JSON `null` literal.
    @usableFromInline
    func validateNull() throws(JSONError) {
        guard _kind == .null else {
            throw .unexpectedEndOfFile
        }
        try _jsonValidateNull(in: bytes, at: startOffset)
    }

    // MARK: - Array Iteration

    /// An iterator over the elements of a JSON array.
    @usableFromInline
    struct ArrayIterator: ~Escapable {
        @usableFromInline let bytes: RawSpan
        @usableFromInline var currentOffset: Int
        @usableFromInline var done: Bool

        @usableFromInline
        @_lifetime(copy bytes)
        init(bytes: RawSpan, afterOpenBracket: Int) {
            self.bytes = bytes
            self.currentOffset = afterOpenBracket
            self.done = false
        }

        /// Returns the next element, or `nil` when iteration is complete.
        @_lifetime(copy self)
        @usableFromInline
        mutating func next() throws(JSONError) -> JSONStreamingPrimitive? {
            guard !done else { return nil }

            var offset = _jsonSkipWhitespace(
                in: bytes, from: currentOffset
            )
            guard offset < bytes.byteCount else {
                throw .unexpectedEndOfFile
            }

            // Check for close bracket
            if bytes._loadByteUnchecked(offset) == ._closebracket {
                done = true
                return nil
            }

            let kind = try _jsonKindOfValue(in: bytes, at: offset)
            let element = JSONStreamingPrimitive(
                bytes: bytes, startOffset: offset, kind: kind
            )

            // Skip past this value to find the next element
            offset = try _jsonSkipValue(in: bytes, from: offset)
            offset = _jsonSkipWhitespace(in: bytes, from: offset)

            guard offset < bytes.byteCount else {
                throw .unexpectedEndOfFile
            }

            switch bytes._loadByteUnchecked(offset) {
            case ._comma:
                currentOffset = offset + 1
            case ._closebracket:
                currentOffset = offset
                done = true
            default:
                throw .unexpectedCharacter(
                    context: "in array",
                    ascii: bytes._loadByteUnchecked(offset),
                    location: .init(byteOffset: offset)
                )
            }

            return element
        }
    }

    /// Creates an iterator over array elements. Throws if this value is not an array.
    @_lifetime(copy self)
    @usableFromInline
    func makeArrayIterator() throws(JSONError) -> ArrayIterator {
        guard _kind == .array else {
            throw .unexpectedEndOfFile
        }
        return ArrayIterator(bytes: bytes, afterOpenBracket: startOffset + 1)
    }

    // MARK: - Object Iteration

    /// An iterator over the key-value pairs of a JSON object.
    @usableFromInline
    struct ObjectIterator: ~Escapable {
        @usableFromInline let bytes: RawSpan
        @usableFromInline var currentOffset: Int
        @usableFromInline var done: Bool

        @usableFromInline
        @_lifetime(copy bytes)
        init(bytes: RawSpan, afterOpenBrace: Int) {
            self.bytes = bytes
            self.currentOffset = afterOpenBrace
            self.done = false
        }

        /// Returns the next (key, value) pair, or `nil` when iteration is complete.
        @_lifetime(copy self)
        @usableFromInline
        mutating func next() throws(JSONError) -> (
            key: JSONStreamingPrimitive, value: JSONStreamingPrimitive
        )? {
            guard !done else { return nil }

            var offset = _jsonSkipWhitespace(
                in: bytes, from: currentOffset
            )
            guard offset < bytes.byteCount else {
                throw .unexpectedEndOfFile
            }

            // Check for close brace
            if bytes._loadByteUnchecked(offset) == ._closebrace {
                done = true
                return nil
            }

            // Key must be a string
            guard bytes._loadByteUnchecked(offset) == ._quote else {
                throw .unexpectedCharacter(
                    context: "at beginning of object key",
                    ascii: bytes._loadByteUnchecked(offset),
                    location: .init(byteOffset: offset)
                )
            }

            let key = JSONStreamingPrimitive(
                bytes: bytes, startOffset: offset, kind: .string
            )

            // Skip past key
            offset = try _jsonSkipValue(in: bytes, from: offset)
            offset = _jsonSkipWhitespace(in: bytes, from: offset)

            // Expect colon
            guard offset < bytes.byteCount,
                  bytes._loadByteUnchecked(offset) == ._colon else {
                throw .unexpectedCharacter(
                    context: "after object key",
                    ascii: offset < bytes.byteCount ? bytes._loadByteUnchecked(offset) : 0,
                    location: .init(byteOffset: offset)
                )
            }
            offset += 1

            // Value
            offset = _jsonSkipWhitespace(in: bytes, from: offset)
            guard offset < bytes.byteCount else {
                throw .unexpectedEndOfFile
            }

            let valueKind = try _jsonKindOfValue(in: bytes, at: offset)
            let value = JSONStreamingPrimitive(
                bytes: bytes, startOffset: offset, kind: valueKind
            )

            // Skip past value
            offset = try _jsonSkipValue(in: bytes, from: offset)
            offset = _jsonSkipWhitespace(in: bytes, from: offset)

            guard offset < bytes.byteCount else {
                throw .unexpectedEndOfFile
            }

            switch bytes._loadByteUnchecked(offset) {
            case ._comma:
                currentOffset = offset + 1
            case ._closebrace:
                currentOffset = offset
                done = true
            default:
                throw .unexpectedCharacter(
                    context: "in object",
                    ascii: bytes._loadByteUnchecked(offset),
                    location: .init(byteOffset: offset)
                )
            }

            return (key, value)
        }
    }

    /// Creates an iterator over object key-value pairs. Throws if not an object.
    @_lifetime(copy self)
    @usableFromInline
    func makeObjectIterator() throws(JSONError) -> ObjectIterator {
        guard _kind == .object else {
            throw .unexpectedEndOfFile
        }
        return ObjectIterator(bytes: bytes, afterOpenBrace: startOffset + 1)
    }

    // MARK: - Key Lookup

    /// Returns the value for the given key in a JSON object, or `nil` if the
    /// key is not found. This is an O(n) linear scan each time it is called.
    /// Throws if this value is not an object.
    @_lifetime(copy self)
    @usableFromInline
    func value(forKey searchKey: String) throws(JSONError) -> JSONStreamingPrimitive? {
        var iter = try makeObjectIterator()
        while let (key, value) = try iter.next() {
            let matches: Bool
            if key.isSimpleString {
                // Fast path: compare raw bytes directly against the key's UTF-8.
                let rawBytes = try key.rawStringBytes
                matches = _jsonRawSpanEqualsUTF8(rawBytes, searchKey)
            } else {
                matches = try key.withUTF8String { keyUTF8 in
                    _jsonRawSpanEqualsUTF8(keyUTF8.span.bytes, searchKey)
                }
            }
            if matches {
                return value
            }
        }
        return nil
    }

    // MARK: - Materialization

    /// Converts this lazy value into a fully-owned `JSONPrimitive`, recursively
    /// materializing all children for collections.
    @usableFromInline
    func materialize() throws(JSONError) -> JSONPrimitive {
        switch kind {
        case .null:
            return .null
        case .bool:
            return .bool(try boolValue)
        case .string:
            return try withUTF8String { utf8Span in
                .string(String(copying: utf8Span))
            }
        case .number:
            let span = try numberBytes
            guard let s = String._tryFromUTF8(span) else {
                throw .cannotConvertEntireInputDataToUTF8
            }
            return .number(.init(extendedPrecisionRepresentation: s))
        case .array:
            var elements: [JSONPrimitive] = []
            var iter = try makeArrayIterator()
            while let element = try iter.next() {
                try elements.append(element.materialize())
            }
            return .array(elements)
        case .object:
            var pairs: [(key: String, value: JSONPrimitive)] = []
            var iter = try makeObjectIterator()
            while let (key, value) = try iter.next() {
                let keyString: String = try key.withUTF8String { utf8Span in
                    String(copying: utf8Span)
                }
                try pairs.append((key: keyString, value: value.materialize()))
            }
            return .dictionary(pairs)
        }
    }
}

