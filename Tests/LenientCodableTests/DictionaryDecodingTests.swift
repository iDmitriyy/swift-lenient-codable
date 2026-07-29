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
}
