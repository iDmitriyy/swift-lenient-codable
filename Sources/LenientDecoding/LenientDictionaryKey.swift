//
//  LenientDictionaryKey.swift
//  LenientCodable
//
//  Created by Omar Elsayed on 29/07/2026.
//

/// A dictionary key type the lenient dictionary helpers can build from a JSON
/// object key.
///
/// JSON object keys are always strings on the wire, and Codable never exposes
/// a decoder positioned on a key — so decoding `[K: V]` leniently needs an
/// explicit string → `K` contract. This is that contract: a decode-only,
/// failure-tolerant analogue of `CodingKeyRepresentable` (which requires
/// iOS 15.4; this package's floor is iOS 13).
///
/// Returning `nil` from the initializer is not an error path — it *is* the
/// leniency hook: the helpers drop that entry and report it, keeping the rest
/// of the dictionary.
///
/// `String` and `Int` conform out of the box. `RawRepresentable` types with
/// `String` or `Int` raw values get the implementation for free — an enum key
/// opts in with one line:
///
/// ```swift
/// extension Status: LenientDictionaryKey {}
/// ```
public protocol LenientDictionaryKey: Hashable {
    /// Creates the key from a JSON object key string, or returns `nil` when
    /// the string cannot represent this type (the entry is then dropped).
    init?(lenientKeyString: String)
}

extension String: LenientDictionaryKey {
    /// The identity conversion — never fails.
    public init?(lenientKeyString: String) {
        self = lenientKeyString
    }
}

extension Int: LenientDictionaryKey {
    /// Swift's standard string parse: accepts `"42"`, `"-7"`, `"+7"`,
    /// `"007"`; rejects whitespace, decimals, and non-numeric text.
    public init?(lenientKeyString: String) {
        self.init(lenientKeyString)
    }
}

public extension LenientDictionaryKey where Self: RawRepresentable, RawValue == String {
    /// Free implementation for `String`-raw types: the JSON key is the raw
    /// value, so an unknown raw value returns `nil` (entry dropped).
    init?(lenientKeyString: String) {
        self.init(rawValue: lenientKeyString)
    }
}

public extension LenientDictionaryKey where Self: RawRepresentable, RawValue == Int {
    /// Free implementation for `Int`-raw types: the JSON key is parsed as
    /// `Int` first, then matched as a raw value — either step failing
    /// returns `nil` (entry dropped).
    init?(lenientKeyString: String) {
        guard let raw = Int(lenientKeyString) else { return nil }
        self.init(rawValue: raw)
    }
}
