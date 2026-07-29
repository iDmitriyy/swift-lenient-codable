//
//  DictionaryDecodingTests.swift
//  LenientCodable
//
//  Created by Omar Elsayed on 29/07/2026.
//

import Foundation
import Testing
@testable import LenientDecoding

@Suite("Dictionary decoding")
struct DictionaryDecodingTests {
    @Suite("AnyCodingKey")
    struct AnyCodingKeyTests {
        @Test("string key round-trips")
        func stringKey() {
            let key = AnyCodingKey(stringValue: "name")
            #expect(key.stringValue == "name")
            #expect(key.intValue == nil)
        }

        @Test("numeric string exposes intValue")
        func numericString() {
            let key = AnyCodingKey(stringValue: "42")
            #expect(key.intValue == 42)
        }

        @Test("int init sets both representations")
        func intKey() {
            let key = AnyCodingKey(intValue: 7)
            #expect(key.stringValue == "7")
            #expect(key.intValue == 7)
        }
    }

    @Suite("LenientDictionaryKey")
    struct LenientDictionaryKeyTests {
        enum StringStatus: String, LenientDictionaryKey { case active, archived }
        enum IntLevel: Int, LenientDictionaryKey { case one = 1, two = 2 }

        @Test("String conforms, never fails")
        func string() {
            #expect(String(lenientKeyString: "anything") == "anything")
        }

        @Test("Int parses numeric strings, fails otherwise")
        func int() {
            #expect(Int(lenientKeyString: "42") == 42)
            #expect(Int(lenientKeyString: "abc") == nil)
        }

        @Test("String-raw enum via RawRepresentable extension")
        func stringEnum() {
            #expect(StringStatus(lenientKeyString: "active") == .active)
            #expect(StringStatus(lenientKeyString: "deleted") == nil)
        }

        @Test("Int-raw enum via RawRepresentable extension")
        func intEnum() {
            #expect(IntLevel(lenientKeyString: "2") == .two)
            #expect(IntLevel(lenientKeyString: "9") == nil)
            #expect(IntLevel(lenientKeyString: "two") == nil)
        }
    }

    @Suite("LenientDecoding.nilPadding (dictionary)")
    struct DictionaryNilPaddingTests {
        private func catalogJSON(scores: String) -> String {
            #"{ "scores": \#(scores), "regions": {}, "stock": {} }"#
        }

        @Test("all entries valid → full dictionary")
        func allValid() throws {
            let catalog = try decode(Catalog.self, catalogJSON(scores: #"{ "math": 90, "art": 75 }"#))
            #expect(catalog.scores == ["math": 90, "art": 75])
        }

        @Test("broken value → nil at that key, other entries survive")
        func brokenValuePads() throws {
            let catalog = try decode(Catalog.self, catalogJSON(scores: #"{ "math": 90, "art": "high" }"#))
            #expect(catalog.scores.count == 2)
            #expect(catalog.scores["math"] == 90)
            #expect(catalog.scores["art"]! == nil)
        }

        @Test("null value → nil at that key (intentional null, silent)")
        func nullValue() throws {
            let catalog = try decode(Catalog.self, catalogJSON(scores: #"{ "math": null }"#))
            #expect(catalog.scores.count == 1)
            #expect(catalog.scores["math"]! == nil)
        }

        @Test("missing key → [:]")
        func missingKey() throws {
            let catalog = try decode(Catalog.self, #"{ "regions": {}, "stock": {} }"#)
            #expect(catalog.scores == [:])
        }

        @Test("JSON null → [:]")
        func nullDictionary() throws {
            let catalog = try decode(Catalog.self, catalogJSON(scores: "null"))
            #expect(catalog.scores == [:])
        }

        @Test("value is not an object → [:]")
        func notAnObject() throws {
            let catalog = try decode(Catalog.self, catalogJSON(scores: "[1, 2]"))
            #expect(catalog.scores == [:])
        }

        @Test("empty object → [:]")
        func emptyObject() throws {
            let catalog = try decode(Catalog.self, catalogJSON(scores: "{}"))
            #expect(catalog.scores == [:])
        }

        @Test("unknown enum key → entry dropped, others survive")
        func unknownEnumKeyDropped() throws {
            let json = #"{ "scores": {}, "regions": { "eu": { "amount": 9.99 }, "asia": { "amount": 5 } }, "stock": {} }"#
            let catalog = try decode(Catalog.self, json)
            #expect(catalog.regions.count == 1)
            #expect(catalog.regions[.eu] == Price(amount: 9.99))
        }

        @Test("non-numeric Int key → entry dropped")
        func badIntKeyDropped() throws {
            let json = #"{ "scores": {}, "regions": {}, "stock": { "7": 100, "abc": 5 } }"#
            let catalog = try decode(Catalog.self, json)
            #expect(catalog.stock.count == 1)
            #expect(catalog.stock[7]! == 100)
        }

        @Test("keys colliding after conversion keep one entry")
        func keyCollisionAfterConversion() throws {
            let json = #"{ "scores": {}, "regions": {}, "stock": { "7": 1, "07": 2 } }"#
            let catalog = try decode(Catalog.self, json)
            #expect(catalog.stock.count == 1)
            #expect(catalog.stock[7] != nil)
        }

        @Test("bad key AND bad value in one object")
        func mixedFailures() throws {
            let json = #"{ "scores": {}, "regions": {}, "stock": { "7": 100, "abc": 5, "9": "x" } }"#
            let catalog = try decode(Catalog.self, json)
            #expect(catalog.stock.count == 2)          // "abc" dropped
            #expect(catalog.stock[7]! == 100)
            #expect(catalog.stock[9]! == nil)          // bad value padded
        }
    }

    @Suite("LenientDecoding.nilPaddingOptional (dictionary)")
    struct DictionaryNilPaddingOptionalTests {
        private func json(extras: String) -> String {
            #"{ "scores": {}, "regions": {}, "stock": {}, "extras": \#(extras) }"#
        }

        @Test("missing key → nil (not [:])")
        func missingKey() throws {
            let catalog = try decode(Catalog.self, #"{ "scores": {}, "regions": {}, "stock": {} }"#)
            #expect(catalog.extras == nil)
        }

        @Test("JSON null → nil")
        func nullDictionary() throws {
            let catalog = try decode(Catalog.self, json(extras: "null"))
            #expect(catalog.extras == nil)
        }

        @Test("value is not an object → nil")
        func notAnObject() throws {
            let catalog = try decode(Catalog.self, json(extras: "3"))
            #expect(catalog.extras == nil)
        }

        @Test("empty object → [:] (present but empty ≠ absent)")
        func emptyObject() throws {
            let catalog = try decode(Catalog.self, json(extras: "{}"))
            #expect(catalog.extras != nil)
            #expect(catalog.extras?.isEmpty == true)
        }

        @Test("actual object → padded exactly like nilPadding")
        func actualObject() throws {
            let catalog = try decode(Catalog.self, json(extras: #"{ "a": 1, "b": "x" }"#))
            let extras = try #require(catalog.extras)
            #expect(extras.count == 2)
            #expect(extras["a"]! == 1)
            #expect(extras["b"]! == nil)
        }
    }
}

// MARK: - Helper types
private enum Region: String, LenientDictionaryKey { case eu, us }

private struct Price: Decodable, Equatable {
    let amount: Double
}

/// Exercises the dictionary `nilPadding` helper across all three key kinds:
/// `String` (identity), enum (`RawRepresentable` extension), and `Int` (parse).
private struct Catalog: Decodable {
    let scores: [String: Int?]
    let regions: [Region: Price?]
    let stock: [Int: Int?]
    let extras: [String: Int?]?

    enum CodingKeys: CodingKey { case scores, regions, stock, extras }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.scores = LenientDecoding.nilPadding(String.self, Int.self, in: container, forKey: .scores, decoder: decoder)
        self.regions = LenientDecoding.nilPadding(Region.self, Price.self, in: container, forKey: .regions, decoder: decoder)
        self.stock = LenientDecoding.nilPadding(Int.self, Int.self, in: container, forKey: .stock, decoder: decoder)
        self.extras = LenientDecoding.nilPaddingOptional(String.self, Int.self, in: container, forKey: .extras, decoder: decoder)
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}
