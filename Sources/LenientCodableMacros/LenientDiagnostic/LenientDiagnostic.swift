//
//  LenientDiagnostic.swift
//  LenientCodable
//
//  Created by Omar Elsayed on 19/07/2026.
//

import SwiftSyntax
import SwiftDiagnostics

/// The complete catalog of compile-time diagnostics `@LenientDecodable` can
/// emit — one case per rejection, so this file *is* the macro's error surface.
///
/// Every case carries its user-facing text in ``message``; the expansion code
/// in `LenientDecodableMacro` decides *where* to anchor it (the attribute, the
/// property's annotation, the type annotation, …) and which fix-its from
/// `LenientFixItHelperMethods` to attach. `LenientDecodableDiagnosticTests`
/// pins the exact message, anchor position, and fix-it list for each case.
///
/// The cases fall into two groups, mirroring the two validation stages of the
/// expansion:
///
/// - **Type-level** — the struct itself is unusable
///   (``structsOnly``, ``duplicateAttribute``, ``handWrittenInitFromDecoder``,
///   ``redundantConformance``), diagnosed before any property is inspected.
/// - **Property-level** — one stored property's annotation and declared shape
///   don't fit together (everything else), diagnosed per property so a struct
///   with three bad properties gets three diagnostics, not one.
///
/// All cases are errors except ``redundantConformance``, which is a warning —
/// see ``severity``.
enum LenientDiagnostic: DiagnosticMessage {
    // Type-level

    /// `@LenientDecodable` was attached to a class, enum, or actor.
    /// Anchored at the attribute itself. No fix-its — there is no mechanical
    /// rewrite from a reference type to a struct.
    case structsOnly

    /// `@LenientDecodable` appears more than once on the same type.
    /// Anchored at the *last* occurrence, the one to delete.
    case duplicateAttribute

    /// The struct declares its own `init(from:)`, which would collide with
    /// the initializer the macro generates. Anchored at the hand-written
    /// initializer. The user must choose: keep their initializer and drop the
    /// macro, or delete the initializer and let the macro own decoding.
    case handWrittenInitFromDecoder

    /// The struct writes `: Decodable` explicitly even though the macro adds
    /// that conformance. The only warning in the catalog — the code still
    /// compiles and behaves correctly.
    ///
    /// - Note: Currently never emitted; its emission site in the extension
    ///   macro is disabled pending a reliable way to detect the explicit
    ///   conformance.
    case redundantConformance

    // Property-level

    /// One property carries two or more marker annotations (`@NilOnFailure`,
    /// `@DropOnFailure`, `@Strict`) whose strategies contradict each other.
    /// Anchored at the second annotation; the message lists every annotation
    /// found, in source order.
    case multipleAnnotations(annotations: [String])

    /// `@NilOnFailure` semantics on a non-optional, non-array type `T` — there
    /// is no nil-shaped hole to absorb a failure into. Fix-its: make the type
    /// optional (`T` → `T?`), or opt out with `@Strict`.
    ///
    /// `implicit` is `true` when the strategy came from `@LenientDecodable`'s
    /// default rather than a written `@NilOnFailure`; the message then says
    /// "(applied by @LenientDecodable)" so the user isn't blamed for an
    /// annotation they never wrote, and the fix-it *adds* `@Strict` instead of
    /// replacing an existing annotation.
    case requiresOptional(implicit: Bool)

    /// `@NilOnFailure` semantics on `[T]` or `[T]?` — element padding writes
    /// `nil` in place, so the element type must be optional. Fix-its: make the
    /// elements optional (`[T]` → `[T?]`, keeping an outer optional if
    /// present), switch to `@DropOnFailure` (plain `[T]` only), or opt out
    /// with `@Strict`. Same `implicit` wording rule as ``requiresOptional(implicit:)``.
    case arrayRequiresOptionalElements(implicit: Bool)

    /// `@DropOnFailure` on something that is neither an array nor a
    /// dictionary (`T` or `T?`) — there is nothing to drop. Fix-it: replace
    /// with `@Strict`.
    case dropRequiresArrayOrDictionary

    /// `@DropOnFailure` on `[T]?` / `[T?]?` or `[K: V]?` / `[K: V?]?` — the
    /// outer optional is dead weight because a missing or `null` key already
    /// decodes as the empty collection (`[]` / `[:]`). Fix-its: make it a
    /// plain `[T]` (or `[K: V]`), or replace with `@Strict`.
    case dropRequiresNonOptionalArrayOrDictionary

    /// `@DropOnFailure` on `[T?]` — dropping and nil-padding are mutually
    /// exclusive answers to the same failure. Fix-its: make it a plain `[T]`,
    /// or replace with `@NilOnFailure` to keep the `nil` placeholders.
    case dropRequiresNonOptionalElements

    /// `@NilOnFailure` semantics on `[K: V]` or `[K: V]?` — value padding
    /// writes `nil` at the failed value's key, so the value type must be
    /// optional. Fix-its: make the values optional (`[K: V]` → `[K: V?]`,
    /// keeping an outer optional if present), switch to `@DropOnFailure`
    /// (plain `[K: V]` only), or opt out with `@Strict`. Same `implicit`
    /// wording rule as ``requiresOptional(implicit:)``.
    case dictionaryRequiresOptionalValues(implicit: Bool)

    /// `@DropOnFailure` on `[K: V?]` — dropping and nil-padding are mutually
    /// exclusive answers to the same failure. Fix-its: make it a plain
    /// `[K: V]`, or switch to `@NilOnFailure` to keep the `nil` placeholders.
    case dropRequiresNonOptionalValues

    /// A lenient strategy on a dictionary whose key type is optional
    /// (`[K?: V]`) — an entry whose key fails to decode is dropped, so an
    /// optional key has no meaning (and colliding `nil` keys would overwrite
    /// each other). Fix-it: make the key non-optional. `@Strict` is exempt:
    /// it decodes with synthesized behavior, whatever the key type.
    case optionalDictionaryKey

    /// The property's type is written longhand (`Optional<T>`, `Array<T>`,
    /// possibly module-qualified) — the macro classifies shapes purely
    /// syntactically and only understands the sugared forms `T?` and `[T]`.
    /// Anchored at the type annotation.
    case sugarSyntaxRequired

    /// A stored `var` has no type annotation (`var count = 0`). Macros see
    /// syntax, not inferred types, so the shape can't be classified. Fix-it:
    /// insert a `<#Type#>` editor placeholder.
    case missingTypeAnnotation

    /// The user-facing diagnostic text, rendered by Xcode and `swift build`
    /// at the anchor node the expansion chose.
    ///
    /// Wording conventions: annotation and type names are quoted
    /// (`'@Strict'`, `'[T]'`); when a rule has a *why*, it follows an em dash;
    /// implicit-strategy messages carry the "(applied by @LenientDecodable)"
    /// suffix so the blame lands on the macro's default, not the user.
    var message: String {
        switch self {
        case .structsOnly:
            return "'@LenientDecodable' can only be applied to a struct"

        case .duplicateAttribute:
            return "'@LenientDecodable' is already applied to this type"

        case .handWrittenInitFromDecoder:
            return "'@LenientDecodable' cannot be applied to a type that declares its own 'init(from:)'"

        case .redundantConformance:
            return "'@LenientDecodable' already adds the 'Decodable' conformance; the explicit conformance is redundant"

        case .multipleAnnotations(let annotations):
            let list = annotations.map { "'@\($0)'" }.joined(separator: ", ")
            return "property has multiple leniency annotations (\(list)); choose one"

        case .requiresOptional(let implicit):
            return "'@NilOnFailure'\(implicit ? " (applied by @LenientDecodable)" : "") requires an optional type"

        case .arrayRequiresOptionalElements(let implicit):
            return "'@NilOnFailure'\(implicit ? " (applied by @LenientDecodable)" : "") on an array requires optional elements — elements that fail to decode become 'nil' in place"

        case .dropRequiresArrayOrDictionary:
            return "'@DropOnFailure' can only be applied to an array or dictionary property"

        case .dropRequiresNonOptionalArrayOrDictionary:
            return "'@DropOnFailure' requires a non-optional array or dictionary — a missing or null key already decodes as '[]' / '[:]'"

        case .dropRequiresNonOptionalElements:
            return "'@DropOnFailure' requires non-optional elements — use '@NilOnFailure' to keep null placeholders"

        case .dictionaryRequiresOptionalValues(let implicit):
            return "'@NilOnFailure'\(implicit ? " (applied by @LenientDecodable)" : "") on a dictionary requires optional values — values that fail to decode become 'nil' at their key"

        case .dropRequiresNonOptionalValues:
            return "'@DropOnFailure' requires non-optional values — use '@NilOnFailure' to keep null placeholders"

        case .optionalDictionaryKey:
            return "dictionary keys cannot be optional — an entry whose key fails to decode is dropped"

        case .sugarSyntaxRequired:
            return "LenientCodable requires sugar syntax ('T?', '[T]') to determine leniency shape"

        case .missingTypeAnnotation:
            return "'@LenientDecodable' requires an explicit type annotation on stored properties"
        }
    }

    /// A stable identity for deduplication and `#expect`-style filtering,
    /// in the domain `LenientCodable`.
    ///
    /// The `id` is `String(describing: self)`, so associated values are part
    /// of the identity — `requiresOptional(implicit: true)` and
    /// `requiresOptional(implicit: false)` are distinct IDs, and each distinct
    /// annotation list in ``multipleAnnotations(annotations:)`` mints its own.
    var diagnosticID: MessageID {
        let id: String = String(describing: self)
        return MessageID(domain: "LenientCodable", id: id)
    }

    /// `.error` for every case except ``redundantConformance``.
    ///
    /// The line is deliberate: an error means "this would decode wrongly or
    /// not compile" (the generated `init(from:)` would collide, or a leniency
    /// strategy has no valid representation in the declared type), while the
    /// one warning flags something merely redundant that still behaves
    /// correctly.
    var severity: DiagnosticSeverity {
        switch self {
        case .redundantConformance:
            return .warning
        default:
            return .error
        }
    }
}
