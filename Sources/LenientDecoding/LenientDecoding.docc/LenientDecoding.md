# ``LenientDecoding``

The runtime engine behind the `@LenientDecodable` macro — the lenient decoding helpers that macro-generated initializers call.

## Overview

Every lenient property in a `@LenientDecodable` struct decodes through one of the static helpers on ``LenientDecoding/LenientDecoding``. They are ordinary public functions over a `KeyedDecodingContainer`, so a hand-written `init(from:)` can call them directly next to strict `decode` calls:

```swift
init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(Int.self, forKey: .id)
    self.status = LenientDecoding.nilOnFailure(Status.self, in: container, forKey: .status, decoder: decoder)
}
```

No helper throws or returns an error: a failure is *absorbed* into the return value — `nil`, `[]`, `[:]`, a `nil` element or entry value, or a dropped element or entry — and simultaneously *reported* to the debug log. A missing key is reported too; an explicit JSON `null` is the one silent case.

Dictionary helpers convert JSON object keys to the declared key type through ``LenientDictionaryKey`` — `String` and `Int` conform out of the box, and `RawRepresentable` types with `String` or `Int` raw values opt in with a one-line conformance. A key that fails to convert drops its entry.

This module is re-exported by `LenientCodable`, so `import LenientCodable` is all you need.

## Topics

### The decoding helpers

- ``LenientDecoding/LenientDecoding``

### Dictionary keys

- ``LenientDictionaryKey``
