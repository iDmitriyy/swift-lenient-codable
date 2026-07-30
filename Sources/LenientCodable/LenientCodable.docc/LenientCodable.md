# ``LenientCodable``

Swift macros for resilient `Codable` — one unknown enum case or malformed array element no longer fails your whole response.

## Overview

Swift's synthesized `Codable` decoding is all-or-nothing: one surprise anywhere in the payload and the entire response throws. `LenientCodable` inverts the default — an annotated struct decodes *through* surprises, failures degrade into `nil` (or dropped elements) exactly where they happened, and every fallback is reported in debug builds.

```swift
import LenientCodable

@LenientDecodable
struct LendingApplicationResponse {
    @Strict var applicationId: String              // decode fails if this fails
    var status: ApplicationStatus?                 // lenient by default: nil on any failure
    @NilOnFailure var documents: [Document?]       // failed elements → nil in place
    @DropOnFailure var offers: [LoanOffer]         // failed elements → removed
}
```

Every stored property without an annotation is implicitly ``NilOnFailure()``, which requires the type to have a nil-shaped hole for the failure to land in — `T?`, `[T?]`, `[T?]?`, `[K: V?]`, or `[K: V?]?`. Any other shape is a compile error with fix-its, so **nothing is silently strict and nothing is silently lenient**: every property's failure behavior is readable at its declaration, and the compiler enforces that the accounting is complete.

The one-sentence philosophy: **lenient about values, strict about structure — and you pick per property whether "strict" means throw.**

### Choosing an annotation

| Annotation | Applies to | On failure | Can fail the decode? |
|---|---|---|---|
| *(none)* / ``NilOnFailure()`` | `T?`, `[T?]`, `[T?]?`, `[K: V?]`, `[K: V?]?` | `nil` exactly where it broke | never |
| ``DropOnFailure()`` | `[T]`, `[K: V]` | element/entry removed | never |
| ``Strict()`` | any type | throws | **yes — the only way** |

Dictionary keys convert from JSON object keys through `LenientDictionaryKey` (`String` and `Int` conform out of the box; a `RawRepresentable` enum opts in with one line). A key that fails to convert always drops its entry — a key has no nil-shaped hole to pad.

### Observability

Leniency without observability would just be silent data loss. In DEBUG builds every absorbed failure — including missing keys — is logged via `os.Logger` under subsystem `LenientCodable`, category `decoding`; an explicit JSON `null` is the one intentional silent case. Release builds compile the logging out entirely.

```sh
log stream --predicate 'subsystem == "LenientCodable"' --level error
```

## Topics

### The type-level macro

- ``LenientDecodable()``

### Property annotations

- ``NilOnFailure()``
- ``DropOnFailure()``
- ``Strict()``
