//
//  AnyCodingKey.swift
//  LenientCodable
//
//  Created by Omar Elsayed on 29/07/2026.
//

/// A dynamic `CodingKey` that accepts any name — used to open a JSON object
/// whose keys are data (dictionary keys), not code (struct properties).
///
/// `stringValue` is the authoritative representation; `intValue` is a
/// best-effort courtesy for non-JSON decoders — key conversion goes through
/// `LenientDictionaryKey`, never through `intValue`.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = Int(stringValue)
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
