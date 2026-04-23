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

// MARK: - Prescanned Result Tests

@Suite("JSONPrescannedResult")
struct JSONPrescannedResultTests {

    @Test("Parse and access string value")
    func stringValue() throws {
        try withRawSpan(of: "\"hello\"") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .string)
            let noError = result.error == nil
            #expect(noError)
            #expect(try result.stringValue == "hello")
        }
    }

    @Test("Parse and access bool value")
    func boolValue() throws {
        try withRawSpan(of: "true") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .bool)
            #expect(try result.boolValue == true)
        }
        try withRawSpan(of: "false") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(try result.boolValue == false)
        }
    }

    @Test("Parse and access null value")
    func nullValue() throws {
        try withRawSpan(of: "null") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .null)
            let isNull = result.isNull
            #expect(isNull)
        }
    }

    @Test("Parse and access integer value")
    func intValue() throws {
        try withRawSpan(of: "42") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .number)
            #expect(try result.intValue() == 42)
            #expect(try result.intValue(Int8.self) == 42)
        }
    }

    @Test("Parse and access double value")
    func doubleValue() throws {
        try withRawSpan(of: "3.14") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(try result.doubleValue() == 3.14)
        }
    }

    @Test("Object key subscript returns value")
    func objectKeySubscript() throws {
        try withRawSpan(of: #"{"name":"Alice","age":30}"#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .object)
            let nameNoError = result["name"].error == nil
            #expect(nameNoError)
            #expect(try result["name"].stringValue == "Alice")
            #expect(try result["age"].intValue() == 30)
        }
    }

    @Test("Object key subscript records error for missing key")
    func objectMissingKey() throws {
        try withRawSpan(of: #"{"name":"Alice"}"#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let missing = result["nonexistent"]
            let missingError = missing.error
            #expect(missingError == .keyNotFound("nonexistent"))
            let getIsNil = missing.get() == nil
            #expect(getIsNil)
        }
    }

    @Test("Array index subscript returns value")
    func arrayIndexSubscript() throws {
        try withRawSpan(of: "[10,20,30]") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .array)
            #expect(try result[0].intValue() == 10)
            #expect(try result[1].intValue() == 20)
            #expect(try result[2].intValue() == 30)
        }
    }

    @Test("Array index subscript records error for out-of-bounds")
    func arrayOutOfBounds() throws {
        try withRawSpan(of: "[1,2,3]") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let oob = result[5]
            let oobError = oob.error
            #expect(oobError == .indexOutOfBounds(5))
            let oobIsNil = oob.get() == nil
            #expect(oobIsNil)
            let negative = result[-1]
            let negativeError = negative.error
            #expect(negativeError == .indexOutOfBounds(-1))
        }
    }

    @Test("Nested object and array access via chaining")
    func nestedAccess() throws {
        let json = #"{"users":[{"name":"Alice"},{"name":"Bob"}]}"#
        try withRawSpan(of: json) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(try result["users"][0]["name"].stringValue == "Alice")
            #expect(try result["users"][1]["name"].stringValue == "Bob")
        }
    }

    @Test("Materialize produces equivalent JSONPrimitive")
    func materialize() throws {
        let json = #"{"a":1,"b":[true,null,"hi"]}"#
        try withRawSpan(of: json) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let materialized = try result.materialize()
            #expect(materialized == .dictionary([
                (key: "a", value: .number(.init(extendedPrecisionRepresentation: "1"))),
                (key: "b", value: .array([
                    .bool(true),
                    .null,
                    .string("hi")
                ]))
            ]))
        }
    }

    @Test("Count for array and object")
    func count() throws {
        try withRawSpan(of: "[1,2,3]") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(try result.count == 3)
        }
        try withRawSpan(of: #"{"a":1,"b":2}"#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(try result.count == 2)
        }
    }

    @Test("Array iterator yields all elements")
    func arrayIterator() throws {
        try withRawSpan(of: "[1,2,3]") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            var iter = try result.makeArrayIterator()
            var values: [Int] = []
            while let element = iter.next() {
                try values.append(element.intValue())
            }
            #expect(values == [1, 2, 3])
        }
    }

    @Test("Object iterator yields all key-value pairs")
    func objectIterator() throws {
        try withRawSpan(of: #"{"x":1,"y":2}"#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            var iter = try result.makeObjectIterator()
            var keys: [String] = []
            var values: [Int] = []
            while let (key, value) = iter.next() {
                try keys.append(key.stringValue)
                try values.append(value.intValue())
            }
            #expect(keys == ["x", "y"])
            #expect(values == [1, 2])
        }
    }

    @Test("String with escape sequences")
    func escapedString() throws {
        try withRawSpan(of: #""hello\nworld""#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(try result.stringValue == "hello\nworld")
        }
    }
}

// MARK: - Streaming Result Tests

@Suite("JSONStreamingResult")
struct JSONStreamingResultTests {

    @Test("Parse and access string value")
    func stringValue() throws {
        try withRawSpan(of: "\"hello\"") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .string)
            let noError = result.error == nil
            #expect(noError)
            #expect(try result.stringValue == "hello")
        }
    }

    @Test("Parse and access bool value")
    func boolValue() throws {
        try withRawSpan(of: "true") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .bool)
            #expect(try result.boolValue == true)
        }
        try withRawSpan(of: "false") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(try result.boolValue == false)
        }
    }

    @Test("Parse and access null value")
    func nullValue() throws {
        try withRawSpan(of: "null") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .null)
            let isNull = result.isNull
            #expect(isNull)
        }
    }

    @Test("Parse and access integer value")
    func intValue() throws {
        try withRawSpan(of: "42") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .number)
            #expect(try result.intValue() == 42)
            #expect(try result.intValue(Int8.self) == 42)
        }
    }

    @Test("Parse and access double value")
    func doubleValue() throws {
        try withRawSpan(of: "3.14") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(try result.doubleValue() == 3.14)
        }
    }

    @Test("Object key subscript returns value")
    func objectKeySubscript() throws {
        try withRawSpan(of: #"{"name":"Alice","age":30}"#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .object)
            let nameNoError = result["name"].error == nil
            #expect(nameNoError)
            #expect(try result["name"].stringValue == "Alice")
            #expect(try result["age"].intValue() == 30)
        }
    }

    @Test("Object key subscript records error for missing key")
    func objectMissingKey() throws {
        try withRawSpan(of: #"{"name":"Alice"}"#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let missing = result["nonexistent"]
            let missingError = missing.error
            #expect(missingError == .keyNotFound("nonexistent"))
            let getIsNil = missing.get() == nil
            #expect(getIsNil)
        }
    }

    @Test("Array index subscript returns value")
    func arrayIndexSubscript() throws {
        try withRawSpan(of: "[10,20,30]") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let kind = result.kind
            #expect(kind == .array)
            #expect(try result[0].intValue() == 10)
            #expect(try result[1].intValue() == 20)
            #expect(try result[2].intValue() == 30)
        }
    }

    @Test("Array index subscript records error for out-of-bounds")
    func arrayOutOfBounds() throws {
        try withRawSpan(of: "[1,2,3]") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let oob = result[5]
            let oobError = oob.error
            #expect(oobError == .indexOutOfBounds(5))
            let oobIsNil = oob.get() == nil
            #expect(oobIsNil)
            let negative = result[-1]
            let negativeError = negative.error
            #expect(negativeError == .indexOutOfBounds(-1))
        }
    }

    @Test("Nested object and array access via chaining")
    func nestedAccess() throws {
        let json = #"{"users":[{"name":"Alice"},{"name":"Bob"}]}"#
        try withRawSpan(of: json) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(try result["users"][0]["name"].stringValue == "Alice")
            #expect(try result["users"][1]["name"].stringValue == "Bob")
        }
    }

    @Test("Materialize produces equivalent JSONPrimitive")
    func materialize() throws {
        let json = #"{"a":1,"b":[true,null,"hi"]}"#
        try withRawSpan(of: json) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let materialized = try result.materialize()
            #expect(materialized == .dictionary([
                (key: "a", value: .number(.init(extendedPrecisionRepresentation: "1"))),
                (key: "b", value: .array([
                    .bool(true),
                    .null,
                    .string("hi")
                ]))
            ]))
        }
    }

    @Test("Array iterator yields all elements")
    func arrayIterator() throws {
        try withRawSpan(of: "[1,2,3]") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            var iter = try result.makeArrayIterator()
            var values: [Int] = []
            while let element = try iter.next() {
                try values.append(element.intValue())
            }
            #expect(values == [1, 2, 3])
        }
    }

    @Test("Object iterator yields all key-value pairs")
    func objectIterator() throws {
        try withRawSpan(of: #"{"x":1,"y":2}"#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            var iter = try result.makeObjectIterator()
            var keys: [String] = []
            var values: [Int] = []
            while let (key, value) = try iter.next() {
                try keys.append(key.stringValue)
                try values.append(value.intValue())
            }
            #expect(keys == ["x", "y"])
            #expect(values == [1, 2])
        }
    }

    @Test("String with escape sequences")
    func escapedString() throws {
        try withRawSpan(of: #""hello\nworld""#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(try result.stringValue == "hello\nworld")
        }
    }
}

// MARK: - Deep Nesting Tests

@Suite("JSONPrescannedResult - Deep Nesting")
struct JSONPrescannedResultDeepNestingTests {

    @Test("Access value through deeply nested objects")
    func deeplyNestedObjects() throws {
        let json = #"{"a":{"b":{"c":{"d":{"e":"deep"}}}}}"#
        try withRawSpan(of: json) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(try result["a"]["b"]["c"]["d"]["e"].stringValue == "deep")
        }
    }

    @Test("Access value through deeply nested arrays")
    func deeplyNestedArrays() throws {
        let json = "[[[[ 42 ]]]]"
        try withRawSpan(of: json) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(try result[0][0][0][0].intValue() == 42)
        }
    }

    @Test("Access value through mixed nested objects and arrays")
    func deeplyNestedMixed() throws {
        let json = #"{"config":{"servers":[{"endpoints":[{"url":"https://example.com","active":true}]}]}}"#
        try withRawSpan(of: json) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(try result["config"]["servers"][0]["endpoints"][0]["url"].stringValue == "https://example.com")
            #expect(try result["config"]["servers"][0]["endpoints"][0]["active"].boolValue == true)
        }
    }

    @Test("Error propagates through deeply nested chain for missing key")
    func deepNestingMissingKey() throws {
        let json = #"{"a":{"b":{"c":1}}}"#
        try withRawSpan(of: json) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let r = result["a"]["x"]["anything"]["else"]
            let rError = r.error
            #expect(rError == .keyNotFound("x"))
            let isNil = r.get() == nil
            #expect(isNil)
        }
    }

    @Test("Complex deeply nested structure with all value types")
    func deepComplexStructure() throws {
        let json = #"""
        {
            "level1": {
                "level2": [
                    {
                        "level3": {
                            "string": "found",
                            "number": 99,
                            "bool": false,
                            "null": null,
                            "nested_array": [1, [2, [3]]]
                        }
                    }
                ]
            }
        }
        """#
        try withRawSpan(of: json) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let l3 = result["level1"]["level2"][0]["level3"]
            let l3NoError = l3.error == nil
            #expect(l3NoError)
            #expect(try l3["string"].stringValue == "found")
            #expect(try l3["number"].intValue() == 99)
            #expect(try l3["bool"].boolValue == false)
            let nullIsNull = l3["null"].isNull
            #expect(nullIsNull == true)
            #expect(try l3["nested_array"][1][1][0].intValue() == 3)
        }
    }
}

@Suite("JSONStreamingResult - Deep Nesting")
struct JSONStreamingResultDeepNestingTests {

    @Test("Access value through deeply nested objects")
    func deeplyNestedObjects() throws {
        let json = #"{"a":{"b":{"c":{"d":{"e":"deep"}}}}}"#
        try withRawSpan(of: json) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(try result["a"]["b"]["c"]["d"]["e"].stringValue == "deep")
        }
    }

    @Test("Access value through deeply nested arrays")
    func deeplyNestedArrays() throws {
        let json = "[[[[ 42 ]]]]"
        try withRawSpan(of: json) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(try result[0][0][0][0].intValue() == 42)
        }
    }

    @Test("Access value through mixed nested objects and arrays")
    func deeplyNestedMixed() throws {
        let json = #"{"config":{"servers":[{"endpoints":[{"url":"https://example.com","active":true}]}]}}"#
        try withRawSpan(of: json) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(try result["config"]["servers"][0]["endpoints"][0]["url"].stringValue == "https://example.com")
            #expect(try result["config"]["servers"][0]["endpoints"][0]["active"].boolValue == true)
        }
    }

    @Test("Error propagates through deeply nested chain for missing key")
    func deepNestingMissingKey() throws {
        let json = #"{"a":{"b":{"c":1}}}"#
        try withRawSpan(of: json) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let r = result["a"]["x"]["anything"]["else"]
            let rError = r.error
            #expect(rError == .keyNotFound("x"))
            let isNil = r.get() == nil
            #expect(isNil)
        }
    }

    @Test("Complex deeply nested structure with all value types")
    func deepComplexStructure() throws {
        let json = #"""
        {
            "level1": {
                "level2": [
                    {
                        "level3": {
                            "string": "found",
                            "number": 99,
                            "bool": false,
                            "null": null,
                            "nested_array": [1, [2, [3]]]
                        }
                    }
                ]
            }
        }
        """#
        try withRawSpan(of: json) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let l3 = result["level1"]["level2"][0]["level3"]
            let l3NoError = l3.error == nil
            #expect(l3NoError)
            #expect(try l3["string"].stringValue == "found")
            #expect(try l3["number"].intValue() == 99)
            #expect(try l3["bool"].boolValue == false)
            let nullIsNull = l3["null"].isNull
            #expect(nullIsNull == true)
            #expect(try l3["nested_array"][1][1][0].intValue() == 3)
        }
    }
}

// MARK: - Error Propagation Tests

@Suite("JSONPrescannedResult - Error Propagation")
struct JSONPrescannedResultErrorPropagationTests {

    @Test("Error propagates: missing key then further subscripts")
    func errorPropagatesThroughChain() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let r = result["missing"]["nested"][0]
            let rError = r.error
            #expect(rError == .keyNotFound("missing"))
        }
    }

    @Test("Error propagates: out-of-bounds then further subscripts")
    func indexErrorPropagates() throws {
        try withRawSpan(of: "[1,2,3]") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let r = result[99][0]["key"]
            let rError = r.error
            #expect(rError == .indexOutOfBounds(99))
        }
    }

    @Test("Key subscript on a non-object records error")
    func keySubscriptOnNonObject() throws {
        try withRawSpan(of: "[1,2,3]") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let r = result["key"]
            let hasError = r.error != nil
            #expect(hasError)
            let isNil = r.get() == nil
            #expect(isNil)
        }
    }

    @Test("Index subscript on a non-array records error")
    func indexSubscriptOnNonArray() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let r = result[0]
            let hasError = r.error != nil
            #expect(hasError)
            let isNil = r.get() == nil
            #expect(isNil)
        }
    }

    @Test("Key subscript on a leaf value records error")
    func keySubscriptOnLeaf() throws {
        try withRawSpan(of: "42") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let r = result["key"]
            let hasError = r.error != nil
            #expect(hasError)
        }
    }

    @Test("Index subscript on a leaf value records error")
    func indexSubscriptOnLeaf() throws {
        try withRawSpan(of: #""hello""#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let r = result[0]
            let hasError = r.error != nil
            #expect(hasError)
        }
    }

    @Test("get() returns nil on error")
    func getNilOnError() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let isNil = result["missing"].get() == nil
            #expect(isNil)
        }
    }

    @Test("get() returns primitive on success")
    func getReturnsOnSuccess() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let hasValue = result["a"].get() != nil
            #expect(hasValue)
        }
    }

    @Test("Leaf accessors throw recorded errors")
    func leafAccessorsThrowRecordedError() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result["missing"].stringValue
            }
        }
    }

    @Test("stringValue on a number throws type mismatch")
    func stringOnNumber() throws {
        try withRawSpan(of: "42") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result.stringValue
            }
        }
    }

    @Test("boolValue on a string throws type mismatch")
    func boolOnString() throws {
        try withRawSpan(of: #""hello""#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result.boolValue
            }
        }
    }

    @Test("intValue on a string throws type mismatch")
    func intOnString() throws {
        try withRawSpan(of: #""hello""#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result.intValue()
            }
        }
    }

    @Test("intValue overflow throws")
    func intOverflow() throws {
        try withRawSpan(of: "999999999999999999999") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result.intValue(Int8.self)
            }
        }
    }

    @Test("boolValue on null throws")
    func boolOnNull() throws {
        try withRawSpan(of: "null") { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result.boolValue
            }
        }
    }

    @Test("isNull returns false in error state")
    func isNullInErrorState() throws {
        try withRawSpan(of: #"{"a":null}"#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            let aIsNull = result["a"].isNull
            #expect(aIsNull == true)
            let missingIsNull = result["missing"].isNull
            #expect(missingIsNull == false)
        }
    }

    @Test("materialize throws recorded error")
    func materializeThrowsError() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONPrescannedResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result["missing"].materialize()
            }
        }
    }
}

@Suite("JSONStreamingResult - Error Propagation")
struct JSONStreamingResultErrorPropagationTests {

    @Test("Error propagates: missing key then further subscripts")
    func errorPropagatesThroughChain() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let r = result["missing"]["nested"][0]
            let rError = r.error
            #expect(rError == .keyNotFound("missing"))
        }
    }

    @Test("Error propagates: out-of-bounds then further subscripts")
    func indexErrorPropagates() throws {
        try withRawSpan(of: "[1,2,3]") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let r = result[99][0]["key"]
            let rError = r.error
            #expect(rError == .indexOutOfBounds(99))
        }
    }

    @Test("Key subscript on a non-object records error")
    func keySubscriptOnNonObject() throws {
        try withRawSpan(of: "[1,2,3]") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let r = result["key"]
            let hasError = r.error != nil
            #expect(hasError)
            let isNil = r.get() == nil
            #expect(isNil)
        }
    }

    @Test("Index subscript on a non-array records error")
    func indexSubscriptOnNonArray() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let r = result[0]
            let hasError = r.error != nil
            #expect(hasError)
            let isNil = r.get() == nil
            #expect(isNil)
        }
    }

    @Test("Key subscript on a leaf value records error")
    func keySubscriptOnLeaf() throws {
        try withRawSpan(of: "42") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let r = result["key"]
            let hasError = r.error != nil
            #expect(hasError)
        }
    }

    @Test("Index subscript on a leaf value records error")
    func indexSubscriptOnLeaf() throws {
        try withRawSpan(of: #""hello""#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let r = result[0]
            let hasError = r.error != nil
            #expect(hasError)
        }
    }

    @Test("get() returns nil on error")
    func getNilOnError() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let isNil = result["missing"].get() == nil
            #expect(isNil)
        }
    }

    @Test("get() returns primitive on success")
    func getReturnsOnSuccess() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let hasValue = result["a"].get() != nil
            #expect(hasValue)
        }
    }

    @Test("Leaf accessors throw recorded errors")
    func leafAccessorsThrowRecordedError() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result["missing"].stringValue
            }
        }
    }

    @Test("stringValue on a number throws type mismatch")
    func stringOnNumber() throws {
        try withRawSpan(of: "42") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result.stringValue
            }
        }
    }

    @Test("boolValue on a string throws type mismatch")
    func boolOnString() throws {
        try withRawSpan(of: #""hello""#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result.boolValue
            }
        }
    }

    @Test("intValue on a string throws type mismatch")
    func intOnString() throws {
        try withRawSpan(of: #""hello""#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result.intValue()
            }
        }
    }

    @Test("intValue overflow throws")
    func intOverflow() throws {
        try withRawSpan(of: "999999999999999999999") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result.intValue(Int8.self)
            }
        }
    }

    @Test("boolValue on null throws")
    func boolOnNull() throws {
        try withRawSpan(of: "null") { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result.boolValue
            }
        }
    }

    @Test("isNull returns false in error state")
    func isNullInErrorState() throws {
        try withRawSpan(of: #"{"a":null}"#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            let aIsNull = result["a"].isNull
            #expect(aIsNull == true)
            let missingIsNull = result["missing"].isNull
            #expect(missingIsNull == false)
        }
    }

    @Test("materialize throws recorded error")
    func materializeThrowsError() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let result = try JSONStreamingResult.parse(bytes)
            #expect(throws: JSONError.self) {
                try result["missing"].materialize()
            }
        }
    }
}

// MARK: - Cross-validation Tests

@Suite("JSONResult Cross-validation")
struct JSONResultCrossValidationTests {

    @Test("Prescanned and streaming produce same materialized result")
    func crossValidation() throws {
        let jsons = [
            "null",
            "true",
            "false",
            "42",
            "3.14",
            #""hello""#,
            "[]",
            "{}",
            "[1,2,3]",
            #"{"a":1}"#,
            #"{"a":1,"b":"two","c":true,"d":null,"e":[1,[2,3]],"f":{"g":"h"}}"#,
        ]
        for json in jsons {
            try withRawSpan(of: json) { bytes in
                let prescanned = try JSONPrescannedResult.parse(bytes)
                let streaming = try JSONStreamingResult.parse(bytes)
                let m1 = try prescanned.materialize()
                let m2 = try streaming.materialize()
                #expect(m1 == m2, "Mismatch for input: \(json)")
            }
        }
    }

    @Test("Both types record same error for missing keys")
    func missingKeyBoth() throws {
        try withRawSpan(of: #"{"a":1}"#) { bytes in
            let prescanned = try JSONPrescannedResult.parse(bytes)
            let streaming = try JSONStreamingResult.parse(bytes)
            let pError = prescanned["missing"].error
            #expect(pError == .keyNotFound("missing"))
            let sError = streaming["missing"].error
            #expect(sError == .keyNotFound("missing"))
        }
    }

    @Test("Both types record same error for out-of-bounds index")
    func outOfBoundsBoth() throws {
        try withRawSpan(of: "[1]") { bytes in
            let prescanned = try JSONPrescannedResult.parse(bytes)
            let streaming = try JSONStreamingResult.parse(bytes)
            let pError = prescanned[99].error
            #expect(pError == .indexOutOfBounds(99))
            let sError = streaming[99].error
            #expect(sError == .indexOutOfBounds(99))
        }
    }

    @Test("Both types propagate errors identically through chains")
    func errorPropagationBoth() throws {
        try withRawSpan(of: #"{"a":{"b":1}}"#) { bytes in
            let prescanned = try JSONPrescannedResult.parse(bytes)
            let streaming = try JSONStreamingResult.parse(bytes)
            let pError = prescanned["a"]["x"]["y"]["z"].error
            #expect(pError == .keyNotFound("x"))
            let sError = streaming["a"]["x"]["y"]["z"].error
            #expect(sError == .keyNotFound("x"))
        }
    }
}
