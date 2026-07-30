//
//  LenientFixItBuilder.swift
//  LenientCodable
//
//  Created by Omar Elsayed on 19/07/2026.
//

import SwiftSyntax
import SwiftDiagnostics

/// Factories for every fix-it the `LenientDiagnostic` errors attach — the
/// one-click rewrites Xcode offers next to each rejection.
///
/// The helpers come in two families, matching the two things a user can
/// change to satisfy the macro:
///
/// - **Type rewrites** — reshape the property's declared type so the current
///   strategy becomes valid: ``makeOptional(_:)``,
///   ``makeElementsOptional(_:element:)``,
///   ``makeElementsOptionalKeepingOuter(_:element:)``,
///   ``makePlainArray(_:element:)``, and their dictionary counterparts
///   ``makeValuesOptional(_:key:value:)``,
///   ``makeValuesOptionalKeepingOuter(_:key:value:)``,
///   ``makePlainDictionary(_:key:value:)``, ``makeKeyNonOptional(_:)``.
/// - **Annotation changes** — keep the type and switch the strategy instead:
///   ``addAnnotation(_:to:)`` (implicit strategy, nothing to replace) and
///   ``replaceAnnotation(_:with:)`` (explicit annotation, rewritten in
///   place). A shape error usually attaches one fix-it from each family, so
///   the user picks which side to change.
///
/// Every helper returns a single-change `FixIt` that replaces one exact
/// syntax node, with its message drawn from `LenientFixItMessage`. The
/// recurring theme is **trivia preservation**: replacing a node also replaces
/// its attached whitespace and comments, so each factory copies the old
/// node's leading/trailing trivia onto the replacement — an applied fix-it
/// must never disturb the surrounding formatting.
///
/// The type-rewrite helpers return `nil` when the binding has no type
/// annotation to rewrite; callers `compactMap` the fix-it list, so an
/// inapplicable fix-it silently drops out of the diagnostic.
enum LenientFixItHelperMethods {
    /// `T` → `T?` — gives a whole-value `@NilOnFailure` property its
    /// nil-shaped hole. Attached to the `requiresOptional` diagnostic.
    static func makeOptional(_ binding: PatternBindingSyntax) -> FixIt? {
        guard let old = binding.typeAnnotation?.type else { return nil }
        let new = preservingTrivia(TypeSyntax(OptionalTypeSyntax(wrappedType: old.trimmed)), from: old)
        return replaceType(old: old, new: new)
    }

    /// `[E]` → `[E?]` — gives each element the nil-shaped hole that
    /// element padding writes into. Attached to the
    /// `arrayRequiresOptionalElements` diagnostic on a plain array.
    static func makeElementsOptional(_ binding: PatternBindingSyntax, element: TypeSyntax) -> FixIt? {
        guard let old = binding.typeAnnotation?.type else { return nil }
        let new = preservingTrivia(TypeSyntax(ArrayTypeSyntax(element: OptionalTypeSyntax(wrappedType: element.trimmed))), from: old)
        return replaceType(old: old, new: new)
    }

    /// `[E]?` → `[E?]?` — adds the element hole, deliberately KEEPING the
    /// outer optional the user already declared: they said "an absent list is
    /// `nil`", and the fix-it must not silently revoke that. Attached to the
    /// `arrayRequiresOptionalElements` diagnostic on an optional array.
    static func makeElementsOptionalKeepingOuter( _ binding: PatternBindingSyntax, element: TypeSyntax) -> FixIt? {
        guard let old = binding.typeAnnotation?.type else { return nil }
        let new = preservingTrivia(
            TypeSyntax(
                OptionalTypeSyntax(
                    wrappedType: ArrayTypeSyntax(
                        element: OptionalTypeSyntax(
                            wrappedType: element.trimmed
                        )
                    )
                )
            ),
            from: old
        )

        return replaceType(old: old, new: new)
    }

    /// `[E]?` → `[E]` and `[E?]` → `[E]` — strips the optionality that
    /// `@DropOnFailure` has no use for (a missing key already decodes as `[]`,
    /// and dropped elements leave no `nil` behind). Attached to the
    /// `dropRequiresNonOptionalArrayOrDictionary` and `dropRequiresNonOptionalElements`
    /// diagnostics.
    static func makePlainArray(_ binding: PatternBindingSyntax, element: TypeSyntax) -> FixIt? {
        guard let old = binding.typeAnnotation?.type else { return nil }
        let new = preservingTrivia(TypeSyntax(ArrayTypeSyntax(element: element.trimmed)), from: old)
        return replaceType(old: old, new: new)
    }

    /// `[K: V]` → `[K: V?]` — gives each value the nil-shaped hole that
    /// value padding writes into. Attached to the
    /// `dictionaryRequiresOptionalValues` diagnostic on a plain dictionary.
    static func makeValuesOptional(_ binding: PatternBindingSyntax, key: TypeSyntax, value: TypeSyntax) -> FixIt? {
        guard let old = binding.typeAnnotation?.type else { return nil }
        let new = preservingTrivia(
            TypeSyntax(
                DictionaryTypeSyntax(
                    key: key.trimmed,
                    colon: .colonToken(trailingTrivia: .space),
                    value: OptionalTypeSyntax(wrappedType: value.trimmed)
                )
            ),
            from: old
        )

        return replaceType(old: old, new: new)
    }

    /// `[K: V]?` → `[K: V?]?` — adds the value hole, deliberately KEEPING
    /// the outer optional the user already declared. Attached to the
    /// `dictionaryRequiresOptionalValues` diagnostic on an optional dictionary.
    static func makeValuesOptionalKeepingOuter(_ binding: PatternBindingSyntax, key: TypeSyntax, value: TypeSyntax) -> FixIt? {
        guard let old = binding.typeAnnotation?.type else { return nil }
        let new = preservingTrivia(
            TypeSyntax(
                OptionalTypeSyntax(
                    wrappedType: DictionaryTypeSyntax(
                        key: key.trimmed,
                        colon: .colonToken(trailingTrivia: .space),
                        value: OptionalTypeSyntax(wrappedType: value.trimmed)
                    )
                )
            ),
            from: old
        )

        return replaceType(old: old, new: new)
    }

    /// `[K: V?]` / `[K: V]?` / `[K: V?]?` → `[K: V]` — strips the
    /// optionality `@DropOnFailure` has no use for. Attached to the
    /// `dropRequiresNonOptionalValues` and `dropRequiresNonOptionalArrayOrDictionary`
    /// diagnostics on dictionary shapes.
    static func makePlainDictionary(_ binding: PatternBindingSyntax, key: TypeSyntax, value: TypeSyntax) -> FixIt? {
        guard let old = binding.typeAnnotation?.type else { return nil }
        let new = preservingTrivia(
            TypeSyntax(
                DictionaryTypeSyntax(
                    key: key.trimmed,
                    colon: .colonToken(trailingTrivia: .space),
                    value: value.trimmed
                )
            ),
            from: old
        )

        return replaceType(old: old, new: new)
    }

    /// `[K?: V]` → `[K: V]` — removes the key optionality (preserving the
    /// value's spelling and any outer optional): a failed key always drops
    /// its entry, so the `?` buys nothing. Attached to the
    /// `optionalDictionaryKey` diagnostic.
    ///
    /// Unlike the other type rewrites, this factory re-derives structure from
    /// the written type, so it also returns `nil` when the type isn't a
    /// dictionary or its key has no optionality to strip — a fix-it must
    /// never offer a no-op rewrite.
    static func makeKeyNonOptional(_ binding: PatternBindingSyntax) -> FixIt? {
        guard let old = binding.typeAnnotation?.type else { return nil }

        let new: TypeSyntax
        if let outer = old.as(OptionalTypeSyntax.self), let dictionary = outer.wrappedType.as(DictionaryTypeSyntax.self), let stripped = strippingOptionalKey(dictionary) {
            new = TypeSyntax(OptionalTypeSyntax(wrappedType: stripped))
        } else if let dictionary = old.as(DictionaryTypeSyntax.self), let stripped = strippingOptionalKey(dictionary) {
            new = TypeSyntax(stripped)
        } else {
            return nil
        }

        return replaceType(old: old, new: preservingTrivia(new, from: old))
    }

    // MARK: Annotation changes
    /// Prepends `@Name ` to the property declaration — used when the strategy
    /// was implicit, so there is no annotation node to replace.
    ///
    /// The declaration's leading trivia (indentation, doc comments) migrates
    /// onto the new attribute so it lands exactly where the declaration used
    /// to begin, e.g. `var id: Int` → `@Strict var id: Int`.
    static func addAnnotation(_ name: String, to varDecl: VariableDeclSyntax) -> FixIt {
        var attribute = AttributeSyntax(attributeName: TypeSyntax(IdentifierTypeSyntax(name: .identifier(name))))
        attribute.trailingTrivia = .space

        var newDecl = varDecl
        attribute.leadingTrivia = varDecl.leadingTrivia
        newDecl.leadingTrivia = Trivia()
        newDecl.attributes = varDecl.attributes + [.attribute(attribute)]

        return FixIt(
            message: LenientFixItMessage.addAnnotation(name),
            changes: [.replace(oldNode: Syntax(varDecl), newNode: Syntax(newDecl))])
    }

    /// Rewrites an existing marker annotation's name in place:
    /// `@NilOnFailure` → `@Strict`. The attribute's own trivia (position,
    /// spacing) is carried over, so only the name changes.
    ///
    /// `LenientDecodableMacro.annotationFixIt(_:annotationNode:sourceDecl:)`
    /// picks between this and ``addAnnotation(_:to:)`` based on whether the
    /// strategy came from a written annotation or the implicit default.
    static func replaceAnnotation(_ attribute: AttributeSyntax, with name: String) -> FixIt {
        let newTypeSyntax = TypeSyntax(IdentifierTypeSyntax(name: .identifier(name)))
        var newAttribute = AttributeSyntax(newTypeSyntax)
        newAttribute.leadingTrivia = attribute.leadingTrivia
        newAttribute.trailingTrivia = attribute.trailingTrivia

        return FixIt(
            message: LenientFixItMessage.replaceAnnotation(with: name),
            changes: [.replace(oldNode: Syntax(attribute), newNode: Syntax(newAttribute))]
        )
    }

    // MARK: Missing type annotation
    /// `var x = 0` → `var x: <#Type#> = 0` — the editor-placeholder token
    /// renders as a fill-in-the-blank in Xcode. Attached to the
    /// `missingTypeAnnotation` diagnostic; the macro can't infer the type
    /// from the initializer (it sees syntax, not types), so the fix-it can
    /// only hand the user the spot to fill in.
    static func addTypePlaceholder(to binding: PatternBindingSyntax) -> FixIt {
        var newBinding = binding
        var pattern = binding.pattern
        pattern.trailingTrivia = Trivia()
        newBinding.pattern = pattern
        newBinding.typeAnnotation = TypeAnnotationSyntax(
            type: TypeSyntax(
                IdentifierTypeSyntax(name: .identifier("<#Type#>"))
            ),
            trailingTrivia: .space
        )

        return FixIt(
            message: LenientFixItMessage.addTypeAnnotation,
            changes: [.replace(
                oldNode: Syntax(binding),
                newNode: Syntax(newBinding)
            )]
        )
    }

    // MARK: ReplaceType
    /// Wraps a type substitution in a `FixIt` whose message spells out the
    /// exact before/after ("change '[String]' to '[String?]'"), so the user
    /// can judge the rewrite from the fix-it popup alone.
    private static func replaceType(old: TypeSyntax, new: TypeSyntax) -> FixIt {
        FixIt(
            message: LenientFixItMessage.changeType(
                from: old.trimmedDescription, to: new.trimmedDescription),
            changes: [.replace(oldNode: Syntax(old), newNode: Syntax(new))])
    }

    /// Copies the old type's leading/trailing trivia onto its replacement.
    /// The rewritten types are built from `.trimmed` nodes, so without this
    /// step an applied fix-it would eat the spacing (and any comments) around
    /// the original type.
    private static func preservingTrivia(_ new: TypeSyntax, from old: TypeSyntax) -> TypeSyntax {
        var node = new
        node.leadingTrivia = old.leadingTrivia
        node.trailingTrivia = old.trailingTrivia
        return node
    }

    private static func strippingOptionalKey(_ dictionary: DictionaryTypeSyntax) -> DictionaryTypeSyntax? {
        guard let optionalKey = dictionary.key.as(OptionalTypeSyntax.self) else { return nil }
        var new = dictionary
        new.key = optionalKey.wrappedType.trimmed
        return new
    }
}
