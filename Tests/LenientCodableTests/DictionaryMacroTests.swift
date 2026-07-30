//
//  DictionaryMacroTests.swift
//  LenientCodable
//
//  Created by Omar Elsayed on 29/07/2026.
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacrosTestSupport
import Testing
import XCTest
@testable import LenientCodableMacros

@Suite("Dictionary TypeShape parsing")
struct DictionaryTypeShapeTests {
    private func shape(_ type: TypeSyntax) -> TypeShape { type.parseToTypeShape() }

    @Test("[K: V] → dictionary")
    func plainDictionary() {
        guard case .dictionary(let key, let value) = shape("[String: Int]") else {
            Issue.record("expected .dictionary"); return
        }
        #expect(key.trimmedDescription == "String")
        #expect(value.trimmedDescription == "Int")
    }

    @Test("[K: V?] → dictionaryOfOptionalValues, payload is the wrapped value type")
    func optionalValues() {
        guard case .dictionaryOfOptionalValues(let key, let value) = shape("[String: Int?]") else {
            Issue.record("expected .dictionaryOfOptionalValues"); return
        }
        #expect(key.trimmedDescription == "String")
        #expect(value.trimmedDescription == "Int")
    }

    @Test("[K: V]? → optionalDictionary")
    func optionalDictionary() {
        guard case .optionalDictionary(let key, let value) = shape("[String: Int]?") else {
            Issue.record("expected .optionalDictionary"); return
        }
        #expect(key.trimmedDescription == "String")
        #expect(value.trimmedDescription == "Int")
    }

    @Test("[K: V?]? → optionalDictionaryOfOptionalValues")
    func optionalDictionaryOfOptionalValues() {
        guard case .optionalDictionaryOfOptionalValues(let key, let value) = shape("[String: Int?]?") else {
            Issue.record("expected .optionalDictionaryOfOptionalValues"); return
        }
        #expect(key.trimmedDescription == "String")
        #expect(value.trimmedDescription == "Int")
    }

    @Test("[K?: V] parses as dictionary with optional key payload")
    func optionalKeySurvivesParsing() {
        guard case .dictionary(let key, _) = shape("[String?: Int]") else {
            Issue.record("expected .dictionary"); return
        }
        #expect(key.is(OptionalTypeSyntax.self))
    }

    @Test("Dictionary<K, V> longhand → unsupportedLonghand")
    func longhand() {
        guard case .unsupportedLonghand = shape("Dictionary<String, Int>") else {
            Issue.record("expected .unsupportedLonghand"); return
        }
    }

    @Test("Swift.Dictionary<K, V> longhand → unsupportedLonghand")
    func qualifiedLonghand() {
        guard case .unsupportedLonghand = shape("Swift.Dictionary<String, Int>") else {
            Issue.record("expected .unsupportedLonghand"); return
        }
    }

    @Test("longhand inside dictionary value → unsupportedLonghand")
    func longhandInsideValue() {
        guard case .unsupportedLonghand = shape("[String: Optional<Int>]") else {
            Issue.record("expected .unsupportedLonghand"); return
        }
    }

    @Test("longhand inside dictionary key → unsupportedLonghand")
    func longhandInsideKey() {
        guard case .unsupportedLonghand = shape("[Optional<String>: Int]") else {
            Issue.record("expected .unsupportedLonghand"); return
        }
    }

    @Test("optional dictionary with longhand inside → unsupportedLonghand")
    func optionalDictionaryLonghandInside() {
        guard case .unsupportedLonghand = shape("[String: Array<Int>]?") else {
            Issue.record("expected .unsupportedLonghand"); return
        }
    }

    @Test("array of dictionaries stays an array (value carried opaquely)")
    func arrayOfDictionaries() {
        guard case .array(let element) = shape("[[String: Int]]") else {
            Issue.record("expected .array"); return
        }
        #expect(element.trimmedDescription == "[String: Int]")
    }

    @Test("dictionary with array values stays a dictionary (value carried opaquely)")
    func dictionaryOfArrays() {
        guard case .dictionary(_, let value) = shape("[String: [Int]]") else {
            Issue.record("expected .dictionary"); return
        }
        #expect(value.trimmedDescription == "[Int]")
    }
}

// MARK: - @Strict dictionary expansion (final behavior, not a passthrough)
final class DictionaryStrictExpansionTests: XCTestCase {
    override func invokeTest() {
        #if canImport(LenientCodableMacros)
        super.invokeTest()
        #endif
    }

    /// Pins the `@Strict` dictionary reconstruction — including the colon
    /// spacing of the rebuilt `[String: Int]` — which no other test observes.
    func testStrictDictionaryPropertiesKeepSynthesizedBehavior() {
        assertMacroExpansion(
            """
            @LenientDecodable
            struct Cache {
                @Strict var counts: [String: Int]
                @Strict var meta: [String: Int]?
            }
            """,
            expandedSource: """
            struct Cache {
                var counts: [String: Int]
                var meta: [String: Int]?

                private enum CodingKeys: String, CodingKey {
                    case counts
                    case meta
                }

                init(from decoder: any Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        self.counts = try container.decode([String: Int].self, forKey: .counts)
                        self.meta = try container.decodeIfPresent([String: Int].self, forKey: .meta)
                }
            }

            extension Cache: Decodable {
            }
            """,
            macros: testMacros
        )
    }
}
