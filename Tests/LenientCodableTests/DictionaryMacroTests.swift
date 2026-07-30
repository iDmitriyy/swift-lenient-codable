//
//  DictionaryMacroTests.swift
//  LenientCodable
//
//  Created by Omar Elsayed on 29/07/2026.
//

import SwiftDiagnostics
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

@Suite("Dictionary DecodingPlan rendering")
struct DictionaryDecodingPlanTests {
    @Test("dictionaryValuePadding renders the dictionary nilPadding call")
    func valuePadding() {
        let plan = DecodingPlan.dictionaryValuePadding(key: "String", value: "Int")
        #expect(plan.decodingLine(name: "scores") ==
            "self.scores = LenientDecoding.nilPadding(String.self, Int.self, in: container, forKey: .scores, decoder: decoder)")
    }

    @Test("dictionaryValuePaddingOptional renders the dictionary nilPaddingOptional call")
    func valuePaddingOptional() {
        let plan = DecodingPlan.dictionaryValuePaddingOptional(key: "String", value: "Int")
        #expect(plan.decodingLine(name: "extras") ==
            "self.extras = LenientDecoding.nilPaddingOptional(String.self, Int.self, in: container, forKey: .extras, decoder: decoder)")
    }

    @Test("dictionaryDropOnFailure renders the dictionary dropOnFailure call")
    func drop() {
        let plan = DecodingPlan.dictionaryDropOnFailure(key: "String", value: "Double")
        #expect(plan.decodingLine(name: "prices") ==
            "self.prices = LenientDecoding.dropOnFailure(String.self, Double.self, in: container, forKey: .prices, decoder: decoder)")
    }

    @Test("payload trivia is trimmed in the rendered line")
    func triviaTrimmed() {
        let key: TypeSyntax = " String "
        let value: TypeSyntax = " Int "
        let plan = DecodingPlan.dictionaryValuePadding(key: key, value: value)
        #expect(plan.decodingLine(name: "scores") ==
            "self.scores = LenientDecoding.nilPadding(String.self, Int.self, in: container, forKey: .scores, decoder: decoder)")
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

@Suite("Dictionary fix-it factories")
struct DictionaryFixItTests {
    private func binding(_ decl: String) throws -> PatternBindingSyntax {
        let varDecl = try #require(DeclSyntax(stringLiteral: decl).as(VariableDeclSyntax.self))
        return try #require(varDecl.bindings.first)
    }

    private func rewrittenType(of fixIt: FixIt?) throws -> String {
        let change = try #require(fixIt?.changes.first)
        guard case .replace(_, let newNode) = change else {
            Issue.record("expected a replace change"); return ""
        }
        return newNode.trimmedDescription
    }

    @Test("makeValuesOptional: [K: V] → [K: V?]")
    func valuesOptional() throws {
        let b = try binding("var x: [String: Int]")
        let key: TypeSyntax = "String", value: TypeSyntax = "Int"
        #expect(try rewrittenType(of: LenientFixItHelperMethods.makeValuesOptional(b, key: key, value: value)) == "[String: Int?]")
    }

    @Test("makeValuesOptionalKeepingOuter: [K: V]? → [K: V?]?")
    func valuesOptionalKeepingOuter() throws {
        let b = try binding("var x: [String: Int]?")
        let key: TypeSyntax = "String", value: TypeSyntax = "Int"
        #expect(try rewrittenType(of: LenientFixItHelperMethods.makeValuesOptionalKeepingOuter(b, key: key, value: value)) == "[String: Int?]?")
    }

    @Test("makePlainDictionary: [K: V?]? → [K: V]")
    func plainDictionary() throws {
        let b = try binding("var x: [String: Int?]?")
        let key: TypeSyntax = "String", value: TypeSyntax = "Int"
        #expect(try rewrittenType(of: LenientFixItHelperMethods.makePlainDictionary(b, key: key, value: value)) == "[String: Int]")
    }

    @Test("makeKeyNonOptional: [K?: V] → [K: V]")
    func keyNonOptional() throws {
        let b = try binding("var x: [String?: Int]")
        #expect(try rewrittenType(of: LenientFixItHelperMethods.makeKeyNonOptional(b)) == "[String: Int]")
    }

    @Test("makeKeyNonOptional preserves outer optional and value spelling: [K?: V?]? → [K: V?]?")
    func keyNonOptionalPreservesRest() throws {
        let b = try binding("var x: [String?: Int?]?")
        #expect(try rewrittenType(of: LenientFixItHelperMethods.makeKeyNonOptional(b)) == "[String: Int?]?")
    }

    @Test("makeKeyNonOptional returns nil when the key is already non-optional — never a no-op fix-it")
    func keyNonOptionalRefusesNoOp() throws {
        let b = try binding("var x: [String: Int]")
        #expect(LenientFixItHelperMethods.makeKeyNonOptional(b) == nil)
    }

    @Test("makeKeyNonOptional returns nil for a non-dictionary type")
    func keyNonOptionalRefusesNonDictionary() throws {
        let b = try binding("var x: Int")
        #expect(LenientFixItHelperMethods.makeKeyNonOptional(b) == nil)
    }
}
