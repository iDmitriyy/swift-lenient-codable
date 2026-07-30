//
//  TypeSyntax+Extension.swift
//  LenientCodable
//
//  Created by Omar Elsayed on 18/07/2026.
//

import SwiftSyntax

extension TypeSyntax {
    func parseToTypeShape() -> TypeShape {
        if isLonghand() { return .unsupportedLonghand }

        // Unwrap one outer optional, if present.
        if let outerOptional = self.as(OptionalTypeSyntax.self) {
            let inner = outerOptional.wrappedType

            // isLonghand check
            if inner.isLonghand() { return .unsupportedLonghand }

            // [] check
            if let array = inner.as(ArrayTypeSyntax.self) {
                if array.element.isLonghand() { return .unsupportedLonghand }
                if let optionalElement = array.element.as(OptionalTypeSyntax.self) { return .optionalArrayOfOptionals(element: optionalElement.wrappedType) }

                return .optionalArray(element: array.element)
            }

            // [:] check
            if let dictionary = inner.as(DictionaryTypeSyntax.self) { return parseDictionaryShape(dictionary, outerOptional: true) }

            return .optional(wrapped: inner)
        }

        // Check if it's an array
        if let array = self.as(ArrayTypeSyntax.self) {
            if array.element.isLonghand() { return .unsupportedLonghand }
            if let optionalElement = array.element.as(OptionalTypeSyntax.self) { return .arrayOfOptionals(element: optionalElement.wrappedType) }

            return .array(element: array.element)
        }

        // Check if it's a dictionary
        if let dictionary = self.as(DictionaryTypeSyntax.self) { return parseDictionaryShape(dictionary, outerOptional: false) }

        return .plain(self)
    }

    private func parseDictionaryShape(_ dictionary: DictionaryTypeSyntax, outerOptional: Bool) -> TypeShape {
        if dictionary.key.isLonghand() || dictionary.value.isLonghand() { return .unsupportedLonghand }

        if let optionalValue = dictionary.value.as(OptionalTypeSyntax.self) {
            if optionalValue.wrappedType.isLonghand() { return .unsupportedLonghand }
            return outerOptional
                ? .optionalDictionaryOfOptionalValues(key: dictionary.key, value: optionalValue.wrappedType)
                : .dictionaryOfOptionalValues(key: dictionary.key, value: optionalValue.wrappedType)
        }

        return outerOptional
            ? .optionalDictionary(key: dictionary.key, value: dictionary.value)
            : .dictionary(key: dictionary.key, value: dictionary.value)
    }

    /// `Optional<...>` / `Array<...>` / `Dictionary<...>`, bare or
    /// module-qualified (`Swift.Optional<...>`). Anything else — including
    /// user types that merely have generic arguments (`Box<Int>`) — is not
    /// longhand.
    func isLonghand() -> Bool { // will be enhanced in V2
        let name: String?
        let hasGenerics: Bool
        
        if let identifier = self.as(IdentifierTypeSyntax.self) {
            name = identifier.name.text
            hasGenerics = identifier.genericArgumentClause != nil
        } else if let member = self.as(MemberTypeSyntax.self) {
            name = member.name.text
            hasGenerics = member.genericArgumentClause != nil
        } else {
            return false
        }

        return hasGenerics && (name == "Optional" || name == "Array" || name == "Dictionary")
    }
}
