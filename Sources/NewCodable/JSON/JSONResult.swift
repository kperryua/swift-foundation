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

// MARK: - JSONPrescannedResult

/// An ergonomic, subscript-based wrapper around `JSONPrescannedPrimitive` that
/// provides random access to JSON values via string keys and integer indices.
///
/// `JSONPrescannedResult` is an error-propagating monad: subscripts always
/// return a non-optional `JSONPrescannedResult`. If an error occurs (key not
/// found, index out of bounds, type mismatch), it is recorded internally and
/// propagated through subsequent chaining. The caller extracts the value at
/// the end via throwing leaf accessors or the non-throwing `get()`.
///
///     let result = try JSONPrescannedResult.parse(bytes)
///     // Throwing: throws the first error in the chain
///     let name = try result["users"][0]["name"].stringValue
///     // Non-throwing: returns nil if any error occurred
///     let name = result["users"][0]["name"].get()
///     // Error inspection
///     let r = result["missing"]["nested"]
///     if let error = r.error { ... }
///
@usableFromInline
struct JSONPrescannedResult: ~Escapable {

    @usableFromInline let primitive: JSONPrescannedPrimitive?
    @usableFromInline let _error: JSONError?

    @usableFromInline
    @_lifetime(copy primitive)
    init(_ primitive: JSONPrescannedPrimitive) {
        self.primitive = primitive
        self._error = nil
    }

    @usableFromInline
    @_lifetime(copy primitive)
    init(_ primitive: JSONPrescannedPrimitive?, error: JSONError?) {
        self.primitive = primitive
        self._error = error
    }

    // MARK: - Construction

    /// Parses JSON bytes using the prescanned strategy and returns the root result.
    @_lifetime(copy bytes)
    @usableFromInline
    static func parse(_ bytes: RawSpan) throws(JSONError) -> JSONPrescannedResult {
        let primitive = try JSONPrescannedPrimitive.scan(bytes)
        return JSONPrescannedResult(primitive)
    }

    // MARK: - Error Inspection

    /// The recorded error, if any. `nil` when this result holds a valid value.
    @usableFromInline
    var error: JSONError? { _error }

    // MARK: - Value Kind

    /// The JSON value kind, or `nil` if this result is in an error state.
    @usableFromInline
    var kind: JSONValueKind? {
        primitive?.kind
    }

    // MARK: - Subscript Access

    /// Looks up a value by key in a JSON object.
    /// If this result is already in an error state, propagates the error.
    /// If the key is not found, records a `.keyNotFound` error.
    /// If this value is not an object, records the underlying parse error.
    @usableFromInline
    subscript(key: String) -> JSONPrescannedResult {
        @_lifetime(copy self)
        get {
            guard _error == nil, let p = primitive else {
                return JSONPrescannedResult(primitive, error: _error ?? .keyNotFound(key))
            }
            do {
                guard let v = try p.value(forKey: key) else {
                    return JSONPrescannedResult(nil, error: .keyNotFound(key))
                }
                return JSONPrescannedResult(v)
            } catch {
                return JSONPrescannedResult(nil, error: error)
            }
        }
    }

    /// Looks up a value by index in a JSON array.
    /// If this result is already in an error state, propagates the error.
    /// If the index is out of bounds, records an `.indexOutOfBounds` error.
    /// If this value is not an array, records the underlying parse error.
    @usableFromInline
    subscript(index: Int) -> JSONPrescannedResult {
        @_lifetime(copy self)
        get {
            guard _error == nil, let p = primitive else {
                return JSONPrescannedResult(primitive, error: _error ?? .indexOutOfBounds(index))
            }
            guard index >= 0 else {
                return JSONPrescannedResult(nil, error: .indexOutOfBounds(index))
            }
            do {
                var iter = try p.makeArrayIterator()
                var i = 0
                while let element = iter.next() {
                    if i == index {
                        return JSONPrescannedResult(element)
                    }
                    i += 1
                }
                return JSONPrescannedResult(nil, error: .indexOutOfBounds(index))
            } catch {
                return JSONPrescannedResult(nil, error: error)
            }
        }
    }

    // MARK: - Non-Throwing Extraction

    /// Returns the underlying primitive if no error has been recorded, `nil` otherwise.
    @_lifetime(copy self)
    @usableFromInline
    func get() -> JSONPrescannedPrimitive? {
        guard _error == nil else { return nil }
        return primitive
    }

    // MARK: - Leaf Accessors

    /// The string value. Throws any recorded error, then throws on type mismatch.
    @usableFromInline
    var stringValue: String {
        get throws(JSONError) {
            if let e = _error { throw e }
            guard let p = primitive else { throw .unexpectedEndOfFile }
            return try p.withUTF8String { utf8Span in
                String(copying: utf8Span)
            }
        }
    }

    /// The boolean value. Throws any recorded error, then throws on type mismatch.
    @usableFromInline
    var boolValue: Bool {
        get throws(JSONError) {
            if let e = _error { throw e }
            guard let p = primitive else { throw .unexpectedEndOfFile }
            return try p.boolValue
        }
    }

    /// Whether this value is null. Returns `false` if in an error state.
    @usableFromInline
    var isNull: Bool {
        _error == nil && (primitive?.isNull ?? false)
    }

    /// The integer value. Throws any recorded error, then throws on type mismatch
    /// or overflow.
    @usableFromInline
    func intValue<T: FixedWidthInteger>(_ type: T.Type = Int.self) throws(JSONError) -> T {
        if let e = _error { throw e }
        guard let p = primitive else { throw .unexpectedEndOfFile }
        let span = try p.numberBytes
        guard let s = String._tryFromUTF8(span) else {
            throw .cannotConvertEntireInputDataToUTF8
        }
        guard let value = T(s) else {
            throw .numberOverflow(at: .init(byteOffset: 0))
        }
        return value
    }

    /// The floating-point value. Throws any recorded error, then throws on type
    /// mismatch or overflow.
    @usableFromInline
    func doubleValue<T: BinaryFloatingPoint>(_ type: T.Type = Double.self) throws(JSONError) -> T {
        if let e = _error { throw e }
        guard let p = primitive else { throw .unexpectedEndOfFile }
        let span = try p.numberBytes
        guard let s = String._tryFromUTF8(span) else {
            throw .cannotConvertEntireInputDataToUTF8
        }
        if T.self == Double.self {
            guard let value = Double(s) else {
                throw .numberOverflow(at: .init(byteOffset: 0))
            }
            return value as! T
        } else if T.self == Float.self {
            guard let value = Float(s) else {
                throw .numberOverflow(at: .init(byteOffset: 0))
            }
            return value as! T
        }
        guard let value = Double(s) else {
            throw .numberOverflow(at: .init(byteOffset: 0))
        }
        return T(value)
    }

    // MARK: - Materialization

    /// Converts this lazy value into a fully-owned `JSONPrimitive`.
    /// Throws any recorded error first.
    @usableFromInline
    func materialize() throws(JSONError) -> JSONPrimitive {
        if let e = _error { throw e }
        guard let p = primitive else { throw .unexpectedEndOfFile }
        return try p.materialize()
    }

    // MARK: - Collection Count

    /// The number of elements (array) or key-value pairs (object).
    /// Throws any recorded error first.
    @usableFromInline
    var count: Int {
        get throws(JSONError) {
            if let e = _error { throw e }
            guard let p = primitive else { throw .unexpectedEndOfFile }
            return try p.count
        }
    }

    // MARK: - Array Iteration

    /// An iterator over the elements of a JSON array, yielding result wrappers.
    @usableFromInline
    struct ArrayIterator: ~Escapable {
        @usableFromInline var inner: JSONPrescannedPrimitive.ArrayIterator

        @usableFromInline
        @_lifetime(copy inner)
        init(_ inner: JSONPrescannedPrimitive.ArrayIterator) {
            self.inner = inner
        }

        @_lifetime(copy self)
        @usableFromInline
        mutating func next() -> JSONPrescannedResult? {
            guard let element = inner.next() else { return nil }
            return JSONPrescannedResult(element)
        }
    }

    /// Creates an iterator over array elements as result wrappers.
    /// Throws any recorded error first.
    @_lifetime(copy self)
    @usableFromInline
    func makeArrayIterator() throws(JSONError) -> ArrayIterator {
        if let e = _error { throw e }
        guard let p = primitive else { throw .unexpectedEndOfFile }
        return ArrayIterator(try p.makeArrayIterator())
    }

    // MARK: - Object Iteration

    /// An iterator over the key-value pairs of a JSON object, yielding result wrappers.
    @usableFromInline
    struct ObjectIterator: ~Escapable {
        @usableFromInline var inner: JSONPrescannedPrimitive.ObjectIterator

        @usableFromInline
        @_lifetime(copy inner)
        init(_ inner: JSONPrescannedPrimitive.ObjectIterator) {
            self.inner = inner
        }

        @_lifetime(copy self)
        @usableFromInline
        mutating func next() -> (key: JSONPrescannedResult, value: JSONPrescannedResult)? {
            guard let (key, value) = inner.next() else { return nil }
            return (key: JSONPrescannedResult(key), value: JSONPrescannedResult(value))
        }
    }

    /// Creates an iterator over object key-value pairs as result wrappers.
    /// Throws any recorded error first.
    @_lifetime(copy self)
    @usableFromInline
    func makeObjectIterator() throws(JSONError) -> ObjectIterator {
        if let e = _error { throw e }
        guard let p = primitive else { throw .unexpectedEndOfFile }
        return ObjectIterator(try p.makeObjectIterator())
    }
}

// MARK: - JSONStreamingResult

/// An ergonomic, subscript-based wrapper around `JSONStreamingPrimitive` that
/// provides random access to JSON values via string keys and integer indices.
///
/// `JSONStreamingResult` is an error-propagating monad: subscripts always
/// return a non-optional `JSONStreamingResult`. If an error occurs (key not
/// found, index out of bounds, type mismatch), it is recorded internally and
/// propagated through subsequent chaining.
///
///     let result = try JSONStreamingResult.parse(bytes)
///     let name = try result["users"][0]["name"].stringValue
///     let r = result["missing"]
///     if let error = r.error { ... }
///
@usableFromInline
struct JSONStreamingResult: ~Escapable {

    @usableFromInline let primitive: JSONStreamingPrimitive?
    @usableFromInline let _error: JSONError?

    @usableFromInline
    @_lifetime(copy primitive)
    init(_ primitive: JSONStreamingPrimitive) {
        self.primitive = primitive
        self._error = nil
    }

    @usableFromInline
    @_lifetime(copy primitive)
    init(_ primitive: JSONStreamingPrimitive?, error: JSONError?) {
        self.primitive = primitive
        self._error = error
    }

    // MARK: - Construction

    /// Parses JSON bytes using the streaming strategy and returns the root result.
    @_lifetime(copy bytes)
    @usableFromInline
    static func parse(_ bytes: RawSpan) throws(JSONError) -> JSONStreamingResult {
        let primitive = try JSONStreamingPrimitive.from(bytes)
        return JSONStreamingResult(primitive)
    }

    // MARK: - Error Inspection

    /// The recorded error, if any. `nil` when this result holds a valid value.
    @usableFromInline
    var error: JSONError? { _error }

    // MARK: - Value Kind

    /// The JSON value kind, or `nil` if this result is in an error state.
    @usableFromInline
    var kind: JSONValueKind? {
        primitive?.kind
    }

    // MARK: - Subscript Access

    /// Looks up a value by key in a JSON object.
    /// If this result is already in an error state, propagates the error.
    /// If the key is not found, records a `.keyNotFound` error.
    /// If this value is not an object, records the underlying parse error.
    @usableFromInline
    subscript(key: String) -> JSONStreamingResult {
        @_lifetime(copy self)
        get {
            guard _error == nil, let p = primitive else {
                return JSONStreamingResult(primitive, error: _error ?? .keyNotFound(key))
            }
            do {
                guard let v = try p.value(forKey: key) else {
                    return JSONStreamingResult(nil, error: .keyNotFound(key))
                }
                return JSONStreamingResult(v)
            } catch {
                return JSONStreamingResult(nil, error: error)
            }
        }
    }

    /// Looks up a value by index in a JSON array.
    /// If this result is already in an error state, propagates the error.
    /// If the index is out of bounds, records an `.indexOutOfBounds` error.
    /// If this value is not an array, records the underlying parse error.
    @usableFromInline
    subscript(index: Int) -> JSONStreamingResult {
        @_lifetime(copy self)
        get {
            guard _error == nil, let p = primitive else {
                return JSONStreamingResult(primitive, error: _error ?? .indexOutOfBounds(index))
            }
            guard index >= 0 else {
                return JSONStreamingResult(nil, error: .indexOutOfBounds(index))
            }
            do {
                var iter = try p.makeArrayIterator()
                var i = 0
                while let element = try iter.next() {
                    if i == index {
                        return JSONStreamingResult(element)
                    }
                    i += 1
                }
                return JSONStreamingResult(nil, error: .indexOutOfBounds(index))
            } catch {
                return JSONStreamingResult(nil, error: error)
            }
        }
    }

    // MARK: - Non-Throwing Extraction

    /// Returns the underlying primitive if no error has been recorded, `nil` otherwise.
    @_lifetime(copy self)
    @usableFromInline
    func get() -> JSONStreamingPrimitive? {
        guard _error == nil else { return nil }
        return primitive
    }

    // MARK: - Leaf Accessors

    /// The string value. Throws any recorded error, then throws on type mismatch.
    @usableFromInline
    var stringValue: String {
        get throws(JSONError) {
            if let e = _error { throw e }
            guard let p = primitive else { throw .unexpectedEndOfFile }
            return try p.withUTF8String { utf8Span in
                String(copying: utf8Span)
            }
        }
    }

    /// The boolean value. Throws any recorded error, then throws on type mismatch.
    @usableFromInline
    var boolValue: Bool {
        get throws(JSONError) {
            if let e = _error { throw e }
            guard let p = primitive else { throw .unexpectedEndOfFile }
            return try p.boolValue
        }
    }

    /// Whether this value is null. Returns `false` if in an error state.
    @usableFromInline
    var isNull: Bool {
        _error == nil && (primitive?.isNull ?? false)
    }

    /// The integer value. Throws any recorded error, then throws on type mismatch
    /// or overflow.
    @usableFromInline
    func intValue<T: FixedWidthInteger>(_ type: T.Type = Int.self) throws(JSONError) -> T {
        if let e = _error { throw e }
        guard let p = primitive else { throw .unexpectedEndOfFile }
        let span = try p.numberBytes
        guard let s = String._tryFromUTF8(span) else {
            throw .cannotConvertEntireInputDataToUTF8
        }
        guard let value = T(s) else {
            throw .numberOverflow(at: .init(byteOffset: 0))
        }
        return value
    }

    /// The floating-point value. Throws any recorded error, then throws on type
    /// mismatch or overflow.
    @usableFromInline
    func doubleValue<T: BinaryFloatingPoint>(_ type: T.Type = Double.self) throws(JSONError) -> T {
        if let e = _error { throw e }
        guard let p = primitive else { throw .unexpectedEndOfFile }
        let span = try p.numberBytes
        guard let s = String._tryFromUTF8(span) else {
            throw .cannotConvertEntireInputDataToUTF8
        }
        if T.self == Double.self {
            guard let value = Double(s) else {
                throw .numberOverflow(at: .init(byteOffset: 0))
            }
            return value as! T
        } else if T.self == Float.self {
            guard let value = Float(s) else {
                throw .numberOverflow(at: .init(byteOffset: 0))
            }
            return value as! T
        }
        guard let value = Double(s) else {
            throw .numberOverflow(at: .init(byteOffset: 0))
        }
        return T(value)
    }

    // MARK: - Materialization

    /// Converts this lazy value into a fully-owned `JSONPrimitive`.
    /// Throws any recorded error first.
    @usableFromInline
    func materialize() throws(JSONError) -> JSONPrimitive {
        if let e = _error { throw e }
        guard let p = primitive else { throw .unexpectedEndOfFile }
        return try p.materialize()
    }

    // MARK: - Array Iteration

    /// An iterator over the elements of a JSON array, yielding result wrappers.
    @usableFromInline
    struct ArrayIterator: ~Escapable {
        @usableFromInline var inner: JSONStreamingPrimitive.ArrayIterator

        @usableFromInline
        @_lifetime(copy inner)
        init(_ inner: JSONStreamingPrimitive.ArrayIterator) {
            self.inner = inner
        }

        @_lifetime(copy self)
        @usableFromInline
        mutating func next() throws(JSONError) -> JSONStreamingResult? {
            guard let element = try inner.next() else { return nil }
            return JSONStreamingResult(element)
        }
    }

    /// Creates an iterator over array elements as result wrappers.
    /// Throws any recorded error first.
    @_lifetime(copy self)
    @usableFromInline
    func makeArrayIterator() throws(JSONError) -> ArrayIterator {
        if let e = _error { throw e }
        guard let p = primitive else { throw .unexpectedEndOfFile }
        return ArrayIterator(try p.makeArrayIterator())
    }

    // MARK: - Object Iteration

    /// An iterator over the key-value pairs of a JSON object, yielding result wrappers.
    @usableFromInline
    struct ObjectIterator: ~Escapable {
        @usableFromInline var inner: JSONStreamingPrimitive.ObjectIterator

        @usableFromInline
        @_lifetime(copy inner)
        init(_ inner: JSONStreamingPrimitive.ObjectIterator) {
            self.inner = inner
        }

        @_lifetime(copy self)
        @usableFromInline
        mutating func next() throws(JSONError) -> (key: JSONStreamingResult, value: JSONStreamingResult)? {
            guard let (key, value) = try inner.next() else { return nil }
            return (key: JSONStreamingResult(key), value: JSONStreamingResult(value))
        }
    }

    /// Creates an iterator over object key-value pairs as result wrappers.
    /// Throws any recorded error first.
    @_lifetime(copy self)
    @usableFromInline
    func makeObjectIterator() throws(JSONError) -> ObjectIterator {
        if let e = _error { throw e }
        guard let p = primitive else { throw .unexpectedEndOfFile }
        return ObjectIterator(try p.makeObjectIterator())
    }
}
