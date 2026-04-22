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

package import BasicContainers

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
        let offset = JSONStreamingPrimitive._skipWhitespace(in: bytes, from: 0)
        guard offset < bytes.byteCount else {
            throw .unexpectedEndOfFile
        }
        let kind = try JSONStreamingPrimitive._kindOfValue(in: bytes, at: offset)
        switch kind {
        case .bool:
            if bytes._loadByteUnchecked(offset) == UInt8(ascii: "t") {
                try _validateTrue(in: bytes, at: offset)
            } else {
                try _validateFalse(in: bytes, at: offset)
            }
        case .null:
            try _validateNull(in: bytes, at: offset)
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
            let contentEnd = try JSONStreamingPrimitive._findClosingQuote(
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
        if isSimpleString {
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
            try JSONPrescannedPrimitive._processEscapes(from: rawSpan, into: &buffer)
            do {
                let utf8Span = try UTF8Span(validating: buffer.span)
                return try body(utf8Span)
            } catch {
                throw .cannotConvertEntireInputDataToUTF8
            }
        }
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
            let endOffset = JSONStreamingPrimitive._findEndOfNumber(
                in: bytes, from: startOffset
            )
            let span = bytes.extracting(startOffset ..< endOffset)
            try JSONStreamingPrimitive._validateNumber(span, at: startOffset)
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
                try JSONStreamingPrimitive._validateTrue(in: bytes, at: startOffset)
                return true
            } else {
                try JSONStreamingPrimitive._validateFalse(in: bytes, at: startOffset)
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
        try JSONStreamingPrimitive._validateNull(in: bytes, at: startOffset)
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

            var offset = JSONStreamingPrimitive._skipWhitespace(
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

            let kind = try JSONStreamingPrimitive._kindOfValue(in: bytes, at: offset)
            let element = JSONStreamingPrimitive(
                bytes: bytes, startOffset: offset, kind: kind
            )

            // Skip past this value to find the next element
            offset = try JSONStreamingPrimitive._skipValue(in: bytes, from: offset)
            offset = JSONStreamingPrimitive._skipWhitespace(in: bytes, from: offset)

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

            var offset = JSONStreamingPrimitive._skipWhitespace(
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
            offset = try JSONStreamingPrimitive._skipValue(in: bytes, from: offset)
            offset = JSONStreamingPrimitive._skipWhitespace(in: bytes, from: offset)

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
            offset = JSONStreamingPrimitive._skipWhitespace(in: bytes, from: offset)
            guard offset < bytes.byteCount else {
                throw .unexpectedEndOfFile
            }

            let valueKind = try JSONStreamingPrimitive._kindOfValue(in: bytes, at: offset)
            let value = JSONStreamingPrimitive(
                bytes: bytes, startOffset: offset, kind: valueKind
            )

            // Skip past value
            offset = try JSONStreamingPrimitive._skipValue(in: bytes, from: offset)
            offset = JSONStreamingPrimitive._skipWhitespace(in: bytes, from: offset)

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
                matches = JSONStreamingPrimitive._rawSpanEqualsUTF8(rawBytes, searchKey)
            } else {
                matches = try key.withUTF8String { keyUTF8 in
                    JSONStreamingPrimitive._rawSpanEqualsUTF8(keyUTF8.span.bytes, searchKey)
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

// MARK: - Internal helpers

extension JSONStreamingPrimitive {

    /// Determines the JSON value kind from the byte at the given offset.
    @usableFromInline
    static func _kindOfValue(
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

    /// Skips whitespace and returns the offset of the first non-whitespace byte.
    @usableFromInline
    static func _skipWhitespace(in bytes: RawSpan, from offset: Int) -> Int {
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

    /// Finds the offset of the closing quote for a string starting at
    /// `contentStart` (the byte after the opening quote).
    @usableFromInline
    static func _findClosingQuote(
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

    /// Finds the end offset of a number starting at `offset`.
    @usableFromInline
    static func _findEndOfNumber(in bytes: RawSpan, from offset: Int) -> Int {
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

    /// Skips past the JSON value at `offset`, returning the offset just after it.
    /// This handles nested structures by tracking bracket/brace depth.
    @usableFromInline
    static func _skipValue(
        in bytes: RawSpan, from offset: Int
    ) throws(JSONError) -> Int {
        guard offset < bytes.byteCount else {
            throw .unexpectedEndOfFile
        }
        let byte = bytes._loadByteUnchecked(offset)
        switch byte {
        case ._quote:
            // String: skip to closing quote
            let contentEnd = try _findClosingQuote(in: bytes, from: offset + 1)
            return contentEnd + 1 // past closing quote

        case ._openbracket:
            // Array: skip all elements
            return try _skipCollection(
                in: bytes, from: offset + 1,
                closeDelimiter: ._closebracket
            )

        case ._openbrace:
            // Object: skip all key-value pairs
            return try _skipCollection(
                in: bytes, from: offset + 1,
                closeDelimiter: ._closebrace
            )

        case UInt8(ascii: "t"):
            try _validateTrue(in: bytes, at: offset)
            return offset + 4

        case UInt8(ascii: "f"):
            try _validateFalse(in: bytes, at: offset)
            return offset + 5

        case UInt8(ascii: "n"):
            try _validateNull(in: bytes, at: offset)
            return offset + 4

        case ._minus, _asciiNumbers:
            return _findEndOfNumber(in: bytes, from: offset)

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
    static func _skipCollection(
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
                i = try _findClosingQuote(in: bytes, from: i) + 1
            default:
                i &+= 1
            }
        }
        guard depth == 0 else {
            throw .unexpectedEndOfFile
        }
        return i
    }

    /// Validates that the bytes at `offset` spell out `true`.
    @usableFromInline
    static func _validateTrue(
        in bytes: RawSpan, at offset: Int
    ) throws(JSONError) {
        guard offset + 4 <= bytes.byteCount,
              bytes._loadByteUnchecked(offset) == UInt8(ascii: "t"),
              bytes._loadByteUnchecked(offset + 1) == UInt8(ascii: "r"),
              bytes._loadByteUnchecked(offset + 2) == UInt8(ascii: "u"),
              bytes._loadByteUnchecked(offset + 3) == UInt8(ascii: "e") else {
            throw .invalidSpecialValue(
                expected: "true",
                location: .init(byteOffset: offset)
            )
        }
    }

    /// Validates that the bytes at `offset` spell out `false`.
    @usableFromInline
    static func _validateFalse(
        in bytes: RawSpan, at offset: Int
    ) throws(JSONError) {
        guard offset + 5 <= bytes.byteCount,
              bytes._loadByteUnchecked(offset) == UInt8(ascii: "f"),
              bytes._loadByteUnchecked(offset + 1) == UInt8(ascii: "a"),
              bytes._loadByteUnchecked(offset + 2) == UInt8(ascii: "l"),
              bytes._loadByteUnchecked(offset + 3) == UInt8(ascii: "s"),
              bytes._loadByteUnchecked(offset + 4) == UInt8(ascii: "e") else {
            throw .invalidSpecialValue(
                expected: "false",
                location: .init(byteOffset: offset)
            )
        }
    }

    /// Validates that the bytes at `offset` spell out `null`.
    @usableFromInline
    static func _validateNull(
        in bytes: RawSpan, at offset: Int
    ) throws(JSONError) {
        guard offset + 4 <= bytes.byteCount,
              bytes._loadByteUnchecked(offset) == UInt8(ascii: "n"),
              bytes._loadByteUnchecked(offset + 1) == UInt8(ascii: "u"),
              bytes._loadByteUnchecked(offset + 2) == UInt8(ascii: "l"),
              bytes._loadByteUnchecked(offset + 3) == UInt8(ascii: "l") else {
            throw .invalidSpecialValue(
                expected: "null",
                location: .init(byteOffset: offset)
            )
        }
    }

    /// Validates that the bytes in `span` form a well-formed JSON number per
    /// RFC 8259: `[ minus ] int [ frac ] [ exp ]` where
    /// `int = "0" / digit1-9 *DIGIT`, `frac = "." 1*DIGIT`, `exp = e [+-] 1*DIGIT`.
    @usableFromInline
    static func _validateNumber(
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

    /// Compares a `RawSpan` of UTF-8 bytes against a `String` for equality.
    @usableFromInline
    static func _rawSpanEqualsUTF8(_ span: RawSpan, _ string: String) -> Bool {
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
}
