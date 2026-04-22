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

import Testing
@testable import NewCodable

#if canImport(FoundationEssentials)
import FoundationEssentials
#elseif FOUNDATION_FRAMEWORK
import Foundation
#endif

// MARK: - Test Helpers

/// Calls `body` with a `RawSpan` backed by the UTF-8 bytes of `json`.
private func withRawSpan<T>(
    of json: String,
    _ body: (RawSpan) throws -> T
) rethrows -> T {
    var utf8 = Array(json.utf8)
    return try utf8.withUnsafeMutableBytes { buffer in
        let typed = buffer.assumingMemoryBound(to: UInt8.self)
        return try body(RawSpan(_unsafeElements: typed))
    }
}

/// Creates a streaming primitive from the given JSON string, calls `body`
/// with it, and returns the result.
@discardableResult
private func withStreamingPrimitive<T>(
    _ json: String,
    _ body: (JSONStreamingPrimitive) throws -> T
) throws -> T {
    try withRawSpan(of: json) { bytes in
        let prim = try JSONStreamingPrimitive.from(bytes)
        return try body(prim)
    }
}

/// Creates a prescanned primitive from the given JSON string, calls `body`
/// with it, and returns the result.
@discardableResult
private func withPrescannedPrimitive<T>(
    _ json: String,
    _ body: (JSONPrescannedPrimitive) throws -> T
) throws -> T {
    try withRawSpan(of: json) { bytes in
        let prim = try JSONPrescannedPrimitive.scan(bytes)
        return try body(prim)
    }
}

// MARK: - Number Validation Tests

@Suite("JSON Number Validation")
struct JSONNumberValidationTests {

    // MARK: Valid Numbers

    @Test("Valid integer")
    func validInteger() throws {
        try withStreamingPrimitive("42") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "42")))
        }
        try withPrescannedPrimitive("42") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "42")))
        }
    }

    @Test("Valid zero")
    func validZero() throws {
        try withStreamingPrimitive("0") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "0")))
        }
        try withPrescannedPrimitive("0") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "0")))
        }
    }

    @Test("Valid negative integer")
    func validNegativeInteger() throws {
        try withStreamingPrimitive("-123") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "-123")))
        }
        try withPrescannedPrimitive("-123") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "-123")))
        }
    }

    @Test("Valid negative zero")
    func validNegativeZero() throws {
        try withStreamingPrimitive("-0") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "-0")))
        }
    }

    @Test("Valid decimal")
    func validDecimal() throws {
        try withStreamingPrimitive("3.14") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "3.14")))
        }
        try withPrescannedPrimitive("3.14") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "3.14")))
        }
    }

    @Test("Valid number with exponent")
    func validExponent() throws {
        try withStreamingPrimitive("1e10") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "1e10")))
        }
        try withPrescannedPrimitive("1e10") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "1e10")))
        }
    }

    @Test("Valid number with positive exponent sign")
    func validPositiveExponent() throws {
        try withStreamingPrimitive("1E+10") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "1E+10")))
        }
    }

    @Test("Valid number with negative exponent")
    func validNegativeExponent() throws {
        try withStreamingPrimitive("1e-5") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "1e-5")))
        }
    }

    @Test("Valid decimal with exponent")
    func validDecimalExponent() throws {
        try withStreamingPrimitive("1.5e10") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "1.5e10")))
        }
    }

    @Test("Valid negative decimal with exponent")
    func validNegativeDecimalExponent() throws {
        try withStreamingPrimitive("-3.14e-2") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "-3.14e-2")))
        }
    }

    @Test("Valid zero with decimal")
    func validZeroDecimal() throws {
        try withStreamingPrimitive("0.5") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "0.5")))
        }
    }

    @Test("Valid large number")
    func validLargeNumber() throws {
        try withStreamingPrimitive("1234567890.000000000000000001e9999999999999999") { prim in
            let materialized = try prim.materialize()
            #expect(materialized == .number(.init(extendedPrecisionRepresentation: "1234567890.000000000000000001e9999999999999999")))
        }
    }

    // MARK: Invalid Numbers

    @Test("Leading zero followed by digit")
    func leadingZero() throws {
        try withStreamingPrimitive("01") { prim in
            #expect(throws: JSONError.self) {
                _ = try prim.numberBytes
            }
        }
        try withPrescannedPrimitive("01") { prim in
            #expect(throws: JSONError.self) {
                _ = try prim.numberBytes
            }
        }
    }

    @Test("Negative leading zero followed by digit")
    func negativeLeadingZero() throws {
        try withStreamingPrimitive("-01") { prim in
            #expect(throws: JSONError.self) {
                _ = try prim.numberBytes
            }
        }
    }

    @Test("Trailing dot with no fraction digits")
    func trailingDot() throws {
        try withStreamingPrimitive("[1.]") { prim in
            var iter = try prim.makeArrayIterator()
            while let element = try iter.next() {
                #expect(throws: JSONError.self) {
                    _ = try element.numberBytes
                }
            }
        }
        try withPrescannedPrimitive("[1.]") { prim in
            var iter = try prim.makeArrayIterator()
            while let element = iter.next() {
                #expect(throws: JSONError.self) {
                    _ = try element.numberBytes
                }
            }
        }
    }

    @Test("Exponent with no digits")
    func exponentNoDigits() throws {
        try withStreamingPrimitive("[1e]") { prim in
            var iter = try prim.makeArrayIterator()
            while let element = try iter.next() {
                #expect(throws: JSONError.self) {
                    _ = try element.numberBytes
                }
            }
        }
        try withPrescannedPrimitive("[1e]") { prim in
            var iter = try prim.makeArrayIterator()
            while let element = iter.next() {
                #expect(throws: JSONError.self) {
                    _ = try element.numberBytes
                }
            }
        }
    }

    @Test("Exponent sign with no digits")
    func exponentSignNoDigits() throws {
        try withStreamingPrimitive("[1e+]") { prim in
            var iter = try prim.makeArrayIterator()
            while let element = try iter.next() {
                #expect(throws: JSONError.self) {
                    _ = try element.numberBytes
                }
            }
        }
    }

    @Test("Double decimal points")
    func doubleDecimal() throws {
        try withStreamingPrimitive("[1.2.3]") { prim in
            var iter = try prim.makeArrayIterator()
            while let element = try iter.next() {
                #expect(throws: JSONError.self) {
                    _ = try element.numberBytes
                }
            }
        }
    }

    @Test("Bare minus")
    func bareMinus() throws {
        // The streaming type creates a .number kind for '-', but validation
        // fails when accessing numberBytes.
        try withStreamingPrimitive("-") { prim in
            let k = prim.kind
            #expect(k == .number)
            #expect(throws: JSONError.self) {
                _ = try prim.numberBytes
            }
        }
    }
}

// MARK: - Bool/Null Validation Tests

@Suite("JSON Literal Validation")
struct JSONLiteralValidationTests {

    @Test("Valid true")
    func validTrue() throws {
        try withStreamingPrimitive("true") { prim in
            let val = try prim.boolValue
            #expect(val == true)
        }
        try withPrescannedPrimitive("true") { prim in
            let val = try prim.boolValue
            #expect(val == true)
        }
    }

    @Test("Valid false")
    func validFalse() throws {
        try withStreamingPrimitive("false") { prim in
            let val = try prim.boolValue
            #expect(val == false)
        }
        try withPrescannedPrimitive("false") { prim in
            let val = try prim.boolValue
            #expect(val == false)
        }
    }

    @Test("Valid null")
    func validNull() throws {
        try withStreamingPrimitive("null") { prim in
            let isNullVal = prim.isNull
            #expect(isNullVal)
            try prim.validateNull()
        }
        try withPrescannedPrimitive("null") { prim in
            let isNullVal = prim.isNull
            #expect(isNullVal)
        }
    }

    @Test("Invalid true literal is caught at construction")
    func invalidTrue() throws {
        #expect(throws: JSONError.self) {
            try withStreamingPrimitive("tru ") { _ in }
        }
    }

    @Test("Invalid false literal is caught at construction")
    func invalidFalse() throws {
        #expect(throws: JSONError.self) {
            try withStreamingPrimitive("fals ") { _ in }
        }
    }

    @Test("Invalid null literal is caught at construction")
    func invalidNull() throws {
        #expect(throws: JSONError.self) {
            try withStreamingPrimitive("nulx") { _ in }
        }
    }
}

// MARK: - Key Lookup Tests

@Suite("JSON Key Lookup")
struct JSONKeyLookupTests {

    @Test("Find existing key")
    func findExistingKey() throws {
        let json = #"{"name":"Alice","age":30}"#
        // Use object iteration to find the key, avoiding guard/Issue.record on ~Escapable
        try withStreamingPrimitive(json) { prim in
            var iter = try prim.makeObjectIterator()
            var found = false
            while let (key, value) = try iter.next() {
                let keyStr: String = try key.withUTF8String { String(copying: $0) }
                if keyStr == "age" {
                    let k = value.kind
                    #expect(k == .number)
                    let materialized = try value.materialize()
                    #expect(materialized == .number(.init(extendedPrecisionRepresentation: "30")))
                    found = true
                }
            }
            #expect(found)
        }
        try withPrescannedPrimitive(json) { prim in
            var iter = try prim.makeObjectIterator()
            var found = false
            while let (key, value) = iter.next() {
                let keyStr: String = try key.withUTF8String { String(copying: $0) }
                if keyStr == "name" {
                    let k = value.kind
                    #expect(k == .string)
                    found = true
                }
            }
            #expect(found)
        }
    }

    @Test("Missing key returns nil")
    func missingKey() throws {
        let json = #"{"name":"Alice"}"#
        try withStreamingPrimitive(json) { prim in
            var iter = try prim.makeObjectIterator()
            var found = false
            while let (key, _) = try iter.next() {
                let keyStr: String = try key.withUTF8String { String(copying: $0) }
                if keyStr == "missing" { found = true }
            }
            #expect(!found)
        }
        try withPrescannedPrimitive(json) { prim in
            var iter = try prim.makeObjectIterator()
            var found = false
            while let (key, _) = iter.next() {
                let keyStr: String = try key.withUTF8String { String(copying: $0) }
                if keyStr == "missing" { found = true }
            }
            #expect(!found)
        }
    }

    @Test("Key lookup with escaped string key")
    func escapedStringKey() throws {
        let json = #"{"hello\nworld":"value"}"#
        try withStreamingPrimitive(json) { prim in
            var iter = try prim.makeObjectIterator()
            var found = false
            while let (key, _) = try iter.next() {
                let keyStr: String = try key.withUTF8String { String(copying: $0) }
                if keyStr == "hello\nworld" { found = true }
            }
            #expect(found)
        }
        try withPrescannedPrimitive(json) { prim in
            var iter = try prim.makeObjectIterator()
            var found = false
            while let (key, _) = iter.next() {
                let keyStr: String = try key.withUTF8String { String(copying: $0) }
                if keyStr == "hello\nworld" { found = true }
            }
            #expect(found)
        }
    }

    @Test("Key lookup on non-object throws")
    func keyLookupOnArray() throws {
        _ = try withStreamingPrimitive("[1, 2, 3]") { prim in
            #expect(throws: JSONError.self) {
                _ = try prim.value(forKey: "key")
            }
        }
    }
}

// MARK: - Materialization Tests

@Suite("JSON Materialization")
struct JSONMaterializationTests {

    @Test("Materialize full object")
    func materializeObject() throws {
        let json = #"{"a":1,"b":"hello","c":true,"d":null,"e":[1,2]}"#
        let expected: JSONPrimitive = .dictionary([
            (key: "a", value: .number(.init(extendedPrecisionRepresentation: "1"))),
            (key: "b", value: .string("hello")),
            (key: "c", value: .bool(true)),
            (key: "d", value: .null),
            (key: "e", value: .array([
                .number(.init(extendedPrecisionRepresentation: "1")),
                .number(.init(extendedPrecisionRepresentation: "2")),
            ])),
        ])
        let streaming = try withStreamingPrimitive(json) { try $0.materialize() }
        #expect(streaming == expected)
    }

    @Test("Both types produce same materialized result")
    func bothTypesMatch() throws {
        let json = #"{"x":42,"y":-3.14e2,"z":"test"}"#
        let streaming = try withStreamingPrimitive(json) { try $0.materialize() }
        let prescanned = try withPrescannedPrimitive(json) { try $0.materialize() }
        #expect(streaming == prescanned)
    }
}

// MARK: - Complex Array Iteration Tests

@Suite("JSON Array Iteration")
struct JSONArrayIterationTests {

    @Test("Empty array")
    func emptyArray() throws {
        let streaming = try withStreamingPrimitive("[]") { try $0.materialize() }
        #expect(streaming == .array([]))
        let prescanned = try withPrescannedPrimitive("[]") { try $0.materialize() }
        #expect(prescanned == .array([]))
    }

    @Test("Array of mixed types")
    func mixedTypeArray() throws {
        let json = #"[1, "hello", true, false, null, 3.14]"#
        try withStreamingPrimitive(json) { prim in
            var kinds: [JSONValueKind] = []
            var iter = try prim.makeArrayIterator()
            while let element = try iter.next() {
                kinds.append(element.kind)
            }
            #expect(kinds == [.number, .string, .bool, .bool, .null, .number])
        }
        try withPrescannedPrimitive(json) { prim in
            var kinds: [JSONValueKind] = []
            var iter = try prim.makeArrayIterator()
            while let element = iter.next() {
                kinds.append(element.kind)
            }
            #expect(kinds == [.number, .string, .bool, .bool, .null, .number])
        }
    }

    @Test("Nested arrays via element-by-element iteration")
    func nestedArrays() throws {
        let json = "[[1, 2], [3, 4], [5]]"
        // Iterate the outer array and materialize each inner array
        try withStreamingPrimitive(json) { prim in
            var innerArrays: [JSONPrimitive] = []
            var outerIter = try prim.makeArrayIterator()
            while let element = try outerIter.next() {
                try innerArrays.append(element.materialize())
            }
            #expect(innerArrays.count == 3)
            #expect(innerArrays[0] == .array([
                .number(.init(extendedPrecisionRepresentation: "1")),
                .number(.init(extendedPrecisionRepresentation: "2")),
            ]))
            #expect(innerArrays[1] == .array([
                .number(.init(extendedPrecisionRepresentation: "3")),
                .number(.init(extendedPrecisionRepresentation: "4")),
            ]))
            #expect(innerArrays[2] == .array([
                .number(.init(extendedPrecisionRepresentation: "5")),
            ]))
        }
        try withPrescannedPrimitive(json) { prim in
            var innerArrays: [JSONPrimitive] = []
            var outerIter = try prim.makeArrayIterator()
            while let element = outerIter.next() {
                try innerArrays.append(element.materialize())
            }
            #expect(innerArrays.count == 3)
            #expect(innerArrays[0] == .array([
                .number(.init(extendedPrecisionRepresentation: "1")),
                .number(.init(extendedPrecisionRepresentation: "2")),
            ]))
        }
    }

    @Test("Nested arrays with inner iteration")
    func nestedArraysInnerIteration() throws {
        let json = "[[1, 2], [3, 4], [5]]"
        // Iterate the outer array, then iterate each inner array, collecting leaf values
        try withStreamingPrimitive(json) { prim in
            var allValues: [[JSONPrimitive]] = []
            var outerIter = try prim.makeArrayIterator()
            while let inner = try outerIter.next() {
                var values: [JSONPrimitive] = []
                var innerIter = try inner.makeArrayIterator()
                while let leaf = try innerIter.next() {
                    try values.append(leaf.materialize())
                }
                allValues.append(values)
            }
            #expect(allValues.count == 3)
            #expect(allValues[0] == [
                .number(.init(extendedPrecisionRepresentation: "1")),
                .number(.init(extendedPrecisionRepresentation: "2")),
            ])
            #expect(allValues[1] == [
                .number(.init(extendedPrecisionRepresentation: "3")),
                .number(.init(extendedPrecisionRepresentation: "4")),
            ])
            #expect(allValues[2] == [
                .number(.init(extendedPrecisionRepresentation: "5")),
            ])
        }
        try withPrescannedPrimitive(json) { prim in
            var allValues: [[JSONPrimitive]] = []
            var outerIter = try prim.makeArrayIterator()
            while let inner = outerIter.next() {
                var values: [JSONPrimitive] = []
                var innerIter = try inner.makeArrayIterator()
                while let leaf = innerIter.next() {
                    try values.append(leaf.materialize())
                }
                allValues.append(values)
            }
            #expect(allValues.count == 3)
            #expect(allValues[0] == [
                .number(.init(extendedPrecisionRepresentation: "1")),
                .number(.init(extendedPrecisionRepresentation: "2")),
            ])
        }
    }

    @Test("Deeply nested array")
    func deeplyNestedArray() throws {
        let json = "[[[1]]]"
        let expected: JSONPrimitive = .array([.array([.array([
            .number(.init(extendedPrecisionRepresentation: "1")),
        ])])])
        let streaming = try withStreamingPrimitive(json) { try $0.materialize() }
        #expect(streaming == expected)
        let prescanned = try withPrescannedPrimitive(json) { try $0.materialize() }
        #expect(prescanned == expected)
    }

    @Test("Array of objects iterated with key lookup")
    func arrayOfObjects() throws {
        let json = #"[{"a":1},{"b":2},{"c":3}]"#
        // Iterate the array, do key lookup on each object, collect materialized values
        try withStreamingPrimitive(json) { prim in
            let keys = ["a", "b", "c"]
            var results: [JSONPrimitive] = []
            var iter = try prim.makeArrayIterator()
            var i = 0
            while let obj = try iter.next() {
                let objK = obj.kind
                #expect(objK == .object)
                // value(forKey:) returns ~Escapable optional; materialize immediately
                var objIter = try obj.makeObjectIterator()
                while let (key, value) = try objIter.next() {
                    let keyStr: String = try key.withUTF8String { String(copying: $0) }
                    if keyStr == keys[i] {
                        try results.append(value.materialize())
                    }
                }
                i += 1
            }
            #expect(results == [
                .number(.init(extendedPrecisionRepresentation: "1")),
                .number(.init(extendedPrecisionRepresentation: "2")),
                .number(.init(extendedPrecisionRepresentation: "3")),
            ])
        }
        // Prescanned: same test using materialize on the whole structure
        let prescanned = try withPrescannedPrimitive(json) { try $0.materialize() }
        #expect(prescanned == .array([
            .dictionary([(key: "a", value: .number(.init(extendedPrecisionRepresentation: "1")))]),
            .dictionary([(key: "b", value: .number(.init(extendedPrecisionRepresentation: "2")))]),
            .dictionary([(key: "c", value: .number(.init(extendedPrecisionRepresentation: "3")))]),
        ]))
    }

    @Test("Array with whitespace")
    func arrayWithWhitespace() throws {
        let json = "  [  1  ,  2  ,  3  ]  "
        let expected: [JSONPrimitive] = [
            .number(.init(extendedPrecisionRepresentation: "1")),
            .number(.init(extendedPrecisionRepresentation: "2")),
            .number(.init(extendedPrecisionRepresentation: "3")),
        ]
        try withStreamingPrimitive(json) { prim in
            var values: [JSONPrimitive] = []
            var iter = try prim.makeArrayIterator()
            while let element = try iter.next() {
                try values.append(element.materialize())
            }
            #expect(values == expected)
        }
        try withPrescannedPrimitive(json) { prim in
            var values: [JSONPrimitive] = []
            var iter = try prim.makeArrayIterator()
            while let element = iter.next() {
                try values.append(element.materialize())
            }
            #expect(values == expected)
        }
    }

    @Test("Array containing strings with special characters")
    func arrayWithStrings() throws {
        let json = #"["hello", "world", "foo\"bar", "line\nnewline"]"#
        let expected: [JSONPrimitive] = [
            .string("hello"),
            .string("world"),
            .string("foo\"bar"),
            .string("line\nnewline"),
        ]
        try withStreamingPrimitive(json) { prim in
            var values: [JSONPrimitive] = []
            var iter = try prim.makeArrayIterator()
            while let element = try iter.next() {
                try values.append(element.materialize())
            }
            #expect(values == expected)
        }
        try withPrescannedPrimitive(json) { prim in
            var values: [JSONPrimitive] = []
            var iter = try prim.makeArrayIterator()
            while let element = iter.next() {
                try values.append(element.materialize())
            }
            #expect(values == expected)
        }
    }

    @Test("Materialize complex nested array")
    func materializeNestedArray() throws {
        let json = #"[1, [2, 3], [4, [5, 6]]]"#
        let expected: JSONPrimitive = .array([
            .number(.init(extendedPrecisionRepresentation: "1")),
            .array([
                .number(.init(extendedPrecisionRepresentation: "2")),
                .number(.init(extendedPrecisionRepresentation: "3")),
            ]),
            .array([
                .number(.init(extendedPrecisionRepresentation: "4")),
                .array([
                    .number(.init(extendedPrecisionRepresentation: "5")),
                    .number(.init(extendedPrecisionRepresentation: "6")),
                ]),
            ]),
        ])
        let streaming = try withStreamingPrimitive(json) { try $0.materialize() }
        #expect(streaming == expected)
        let prescanned = try withPrescannedPrimitive(json) { try $0.materialize() }
        #expect(prescanned == expected)
    }
}

// MARK: - Complex Object Iteration Tests

@Suite("JSON Object Iteration")
struct JSONObjectIterationTests {

    @Test("Empty object")
    func emptyObject() throws {
        let streaming = try withStreamingPrimitive("{}") { try $0.materialize() }
        #expect(streaming == .dictionary([]))
        let prescanned = try withPrescannedPrimitive("{}") { try $0.materialize() }
        #expect(prescanned == .dictionary([]))
    }

    @Test("Object iteration preserves order")
    func objectOrder() throws {
        let json = #"{"z":1,"a":2,"m":3}"#
        try withStreamingPrimitive(json) { prim in
            var keys: [String] = []
            var iter = try prim.makeObjectIterator()
            while let (key, _) = try iter.next() {
                try key.withUTF8String { keys.append(String(copying: $0)) }
            }
            #expect(keys == ["z", "a", "m"])
        }
        try withPrescannedPrimitive(json) { prim in
            var keys: [String] = []
            var iter = try prim.makeObjectIterator()
            while let (key, _) = iter.next() {
                try key.withUTF8String { keys.append(String(copying: $0)) }
            }
            #expect(keys == ["z", "a", "m"])
        }
    }

    @Test("Object with nested object values")
    func nestedObjects() throws {
        let json = #"{"outer":{"inner":{"deep":42}}}"#
        let expected: JSONPrimitive = .dictionary([
            (key: "outer", value: .dictionary([
                (key: "inner", value: .dictionary([
                    (key: "deep", value: .number(.init(extendedPrecisionRepresentation: "42"))),
                ])),
            ])),
        ])
        let streaming = try withStreamingPrimitive(json) { try $0.materialize() }
        #expect(streaming == expected)
        let prescanned = try withPrescannedPrimitive(json) { try $0.materialize() }
        #expect(prescanned == expected)
    }

    @Test("Object with array values")
    func objectWithArrayValues() throws {
        let json = #"{"names":["Alice","Bob"],"scores":[100,200,300]}"#
        let expected: JSONPrimitive = .dictionary([
            (key: "names", value: .array([.string("Alice"), .string("Bob")])),
            (key: "scores", value: .array([
                .number(.init(extendedPrecisionRepresentation: "100")),
                .number(.init(extendedPrecisionRepresentation: "200")),
                .number(.init(extendedPrecisionRepresentation: "300")),
            ])),
        ])
        let streaming = try withStreamingPrimitive(json) { try $0.materialize() }
        #expect(streaming == expected)
        let prescanned = try withPrescannedPrimitive(json) { try $0.materialize() }
        #expect(prescanned == expected)
    }

    @Test("Object iteration collects keys and value kinds")
    func objectWithMixedValues() throws {
        let json = #"{"str":"hello","num":42,"bool":true,"nil":null,"arr":[1],"obj":{"k":"v"}}"#
        try withStreamingPrimitive(json) { prim in
            var entries: [(String, JSONValueKind)] = []
            var iter = try prim.makeObjectIterator()
            while let (key, value) = try iter.next() {
                let keyStr: String = try key.withUTF8String { String(copying: $0) }
                entries.append((keyStr, value.kind))
            }
            #expect(entries.count == 6)
            #expect(entries[0].0 == "str")
            #expect(entries[0].1 == .string)
            #expect(entries[1].0 == "num")
            #expect(entries[1].1 == .number)
            #expect(entries[2].0 == "bool")
            #expect(entries[2].1 == .bool)
            #expect(entries[3].0 == "nil")
            #expect(entries[3].1 == .null)
            #expect(entries[4].0 == "arr")
            #expect(entries[4].1 == .array)
            #expect(entries[5].0 == "obj")
            #expect(entries[5].1 == .object)
        }
    }

    @Test("Object with whitespace")
    func objectWithWhitespace() throws {
        let json = #"  {  "a"  :  1  ,  "b"  :  2  }  "#
        let expected: JSONPrimitive = .dictionary([
            (key: "a", value: .number(.init(extendedPrecisionRepresentation: "1"))),
            (key: "b", value: .number(.init(extendedPrecisionRepresentation: "2"))),
        ])
        let streaming = try withStreamingPrimitive(json) { try $0.materialize() }
        #expect(streaming == expected)
        let prescanned = try withPrescannedPrimitive(json) { try $0.materialize() }
        #expect(prescanned == expected)
    }

    @Test("Materialize complex nested structure")
    func materializeComplexNested() throws {
        let json = #"{"users":[{"name":"Alice","tags":["admin","user"]},{"name":"Bob","tags":[]}],"count":2}"#
        let expected: JSONPrimitive = .dictionary([
            (key: "users", value: .array([
                .dictionary([
                    (key: "name", value: .string("Alice")),
                    (key: "tags", value: .array([.string("admin"), .string("user")])),
                ]),
                .dictionary([
                    (key: "name", value: .string("Bob")),
                    (key: "tags", value: .array([])),
                ]),
            ])),
            (key: "count", value: .number(.init(extendedPrecisionRepresentation: "2"))),
        ])
        let streaming = try withStreamingPrimitive(json) { try $0.materialize() }
        #expect(streaming == expected)
        let prescanned = try withPrescannedPrimitive(json) { try $0.materialize() }
        #expect(prescanned == expected)
    }

    @Test("Key lookup skips nested structures correctly")
    func keyLookupSkipsNested() throws {
        let json = #"{"first":{"nested":"value"},"second":42}"#
        // Looking up "second" requires skipping past the nested object value of "first"
        try withStreamingPrimitive(json) { prim in
            var iter = try prim.makeObjectIterator()
            var found = false
            while let (key, value) = try iter.next() {
                let keyStr: String = try key.withUTF8String { String(copying: $0) }
                if keyStr == "second" {
                    let mat = try value.materialize()
                    #expect(mat == .number(.init(extendedPrecisionRepresentation: "42")))
                    found = true
                }
            }
            #expect(found)
        }
        try withPrescannedPrimitive(json) { prim in
            var iter = try prim.makeObjectIterator()
            var found = false
            while let (key, value) = iter.next() {
                let keyStr: String = try key.withUTF8String { String(copying: $0) }
                if keyStr == "second" {
                    let mat = try value.materialize()
                    #expect(mat == .number(.init(extendedPrecisionRepresentation: "42")))
                    found = true
                }
            }
            #expect(found)
        }
    }

    @Test("Key lookup skips nested arrays correctly")
    func keyLookupSkipsNestedArrays() throws {
        let json = #"{"data":[1,[2,3],4],"result":"ok"}"#
        try withStreamingPrimitive(json) { prim in
            var iter = try prim.makeObjectIterator()
            var found = false
            while let (key, value) = try iter.next() {
                let keyStr: String = try key.withUTF8String { String(copying: $0) }
                if keyStr == "result" {
                    let mat = try value.materialize()
                    #expect(mat == .string("ok"))
                    found = true
                }
            }
            #expect(found)
        }
        try withPrescannedPrimitive(json) { prim in
            var iter = try prim.makeObjectIterator()
            var found = false
            while let (key, value) = iter.next() {
                let keyStr: String = try key.withUTF8String { String(copying: $0) }
                if keyStr == "result" {
                    let mat = try value.materialize()
                    #expect(mat == .string("ok"))
                    found = true
                }
            }
            #expect(found)
        }
    }

    @Test("Both types produce same result for complex structure")
    func bothTypesMatchComplex() throws {
        let json = #"{"a":[1,{"b":true},[null,"test"]],"c":{"d":[-1.5e2]}}"#
        let streaming = try withStreamingPrimitive(json) { try $0.materialize() }
        let prescanned = try withPrescannedPrimitive(json) { try $0.materialize() }
        #expect(streaming == prescanned)
    }
}
