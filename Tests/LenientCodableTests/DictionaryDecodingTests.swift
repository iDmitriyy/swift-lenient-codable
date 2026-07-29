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
}
