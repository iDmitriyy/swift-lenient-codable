//
//  DictionaryIntegrationTests.swift
//  LenientCodable
//
//  Created by Omar Elsayed on 30/07/2026.
//

import Foundation
import Testing
import LenientCodable

// MARK: - Fixture

fileprivate enum Region: String, LenientDictionaryKey { case eu, us }

/// End-to-end fixture: the `@LenientDecodable` attribute expands through the
/// real macro implementation, calls the real `LenientDecoding` runtime, and is
/// decoded by a real `JSONDecoder` — exactly what a package consumer gets.
@LenientDecodable
fileprivate struct Storefront {
    @Strict var id: Int
    @Strict var inventory: [String: Int]
    var scores: [String: Int?]                          // implicit @NilOnFailure → nilPadding
    @NilOnFailure var regionNames: [Region: String?]    // enum keys
    @DropOnFailure var prices: [String: Double]
    var extras: [String: Int?]?                         // implicit → nilPaddingOptional
}

@Suite("Dictionary integration (macro + runtime + JSONDecoder)")
struct DictionaryIntegrationTests {
    @Test("happy path: all six properties decode exact values")
    func happyPath() throws {
        let json = #"""
        {
            "id": 1,
            "inventory": { "widgets": 3 },
            "scores": { "math": 90, "art": 75 },
            "regionNames": { "eu": "Europe", "us": "United States" },
            "prices": { "eu": 9.99, "us": 12.5 },
            "extras": { "bonus": 5 }
        }
        """#
        let storefront = try decode(Storefront.self, json)
        #expect(storefront.id == 1)
        #expect(storefront.inventory == ["widgets": 3])
        #expect(storefront.scores == ["math": 90, "art": 75])
        #expect(storefront.regionNames == [.eu: "Europe", .us: "United States"])
        #expect(storefront.prices == ["eu": 9.99, "us": 12.5])
        #expect(storefront.extras == ["bonus": 5])
    }

    @Test("broken value in nil-padded dictionary → nil at that key, siblings survive")
    func brokenValuePads() throws {
        let json = #"""
        {
            "id": 1,
            "inventory": {},
            "scores": { "math": 90, "art": "high" },
            "regionNames": {},
            "prices": {}
        }
        """#
        let storefront = try decode(Storefront.self, json)
        #expect(storefront.id == 1)
        #expect(storefront.scores.count == 2)
        #expect(storefront.scores["math"] == 90)
        #expect(storefront.scores["art"] == .some(nil))
    }

    @Test("broken value in drop-on-failure dictionary → entry removed")
    func brokenValueDrops() throws {
        let json = #"""
        {
            "id": 1,
            "inventory": {},
            "scores": {},
            "regionNames": {},
            "prices": { "eu": 9.99, "us": "n/a" }
        }
        """#
        let storefront = try decode(Storefront.self, json)
        #expect(storefront.prices == ["eu": 9.99])
    }

    @Test("unknown enum key drops its entry, siblings survive")
    func unknownEnumKeyDropped() throws {
        let json = #"""
        {
            "id": 1,
            "inventory": {},
            "scores": {},
            "regionNames": { "eu": "Europe", "asia": "Asia" },
            "prices": {}
        }
        """#
        let storefront = try decode(Storefront.self, json)
        #expect(storefront.regionNames.count == 1)
        #expect(storefront.regionNames[.eu] == "Europe")
    }

    @Test("missing lenient keys → [:] for dictionaries, nil for the optional one")
    func missingLenientKeys() throws {
        let storefront = try decode(Storefront.self, #"{ "id": 1, "inventory": {} }"#)
        #expect(storefront.id == 1)
        #expect(storefront.scores == [:])
        #expect(storefront.regionNames == [:])
        #expect(storefront.prices == [:])
        #expect(storefront.extras == nil)
    }

    @Test("explicit null lenient keys → same as missing")
    func nullLenientKeys() throws {
        let json = #"""
        {
            "id": 1,
            "inventory": {},
            "scores": null,
            "regionNames": null,
            "prices": null,
            "extras": null
        }
        """#
        let storefront = try decode(Storefront.self, json)
        #expect(storefront.id == 1)
        #expect(storefront.scores == [:])
        #expect(storefront.regionNames == [:])
        #expect(storefront.prices == [:])
        #expect(storefront.extras == nil)
    }

    @Test("non-object values on lenient keys → [:] for dictionaries, nil for the optional one")
    func nonObjectLenientValues() throws {
        let json = #"""
        {
            "id": 1,
            "inventory": {},
            "scores": 42,
            "regionNames": [1, 2],
            "prices": "free",
            "extras": 3
        }
        """#
        let storefront = try decode(Storefront.self, json)
        #expect(storefront.id == 1)
        #expect(storefront.scores == [:])
        #expect(storefront.regionNames == [:])
        #expect(storefront.prices == [:])
        #expect(storefront.extras == nil)
    }

    @Test("@Strict property with broken value still fails the whole decode")
    func strictBrokenValueThrows() {
        let json = #"""
        {
            "id": "not-a-number",
            "inventory": { "widgets": 3 },
            "scores": { "math": 90 },
            "regionNames": { "eu": "Europe" },
            "prices": { "eu": 9.99 },
            "extras": { "bonus": 5 }
        }
        """#
        #expect(throws: DecodingError.self) {
            _ = try decode(Storefront.self, json)
        }
    }

    @Test("missing @Strict key fails the whole decode")
    func strictMissingKeyThrows() {
        let json = #"""
        {
            "inventory": { "widgets": 3 },
            "scores": { "math": 90 },
            "regionNames": { "eu": "Europe" },
            "prices": { "eu": 9.99 },
            "extras": { "bonus": 5 }
        }
        """#
        #expect(throws: DecodingError.self) {
            _ = try decode(Storefront.self, json)
        }
    }

    @Test("@Strict dictionary with a broken value fails the whole decode (bypasses lenient helpers)")
    func strictDictionaryBrokenValueThrows() {
        let json = #"""
        {
            "id": 1,
            "inventory": { "widgets": "many" },
            "scores": { "math": 90 },
            "regionNames": { "eu": "Europe" },
            "prices": { "eu": 9.99 },
            "extras": { "bonus": 5 }
        }
        """#
        #expect(throws: DecodingError.self) {
            _ = try decode(Storefront.self, json)
        }
    }

    @Test("kitchen sink: failures in every lenient property, decode still succeeds")
    func kitchenSink() throws {
        let json = #"""
        {
            "id": 7,
            "inventory": { "widgets": 3 },
            "scores": { "math": 90, "art": "high" },
            "regionNames": { "eu": "Europe", "asia": "Asia", "us": 42 },
            "prices": { "eu": 9.99, "us": "n/a" },
            "extras": { "a": 1, "b": "x" }
        }
        """#
        let storefront = try decode(Storefront.self, json)

        #expect(storefront.id == 7)
        #expect(storefront.inventory == ["widgets": 3])

        // scores: broken value padded with nil
        #expect(storefront.scores.count == 2)
        #expect(storefront.scores["math"] == 90)
        #expect(storefront.scores["art"] == .some(nil))

        // regionNames: unknown key "asia" dropped, broken value at "us" padded
        #expect(storefront.regionNames.count == 2)
        #expect(storefront.regionNames[.eu] == "Europe")
        #expect(storefront.regionNames[.us] == .some(nil))

        // prices: broken entry dropped
        #expect(storefront.prices == ["eu": 9.99])

        // extras: present object with one bad entry → padded in place
        let extras = try #require(storefront.extras)
        #expect(extras.count == 2)
        #expect(extras["a"] == 1)
        #expect(extras["b"] == .some(nil))
    }
}

// MARK: - Helper

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}
