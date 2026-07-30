# LenientCodable
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FEngOmarElsayed%2Fswift-lenient-codable%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/EngOmarElsayed/swift-lenient-codable)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FEngOmarElsayed%2Fswift-lenient-codable%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/EngOmarElsayed/swift-lenient-codable)
![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen)
![License](https://img.shields.io/badge/License-MIT-green)

Swift macros for resilient `Codable` — one unknown enum case or malformed array element no longer fails your whole response. Lenient by default, strict by explicit opt-in, with compile-time diagnostics and fix-its.

```swift
import LenientCodable

@LenientDecodable
struct ApplicationResponse {
    @Strict var applicationId: String              // decode fails if this fails
    var status: Status?                 // lenient by default: nil on any failure
    @NilOnFailure var documents: [Document?]       // failed elements → nil in place
    @DropOnFailure var offers: [Offer]         // failed elements → removed
}

let response = try JSONDecoder().decode(ApplicationResponse.self, from: data)
```

- [The Problem](#the-problem)
- [Installation](#installation)
- [How It Works](#how-it-works)
- [What the Macro Writes](#what-the-macro-writes)
- [The Annotations](#the-annotations)
- [Dictionaries](#dictionaries)
- [Compile-Time Enforcement](#compile-time-enforcement)
- [Debug Logging](#debug-logging)
- [Rules & Edge Cases](#rules--edge-cases)
- [When NOT to Use This](#when-not-to-use-this)
- [Related Work](#related-work)
- [Requirements](#requirements)

## The Problem

Swift's synthesized `Codable` decoding is all-or-nothing. One surprise anywhere in the payload — the backend adds an enum case your compiled app doesn't know, one element in a 20-element array is malformed, one nested field changes shape — and the **entire** response throws. The bug ships silently and detonates the day the API evolves, usually in the oldest app version still installed.

`LenientCodable` inverts the default: an annotated struct decodes *through* surprises, failures degrade into `nil` (or dropped elements) exactly where they happened, and every fallback is logged in debug builds so nothing degrades invisibly during development.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/EngOmarElsayed/swift-lenient-codable.git", from: "1.0.0"),
]
```

Then add `LenientCodable` to your target's dependencies and `import LenientCodable`. On first build, Xcode asks you to **Trust & Enable** the macro target — macros are compiler plugins, and this is the standard one-time ceremony.

## How It Works

`@LenientDecodable` generates `CodingKeys`, `init(from:)`, and the `Decodable` conformance for a struct. Every stored property without an annotation is implicitly `@NilOnFailure`, which requires the type to have a nil-shaped hole for the failure to land in:

| Declared type | Behavior on failure |
|---|---|
| `T?` | whole value → `nil` |
| `[T?]` | failed element → `nil` **in place**, count preserved |
| `[T?]?` | as `[T?]`; an absent or unusable array → `nil` instead of `[]` |
| `[K: V?]` | failed value → `nil` **at its key**; failed key → entry dropped |
| `[K: V?]?` | as `[K: V?]`; an absent or unusable object → `nil` instead of `[:]` |
| `T`, `[T]`, `[T]?`, `[K: V]`, `[K: V]?` | ❌ compile error with fix-its — change the type, or opt out with `@Strict` |

That last row is the design's core guarantee: **nothing is silently strict and nothing is silently lenient.** Every property's failure behavior is readable at its declaration — lenient by visible type shape, or explicit by visible annotation — and the compiler enforces that the accounting is complete.

## What the Macro Writes

No hidden runtime magic: right-click → *Expand Macro* shows exactly what was generated. For the struct at the top of this page:

```swift
struct ApplicationResponse {
    var applicationId: String
    var status: Status?
    var documents: [Document?]
    var offers: [Offer]

    private enum CodingKeys: String, CodingKey {
        case applicationId
        case status
        case documents
        case offers
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.applicationId = try container.decode(String.self, forKey: .applicationId)
        // implicit @NilOnFailure (applied by @LenientDecodable)
        self.status = LenientDecoding.nilOnFailure(Status.self, in: container, forKey: .status, decoder: decoder)
        self.documents = LenientDecoding.nilPadding(Document.self, in: container, forKey: .documents, decoder: decoder)
        self.offers = LenientDecoding.dropOnFailure(Offer.self, in: container, forKey: .offers, decoder: decoder)
    }
}

extension ApplicationResponse: Decodable {}
```

Three things to notice: `@Strict` properties compile to plain `try container.decode` — the only lines that can throw; implicitly-lenient properties carry a provenance comment so expanded code shows *why* they're lenient; and the lenient helpers are ordinary public functions in the `LenientDecoding` module, callable from a hand-written `init(from:)` if you ever need to mix approaches manually.

## The Annotations

| Annotation | Applies to | On failure | Can fail the decode? |
|---|---|---|---|
| *(none)* / `@NilOnFailure` | `T?`, `[T?]`, `[T?]?`, `[K: V?]`, `[K: V?]?` | `nil` exactly where it broke | never |
| `@DropOnFailure` | `[T]`, `[K: V]` | element/entry removed | never |
| `@Strict` | any type | throws | **yes — the only way** |

### `@NilOnFailure` — nil where it broke

The default, written explicitly only as documentation. JSON `null` decodes silently as `nil` / `[]` — an explicit `null` is the backend saying "no value" on purpose. Anything else that goes wrong — a missing key, unknown enum raw value, type mismatch, malformed nested object — becomes `nil` at the exact position it occurred **and is reported in the debug log**.

On `[T?]`, count and positions are preserved, which makes incompleteness detectable in one line:

```swift
if documents.count != documents.compactMap({ $0 }).count {
    // something in the payload didn't parse — block submission, prompt an update
}
```

### `@DropOnFailure` — pretend it wasn't there

For `[T]` only. Failed elements (any reason, including `null`) are removed; survivors keep their order. The result is a clean non-optional array with zero `nil` handling at call sites — at the cost of erasing all in-value evidence that anything was dropped.

Dropping is a product decision, which is why it is **never applied by default**. Good fit: decorative lists — banners, tiles, recommendations. Poor fit: anything representing obligations or completeness (a required-documents checklist, a payment breakdown) — silently dropping an entry the user must act on misleads them. For those, prefer `@NilOnFailure` on `[T?]`.

### `@Strict` — synthesized behavior, on purpose

Byte-for-byte what plain `Codable` synthesis would do. Optionality covers *absence* only: a missing key or `null` decodes as `nil`, but a **present-and-broken value throws and fails the entire decode**. That absence-vs-failure distinction is the whole difference between `@Strict var x: [Int]?` and any lenient annotation.

In a `@LenientDecodable` struct, `@Strict` properties are the *only* way a decode can fail — `grep @Strict` audits every hard failure point, and the compiler guarantees the list is complete.

> ⚠️ On an enum property, synthesized decoding throws for an *unknown raw value* — meaning a new backend enum case will fail the decode. Use `@Strict` on enums from evolving APIs deliberately.

## Dictionaries

The same annotations extend to dictionaries, with one twist: an entry has **two** failure points — the key and the value — and they get different treatment.

**A failed key always drops its entry**, under every lenient strategy. That's forced by dictionary semantics, not policy: a key has no nil-shaped hole to pad `nil` into, and two failed keys would collide at the same slot. **A failed value follows the annotation**, exactly like an array element: `@NilOnFailure` pads `nil` at that key, `@DropOnFailure` removes the pair.

| Annotation | Shape | Failed value | Failed key |
|---|---|---|---|
| *(none)* / `@NilOnFailure` | `[K: V?]` | `nil` at that key | entry dropped |
| *(none)* / `@NilOnFailure` | `[K: V?]?` | as `[K: V?]`; an absent/unusable object → `nil` | entry dropped |
| `@DropOnFailure` | `[K: V]` | entry dropped (`null` too — non-optional `V` has nowhere to keep it) | entry dropped |
| `@Strict` | any dictionary | throws | throws |

Whole-value failures mirror arrays exactly: missing key → `[:]` (reported), JSON `null` → `[:]` (silent), value isn't an object → `[:]` (reported) — and the outer-optional shape (`[K: V?]?`) decodes `nil` instead of `[:]` in all three cases. Optional keys (`[K?: V]`) are a compile error under lenient strategies, fix-it removes the `?`.

### Keys: `LenientDictionaryKey`

JSON object keys are always strings on the wire, and Codable never exposes a decoder positioned on a key — so lenient dictionary decoding needs an explicit string → key contract:

```swift
public protocol LenientDictionaryKey: Hashable {
    init?(lenientKeyString: String)
}
```

`String` and `Int` conform out of the box, and `RawRepresentable` types with `String` or `Int` raw values get the implementation for free — an enum key opts in with one line:

```swift
enum Subject: String, Codable { case math, science }
extension Subject: LenientDictionaryKey {}
```

Any custom key joins the same way. Returning `nil` is not an error path — it *is* the key-level leniency hook: that entry is dropped and reported, and the rest of the dictionary survives.

```swift
extension UUID: LenientDictionaryKey {
    public init?(lenientKeyString: String) {
        self.init(uuidString: lenientKeyString)
    }
}
```

The conversion doesn't have to be injective: when two JSON keys convert to the same key (`"7"` and `"07"` as `Int`), one entry survives — which one is unspecified — and the collision is reported.

`LenientDictionaryKey` is a decode-only, failure-tolerant analogue of the standard library's `CodingKeyRepresentable`, back-deployed to this package's iOS 13 floor (`CodingKeyRepresentable` requires iOS 15.4).

### One payload, both failure points

```swift
@LenientDecodable
struct ReportCard {
    var scores: [Subject: Int?]   // implicitly @NilOnFailure
}
```

```json
{ "scores": { "math": 91, "science": "N/A", "alchemy": 60 } }
```

```swift
let card = try JSONDecoder().decode(ReportCard.self, from: json)
card.scores   // [.math: 91, .science: nil]
// "N/A" isn't an Int      → value failure → nil padded at .science (reported)
// "alchemy" isn't a Subject → key failure  → entry dropped          (reported)
```

One broken value and one unknown key, and the decode still hands you everything usable — under plain `Codable`, that payload would have thrown.

## Compile-Time Enforcement

The macro validates every property's type shape against its strategy and refuses to generate against an invalid spec. Errors arrive with fix-its enumerating your actual choices:

```swift
@LenientDecodable
struct Response {
    let count: Int
    // ❌ '@NilOnFailure' (applied by @LenientDecodable) requires an optional type
    //    fix-it: change 'Int' to 'Int?'
    //    fix-it: add '@Strict'

    let docs: [Doc]?
    // ❌ '@NilOnFailure' (applied by @LenientDecodable) on an array requires
    //    optional elements — elements that fail to decode become 'nil' in place
    //    fix-it: change '[Doc]?' to '[Doc?]?'
    //    fix-it: add '@Strict'
}
```

Also diagnosed: conflicting annotations on one property, `@DropOnFailure` anywhere but a plain `[T]` / `[K: V]`, optional dictionary keys (`[K?: V]`), longhand spellings (`Optional<T>`, `Array<T>`, `Dictionary<K, V>` — use sugar syntax), stored properties without a written type (macros can't see inferred types), a hand-written `init(from:)`, duplicate application, and applying the macro to anything but a struct. A redundant `: Decodable` on the struct is a warning.

## Debug Logging

Leniency without observability would just be silent data loss. Every absorbed failure logs in DEBUG builds via `os.Logger` (subsystem `LenientCodable`, category `decoding`; `print` on platforms without `os`):

```
decoded nil for 'status' — dataCorrupted(...)
decoded nil for 'status' — key not found
padded nil at element 2 of 'documents' — typeMismatch(...)
dropped element 1 of 'offers' — keyNotFound(...)
padded nil for entry "science" of 'scores' — typeMismatch(...)
dropped entry "alchemy" of 'scores' — key is not a valid Subject
```

Missing keys are reported (the backend omitting a field is worth knowing about); an explicit JSON `null` is the one silent case. Filter the firehose in Console.app or from the terminal:

```sh
log stream --predicate 'subsystem == "LenientCodable"' --level error
```

Release builds compile the logging out entirely — messages are never even constructed. Production degrades gracefully; development stays loud.

## Rules & Edge Cases

- **Structs only** (v1). Classes and enums are a compile error.
- **Skipped, never decoded:** `static` properties, computed properties, and `let` constants with an initializer — matching synthesis. Properties with `willSet`/`didSet` are stored and *are* decoded.
- **Your `CodingKeys` wins.** Declare your own enum (or typealias) named `CodingKeys` for custom key mappings and the macro references it instead of generating one.
- **Explicit types required.** `var x = 0` is an error: macros see syntax, not inferred types.
- **Sugar syntax required.** `T?` and `[T]`, not `Optional<T>` / `Array<T>`.
- **Leniency depth is one level.** Array elements and dictionary values are decoded as whole values — in `[String: [Int]]`, one bad `Int` fails that whole entry. For control *inside* an element or value type, make that type `@LenientDecodable` too and annotate its properties — leniency composes by nesting.

## When NOT to Use This

Leniency is for **API evolution**, not for hiding bugs. If a field's absence should be impossible — an ID, an amount in a payments flow — mark it `@Strict` and let a broken payload fail loudly. A decode that always succeeds while quietly producing `nil` amounts is strictly worse than a crash you find in QA. The debug logging exists precisely to keep that failure mode visible while you develop.

## Related Work

- [ResilientDecoding](https://github.com/airbnb/ResilientDecoding) (Airbnb) — property-wrapper approach with a rich error-introspection system.
- [BetterCodable](https://github.com/marksands/BetterCodable) — a grab bag of `Codable` property wrappers including `@LossyArray`.

`LenientCodable` differs in being macro-based: no wrapper types in your stored properties (so `Equatable`/`Hashable`/memberwise-init synthesis are untouched), compile-time shape validation with fix-its, lenient-by-default semantics with enforced total accounting, and generated code you can read with *Expand Macro*.

## Requirements

- Swift 6.2+ toolchain (Xcode 26+)
- Platforms: iOS 13+, macOS 10.15+, tvOS 13+, watchOS 6+, Mac Catalyst 13+

## License

MIT — see [LICENSE](LICENSE).
