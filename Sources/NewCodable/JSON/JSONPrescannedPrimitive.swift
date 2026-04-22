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

// MARK: - JSONValueKind

/// The kind of a JSON value, shared between lazy primitive representations.
@usableFromInline
enum JSONValueKind {
    case string
    case number
    case bool
    case null
    case array
    case object
}

// MARK: - JSONPrescannedPrimitive

/// A reference-counted wrapper around `UniqueArray<Int>` so that multiple
/// `JSONPrescannedPrimitive` values (parent, children, iterators) can share
/// the same map without copying.
@usableFromInline
final class _MapBuffer: @unchecked Sendable {
    let storage: UniqueArray<Int>

    init(consuming storage: consuming UniqueArray<Int>) {
        self.storage = storage
    }

    @inline(__always)
    @usableFromInline
    subscript(position: Int) -> Int { storage[position] }

    @usableFromInline
    var count: Int { storage.count }
}

/// A lazy, non-escaping representation of a JSON value backed by a pre-scanned
/// map of the document structure.
///
/// This type does a full initial scan pass over the input JSON bytes, producing
/// an `[Int]` map buffer (similar to Foundation's `JSONMap`) that records the
/// type and location of every value. Actual string/number parsing is deferred
/// until you access leaf values.
///
/// `JSONPrescannedPrimitive` is `Copyable` (it just wraps offsets and a
/// reference-counted map buffer) but `~Escapable` (its lifetime is tied to the
/// input `RawSpan`).
@usableFromInline
struct JSONPrescannedPrimitive: ~Escapable {

    // MARK: Map format
    //
    // The map is an [Int] array encoding JSON structure:
    //
    //   string/simpleString:   [marker, byteCount, sourceByteOffset]
    //   number/numberWithExp:  [marker, byteCount, sourceByteOffset]
    //   null/true/false:       [marker]
    //   object:                [marker, nextSiblingOffset, pairCount, <keys & values>..., collectionEnd]
    //   array:                 [marker, nextSiblingOffset, elementCount, <values>..., collectionEnd]
    //
    // `sourceByteOffset` refers to the input RawSpan.
    // `nextSiblingOffset` is the map index after the collection.

    @usableFromInline
    enum TypeDescriptor: Int {
        case string = 0
        case number = 1
        case null = 2
        case `true` = 3
        case `false` = 4
        case object = 5
        case array = 6
        case collectionEnd = 7
        case simpleString = 8          // no escape sequences
        case numberContainingExponent = 9
    }

    // MARK: Stored properties

    @usableFromInline let bytes: RawSpan
    @usableFromInline let mapBuffer: _MapBuffer
    @usableFromInline let mapOffset: Int

    @usableFromInline
    @_lifetime(copy bytes)
    init(bytes: RawSpan, mapBuffer: _MapBuffer, mapOffset: Int) {
        self.bytes = bytes
        self.mapBuffer = mapBuffer
        self.mapOffset = mapOffset
    }

    // MARK: - Value Kind

    @usableFromInline
    var kind: JSONValueKind {
        let marker = mapBuffer[mapOffset]
        switch TypeDescriptor(rawValue: marker)! {
        case .string, .simpleString: return .string
        case .number, .numberContainingExponent: return .number
        case .null: return .null
        case .true, .false: return .bool
        case .object: return .object
        case .array: return .array
        case .collectionEnd:
            fatalError("Internal error: JSONPrescannedPrimitive pointing at collectionEnd")
        }
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
            let marker = mapBuffer[mapOffset]
            guard let td = TypeDescriptor(rawValue: marker),
                  td == .string || td == .simpleString else {
                throw .unexpectedCharacter(
                    context: "expected string",
                    ascii: bytes._loadByteUnchecked(mapBuffer[mapOffset + 2]),
                    location: .init(byteOffset: mapBuffer[mapOffset + 2])
                )
            }
            let count = mapBuffer[mapOffset + 1]
            let offset = mapBuffer[mapOffset + 2]
            return bytes.extracting(offset ..< offset + count)
        }
    }

    /// Whether this string value contains no escape sequences and can be
    /// interpreted directly as UTF-8.
    @usableFromInline
    var isSimpleString: Bool {
        TypeDescriptor(rawValue: mapBuffer[mapOffset]) == .simpleString
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
            let marker = mapBuffer[mapOffset]
            guard let td = TypeDescriptor(rawValue: marker),
                  td == .number || td == .numberContainingExponent else {
                throw .unexpectedCharacter(
                    context: "expected number",
                    ascii: bytes._loadByteUnchecked(mapBuffer[mapOffset + 2]),
                    location: .init(byteOffset: mapBuffer[mapOffset + 2])
                )
            }
            let count = mapBuffer[mapOffset + 1]
            let offset = mapBuffer[mapOffset + 2]
            let span = bytes.extracting(offset ..< offset + count)
            try _jsonValidateNumber(span, at: offset)
            return span
        }
    }

    /// The boolean value if this is a `true` or `false` literal.
    @usableFromInline
    var boolValue: Bool {
        get throws(JSONError) {
            let marker = mapBuffer[mapOffset]
            switch TypeDescriptor(rawValue: marker) {
            case .true: return true
            case .false: return false
            default:
                throw .unexpectedEndOfFile
            }
        }
    }

    /// Whether this value is a JSON `null`.
    @usableFromInline
    var isNull: Bool {
        TypeDescriptor(rawValue: mapBuffer[mapOffset]) == .null
    }

    // MARK: - Collection Accessors

    /// The number of elements in an array, or key-value pairs in an object.
    @usableFromInline
    var count: Int {
        get throws(JSONError) {
            let marker = mapBuffer[mapOffset]
            guard let td = TypeDescriptor(rawValue: marker),
                  td == .array || td == .object else {
                throw .unexpectedEndOfFile
            }
            return mapBuffer[mapOffset + 2]
        }
    }

    // MARK: - Array Iteration

    /// An iterator over the elements of a JSON array.
    @usableFromInline
    struct ArrayIterator: ~Escapable {
        @usableFromInline let bytes: RawSpan
        @usableFromInline let mapBuffer: _MapBuffer
        @usableFromInline var currentOffset: Int

        @usableFromInline
        @_lifetime(copy bytes)
        init(bytes: RawSpan, mapBuffer: _MapBuffer, firstElementOffset: Int) {
            self.bytes = bytes
            self.mapBuffer = mapBuffer
            self.currentOffset = firstElementOffset
        }

        /// Returns the next element, or `nil` when iteration is complete.
        @_lifetime(copy self)
        @usableFromInline
        mutating func next() -> JSONPrescannedPrimitive? {
            guard TypeDescriptor(rawValue: mapBuffer[currentOffset]) != .collectionEnd else {
                return nil
            }
            let value = JSONPrescannedPrimitive(
                bytes: bytes, mapBuffer: mapBuffer, mapOffset: currentOffset
            )
            currentOffset = JSONPrescannedPrimitive._offsetAfter(
                mapOffset: currentOffset, in: mapBuffer
            )
            return value
        }
    }

    /// Creates an iterator over array elements. Throws if this value is not an array.
    @_lifetime(copy self)
    @usableFromInline
    func makeArrayIterator() throws(JSONError) -> ArrayIterator {
        let marker = mapBuffer[mapOffset]
        guard TypeDescriptor(rawValue: marker) == .array else {
            throw .unexpectedEndOfFile
        }
        return ArrayIterator(
            bytes: bytes,
            mapBuffer: mapBuffer,
            firstElementOffset: mapOffset + 3
        )
    }

    // MARK: - Object Iteration

    /// An iterator over the key-value pairs of a JSON object.
    @usableFromInline
    struct ObjectIterator: ~Escapable {
        @usableFromInline let bytes: RawSpan
        @usableFromInline let mapBuffer: _MapBuffer
        @usableFromInline var currentOffset: Int

        @usableFromInline
        @_lifetime(copy bytes)
        init(bytes: RawSpan, mapBuffer: _MapBuffer, firstKeyOffset: Int) {
            self.bytes = bytes
            self.mapBuffer = mapBuffer
            self.currentOffset = firstKeyOffset
        }

        /// Returns the next (key, value) pair, or `nil` when iteration is complete.
        @_lifetime(copy self)
        @usableFromInline
        mutating func next() -> (
            key: JSONPrescannedPrimitive, value: JSONPrescannedPrimitive
        )? {
            guard TypeDescriptor(rawValue: mapBuffer[currentOffset]) != .collectionEnd else {
                return nil
            }
            let key = JSONPrescannedPrimitive(
                bytes: bytes, mapBuffer: mapBuffer, mapOffset: currentOffset
            )
            let valueOffset = JSONPrescannedPrimitive._offsetAfter(
                mapOffset: currentOffset, in: mapBuffer
            )
            let value = JSONPrescannedPrimitive(
                bytes: bytes, mapBuffer: mapBuffer, mapOffset: valueOffset
            )
            currentOffset = JSONPrescannedPrimitive._offsetAfter(
                mapOffset: valueOffset, in: mapBuffer
            )
            return (key, value)
        }
    }

    /// Creates an iterator over object key-value pairs. Throws if not an object.
    @_lifetime(copy self)
    @usableFromInline
    func makeObjectIterator() throws(JSONError) -> ObjectIterator {
        let marker = mapBuffer[mapOffset]
        guard TypeDescriptor(rawValue: marker) == .object else {
            throw .unexpectedEndOfFile
        }
        return ObjectIterator(
            bytes: bytes,
            mapBuffer: mapBuffer,
            firstKeyOffset: mapOffset + 3
        )
    }

    // MARK: - Key Lookup

    /// Returns the value for the given key in a JSON object, or `nil` if the
    /// key is not found. This is an O(n) linear scan each time it is called.
    /// Throws if this value is not an object.
    @_lifetime(copy self)
    @usableFromInline
    func value(forKey searchKey: String) throws(JSONError) -> JSONPrescannedPrimitive? {
        var iter = try makeObjectIterator()
        while let (key, value) = iter.next() {
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
            while let element = iter.next() {
                try elements.append(element.materialize())
            }
            return .array(elements)
        case .object:
            var pairs: [(key: String, value: JSONPrimitive)] = []
            var iter = try makeObjectIterator()
            while let (key, value) = iter.next() {
                let keyString: String = try key.withUTF8String { utf8Span in
                    String(copying: utf8Span)
                }
                try pairs.append((key: keyString, value: value.materialize()))
            }
            return .dictionary(pairs)
        }
    }

    // MARK: - Map Navigation

    /// Returns the map offset of the value after the one at `mapOffset`.
    @usableFromInline
    static func _offsetAfter(mapOffset: Int, in mapBuffer: _MapBuffer) -> Int {
        let marker = mapBuffer[mapOffset]
        switch TypeDescriptor(rawValue: marker)! {
        case .string, .simpleString, .number, .numberContainingExponent:
            return mapOffset + 3
        case .null, .true, .false:
            return mapOffset + 1
        case .object, .array:
            return mapBuffer[mapOffset + 1] // nextSiblingOffset
        case .collectionEnd:
            fatalError("Cannot advance past collectionEnd marker")
        }
    }

}

// MARK: - Scanner

extension JSONPrescannedPrimitive {

    /// Scans the given JSON bytes and produces a `JSONPrescannedPrimitive`
    /// representing the root value.
    @_lifetime(copy bytes)
    @usableFromInline
    static func scan(_ bytes: RawSpan) throws(JSONError) -> JSONPrescannedPrimitive {
        var scanner = MapScanner(bytes: bytes)
        try scanner.scanValue()
        let buffer = _MapBuffer(consuming: scanner.map)
        return JSONPrescannedPrimitive(
            bytes: bytes,
            mapBuffer: buffer,
            mapOffset: 0
        )
    }

    /// A lightweight scanner that produces a `UniqueArray<Int>` map buffer from raw JSON bytes.
    @usableFromInline
    struct MapScanner: ~Escapable, ~Copyable {
        var map: UniqueArray<Int> = .init()
        @usableFromInline let bytes: RawSpan
        @usableFromInline var readOffset: Int = 0
        @usableFromInline var depth: Int = 0

        @usableFromInline
        @_lifetime(copy bytes)
        init(bytes: RawSpan) {
            self.bytes = bytes
        }

        @usableFromInline
        var isEOF: Bool { readOffset >= bytes.byteCount }

        // MARK: Peeking & reading

        @inline(__always)
        @usableFromInline
        func peek() -> UInt8? {
            guard readOffset < bytes.byteCount else { return nil }
            return bytes._loadByteUnchecked(readOffset)
        }

        @inline(__always)
        @usableFromInline
        mutating func advance(_ n: Int = 1) {
            readOffset &+= n
        }

        @inline(__always)
        @usableFromInline
        mutating func read() -> UInt8? {
            guard readOffset < bytes.byteCount else { return nil }
            defer { readOffset &+= 1 }
            return bytes._loadByteUnchecked(readOffset)
        }

        // MARK: Whitespace

        @usableFromInline
        mutating func skipWhitespace() {
            while readOffset < bytes.byteCount {
                switch bytes._loadByteUnchecked(readOffset) {
                case ._space, ._tab, ._newline, ._return:
                    readOffset &+= 1
                default:
                    return
                }
            }
        }

        @usableFromInline
        @_lifetime(self: copy self)
        mutating func consumeWhitespaceAndPeek() throws(JSONError) -> UInt8 {
            skipWhitespace()
            guard let byte = peek() else {
                throw .unexpectedEndOfFile
            }
            return byte
        }

        // MARK: Value scanning

        @usableFromInline
        @_lifetime(self: copy self)
        mutating func scanValue() throws(JSONError) {
            let byte = try consumeWhitespaceAndPeek()
            switch byte {
            case ._quote:
                try scanString()
            case ._openbrace:
                try scanObject()
            case ._openbracket:
                try scanArray()
            case UInt8(ascii: "t"):
                try scanTrue()
            case UInt8(ascii: "f"):
                try scanFalse()
            case UInt8(ascii: "n"):
                try scanNull()
            case ._minus, _asciiNumbers:
                scanNumber()
            default:
                throw .unexpectedCharacter(
                    ascii: byte,
                    location: .init(byteOffset: readOffset)
                )
            }
        }

        // MARK: Strings

        @usableFromInline
        @_lifetime(self: copy self)
        mutating func scanString() throws(JSONError) {
            advance() // consume opening quote
            let contentStart = readOffset
            var isSimple = true

            while readOffset < bytes.byteCount {
                let byte = bytes._loadByteUnchecked(readOffset)
                switch byte {
                case ._quote:
                    let count = readOffset - contentStart
                    map.append((isSimple ? TypeDescriptor.simpleString : .string).rawValue)
                    map.append(count)
                    map.append(contentStart)
                    advance() // consume closing quote
                    return
                case ._backslash:
                    isSimple = false
                    advance() // consume backslash
                    guard !isEOF else { throw .unexpectedEndOfFile }
                    advance() // consume escaped character
                default:
                    if byte < 0x20 {
                        throw .unescapedControlCharacterInString(
                            ascii: byte,
                            location: .init(byteOffset: readOffset)
                        )
                    }
                    advance()
                }
            }
            throw .unexpectedEndOfFile
        }

        // MARK: Numbers

        @usableFromInline
        @_lifetime(self: copy self)
        mutating func scanNumber() {
            let start = readOffset
            var containsExponent = false

            // Optional leading minus
            if peek() == ._minus { advance() }

            // Digits
            while readOffset < bytes.byteCount {
                let byte = bytes._loadByteUnchecked(readOffset)
                switch byte {
                case _asciiNumbers:
                    advance()
                case ._period:
                    advance()
                case ._e, ._E:
                    containsExponent = true
                    advance()
                    // Optional sign after exponent
                    if let next = peek(), next == ._plus || next == ._minus {
                        advance()
                    }
                default:
                    // End of number
                    let count = readOffset - start
                    let td: TypeDescriptor = containsExponent ? .numberContainingExponent : .number
                    map.append(td.rawValue)
                    map.append(count)
                    map.append(start)
                    return
                }
            }

            // Number at end of input
            let count = readOffset - start
            let td: TypeDescriptor = containsExponent ? .numberContainingExponent : .number
            map.append(td.rawValue)
            map.append(count)
            map.append(start)
        }

        // MARK: Literals

        @usableFromInline
        @_lifetime(self: copy self)
        mutating func scanTrue() throws(JSONError) {
            guard readOffset + 4 <= bytes.byteCount else {
                throw .unexpectedEndOfFile
            }
            // Verify "true"
            guard bytes._loadByteUnchecked(readOffset) == UInt8(ascii: "t"),
                  bytes._loadByteUnchecked(readOffset + 1) == UInt8(ascii: "r"),
                  bytes._loadByteUnchecked(readOffset + 2) == UInt8(ascii: "u"),
                  bytes._loadByteUnchecked(readOffset + 3) == UInt8(ascii: "e") else {
                throw .invalidSpecialValue(
                    expected: "true",
                    location: .init(byteOffset: readOffset)
                )
            }
            map.append(TypeDescriptor.true.rawValue)
            advance(4)
        }

        @usableFromInline
        @_lifetime(self: copy self)
        mutating func scanFalse() throws(JSONError) {
            guard readOffset + 5 <= bytes.byteCount else {
                throw .unexpectedEndOfFile
            }
            guard bytes._loadByteUnchecked(readOffset) == UInt8(ascii: "f"),
                  bytes._loadByteUnchecked(readOffset + 1) == UInt8(ascii: "a"),
                  bytes._loadByteUnchecked(readOffset + 2) == UInt8(ascii: "l"),
                  bytes._loadByteUnchecked(readOffset + 3) == UInt8(ascii: "s"),
                  bytes._loadByteUnchecked(readOffset + 4) == UInt8(ascii: "e") else {
                throw .invalidSpecialValue(
                    expected: "false",
                    location: .init(byteOffset: readOffset)
                )
            }
            map.append(TypeDescriptor.false.rawValue)
            advance(5)
        }

        @usableFromInline
        @_lifetime(self: copy self)
        mutating func scanNull() throws(JSONError) {
            guard readOffset + 4 <= bytes.byteCount else {
                throw .unexpectedEndOfFile
            }
            guard bytes._loadByteUnchecked(readOffset) == UInt8(ascii: "n"),
                  bytes._loadByteUnchecked(readOffset + 1) == UInt8(ascii: "u"),
                  bytes._loadByteUnchecked(readOffset + 2) == UInt8(ascii: "l"),
                  bytes._loadByteUnchecked(readOffset + 3) == UInt8(ascii: "l") else {
                throw .invalidSpecialValue(
                    expected: "null",
                    location: .init(byteOffset: readOffset)
                )
            }
            map.append(TypeDescriptor.null.rawValue)
            advance(4)
        }

        // MARK: Arrays

        @usableFromInline
        @_lifetime(self: copy self)
        mutating func scanArray() throws(JSONError) {
            depth += 1
            guard depth <= 512 else {
                throw .tooManyNestedArraysOrDictionaries(
                    location: .init(byteOffset: readOffset)
                )
            }

            advance() // consume '['

            let headerOffset = map.count
            map.append(TypeDescriptor.array.rawValue)
            map.append(0) // placeholder for nextSiblingOffset
            map.append(0) // placeholder for count

            var elementCount = 0
            var byte = try consumeWhitespaceAndPeek()

            if byte != ._closebracket {
                outerLoop: while true {
                    try scanValue()
                    elementCount += 1

                    byte = try consumeWhitespaceAndPeek()
                    switch byte {
                    case ._comma:
                        advance()
                    case ._closebracket:
                        break outerLoop
                    default:
                        throw .unexpectedCharacter(
                            context: "in array",
                            ascii: byte,
                            location: .init(byteOffset: readOffset)
                        )
                    }
                }
            }

            advance() // consume ']'
            map.append(TypeDescriptor.collectionEnd.rawValue)

            // Backpatch header
            map[headerOffset + 1] = map.count // nextSiblingOffset
            map[headerOffset + 2] = elementCount

            depth -= 1
        }

        // MARK: Objects

        @usableFromInline
        @_lifetime(self: copy self)
        mutating func scanObject() throws(JSONError) {
            depth += 1
            guard depth <= 512 else {
                throw .tooManyNestedArraysOrDictionaries(
                    location: .init(byteOffset: readOffset)
                )
            }

            advance() // consume '{'

            let headerOffset = map.count
            map.append(TypeDescriptor.object.rawValue)
            map.append(0) // placeholder for nextSiblingOffset
            map.append(0) // placeholder for pair count

            var pairCount = 0
            var byte = try consumeWhitespaceAndPeek()

            if byte != ._closebrace {
                outerLoop: while true {
                    // Key must be a string
                    guard try consumeWhitespaceAndPeek() == ._quote else {
                        throw .unexpectedCharacter(
                            context: "at beginning of object key",
                            ascii: try consumeWhitespaceAndPeek(),
                            location: .init(byteOffset: readOffset)
                        )
                    }
                    try scanString()

                    // Colon
                    byte = try consumeWhitespaceAndPeek()
                    guard byte == ._colon else {
                        throw .unexpectedCharacter(
                            context: "after object key",
                            ascii: byte,
                            location: .init(byteOffset: readOffset)
                        )
                    }
                    advance()

                    // Value
                    try scanValue()
                    pairCount += 1

                    byte = try consumeWhitespaceAndPeek()
                    switch byte {
                    case ._comma:
                        advance()
                    case ._closebrace:
                        break outerLoop
                    default:
                        throw .unexpectedCharacter(
                            context: "in object",
                            ascii: byte,
                            location: .init(byteOffset: readOffset)
                        )
                    }
                }
            }

            advance() // consume '}'
            map.append(TypeDescriptor.collectionEnd.rawValue)

            // Backpatch header
            map[headerOffset + 1] = map.count // nextSiblingOffset
            map[headerOffset + 2] = pairCount

            depth -= 1
        }
    }
}
