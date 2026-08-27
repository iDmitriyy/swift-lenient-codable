//
//  LenientDecodingIssue.swift
//  LenientCodable
//
//  Created by Dmitriy Ignatyev on 26.08.2026.
//

/// A single structured issue for a lenient decoding failure.
/// Contains all context needed for debugging and monitoring.
///
/// One ``LenientDecodingLogEntry`` (per decoded object) collects multiple
/// ``LenientDecodingIssue`` instances – one for each absorbed failure.
public struct LenientDecodingIssue: Sendable {
  /// Stable string used as the dictionary key in ``LenientDecodingLogEntry/propertyDecodingIssues``.
  ///
  /// For property-level failures (`@NilOnFailure`, `@Strict`), this is the lookup key.
  /// To group all element failures of the same collection, `append(elementError:forCollectionKey:container:strategy:identityPrefix:)`
  /// computes a separate identity without element key / index.
  internal let errorIdentity: String

  /// Category of the failure (see ``LenientDecodingIssueCode``).
  public let code: LenientDecodingIssueCode
  
  /// The underlying error from the `DecodingError.Context`, if available.
  /// This is the error that caused the decoding failure (e.g. a date parsing error
  /// that triggered a `typeMismatch`), not the `DecodingError` itself.
  public let underlyingError: (any Error)?
  
  /// Additional metadata. Includes `"strategy"` (e.g. `"@NilOnFailure"`).
  ///
  /// Examples:
  /// - `"contextDebugDescription"` – the `DecodingError.Context.debugDescription`.
  /// - `"expectedType"` – the type that was expected (for `typeMismatch`/`valueNotFound`).
  /// - `"missingKey"` – the absent key (for `keyNotFound`).
  public internal(set) var info: [String: any Sendable & CustomStringConvertible & Encodable]
  
  internal init(errorIdentity: String,
                severity: LenientDecodingLogSeverity,
                code: LenientDecodingIssueCode,
                path: String,
                decodingStrategy: String,
                underlyingError: (any Error)?,
                info: consuming[String: any Sendable & CustomStringConvertible & Encodable]) {
    info["severity"] = "\(severity)"
    info["code"] = "\(code)"
    info["path"] = path
    info["decodingStrategy"] = decodingStrategy
    if let underlyingError {
      let descriptions = [
        ("underlyingErrorDebugDescription", String(reflecting: underlyingError)),
        ("underlyingErrorLocalizedDescription", underlyingError.localizedDescription),
        ("underlyingErrorDescription", String(describing: underlyingError)),
      ]
      var added = Set<String>()
      for (name, description) in descriptions {
        if !added.contains(description) {
          info[name] = description
          added.insert(description)
        }
      }
    }
    self.errorIdentity = errorIdentity
    self.code = code
    self.underlyingError = underlyingError
    self.info = info
  }
}

// MARK: DecodingError as Issue

extension DecodingError {
  /// Converts a `DecodingError` into a structured ``LenientDecodingIssue``.
  internal func asIssue(decodingStrategy: String, severity: LenientDecodingLogSeverity) -> LenientDecodingIssue {
    let contextDebugDescrKey = "contextDebugDescription"
    switch self {
    case let .typeMismatch(type, context):
      let contextPath = context.codingPathDotJoinedString
      return LenientDecodingIssue(errorIdentity: errorIdentity(prefix: "typeMismatch", path: contextPath),
                                  severity: severity,
                                  code: .typeMismatch,
                                  path: contextPath,
                                  decodingStrategy: decodingStrategy,
                                  underlyingError: context.underlyingError,
                                  info: [contextDebugDescrKey: context.debugDescription, "expectedType": "\(type)"])

    case let .keyNotFound(key, context):
      let contextPath = context.codingPathDotJoinedString
      return LenientDecodingIssue(errorIdentity: errorIdentity(prefix: "keyNotFound", path: contextPath),
                                  severity: severity,
                                  code: .keyNotFound,
                                  path: contextPath,
                                  decodingStrategy: decodingStrategy,
                                  underlyingError: context.underlyingError,
                                  info: [contextDebugDescrKey: context.debugDescription, "missingKey": "\(key)"])

    case let .valueNotFound(type, context):
      let contextPath = context.codingPathDotJoinedString
      return LenientDecodingIssue(errorIdentity: errorIdentity(prefix: "valueNotFound", path: contextPath),
                                  severity: severity,
                                  code: .valueNotFound,
                                  path: contextPath,
                                  decodingStrategy: decodingStrategy,
                                  underlyingError: context.underlyingError,
                                  info: [contextDebugDescrKey: context.debugDescription, "expectedType": "\(type)"])

    case .dataCorrupted(let context):
      let contextPath = context.codingPathDotJoinedString
      return LenientDecodingIssue(errorIdentity: errorIdentity(prefix: "dataCorrupted", path: contextPath),
                                  severity: severity,
                                  code: .dataCorrupted,
                                  path: contextPath,
                                  decodingStrategy: decodingStrategy,
                                  underlyingError: context.underlyingError,
                                  info: [contextDebugDescrKey: context.debugDescription])

    @unknown default:
      return LenientDecodingIssue(errorIdentity: "unknown:\(Self.self):" + decodingStrategy,
                                  severity: severity,
                                  code: .unknownDecodingError,
                                  path: "",
                                  decodingStrategy: decodingStrategy,
                                  underlyingError: nil,
                                  info: [:])
    }
  }
}

/// Builds a stable string identity for an issue from a prefix and coding path.
internal func errorIdentity(prefix: String, path: String) -> String {
  prefix + ":" + path
}

extension DecodingError.Context {
  /// The coding path rendered as a dot-joined string.
  package var codingPathDotJoinedString: String {
    codingPath.map { $0.stringValue }.joined(separator: ".")
  }
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Issue Code

/// Error codes for categorizing lenient decoding failures.
/// These are stable identifiers used for filtering and aggregation.
/// Values match `DecodingError` codes where applicable (0-29), then lenient-specific (30+).
public enum LenientDecodingIssueCode: Int, Sendable {
  /// Key is absent from JSON object.
  /// Maps to `DecodingError.keyNotFound`.
  ///
  /// **Example:** JSON `{"name": "John"}` decoding `status: Status?`
  case keyNotFound = 10

  /// Key exists but JSON value is `null`.
  /// Maps to `DecodingError.valueNotFound`.
  ///
  /// **Example:** JSON `{"status": null}` decoding `status: Status?`
  case valueNotFound = 11

  /// JSON value type doesn't match expected type.
  /// Maps to `DecodingError.typeMismatch`. Most common error.
  ///
  /// **Example:** JSON `{"status": 123}` decoding `status: Status?` (expects String)
  case typeMismatch = 20

  /// JSON structure corrupted/unreadable.
  /// Maps to `DecodingError.dataCorrupted`. Rare.
  ///
  /// **Example:** JSON `{"date": "not-a-date"}` decoding `date: Date` with custom strategy
  case dataCorrupted = 21

  /// Array element failed to decode (malformed, wrong type, etc.).
  /// Used by `@NilOnFailure` and `@DropOnFailure`.
  ///
  /// **Example:** JSON `{"docs": [{"type": "a"}, 5, {"type": "c"}]}` decoding `docs: [Doc?]`
  case droppedElement = 30

  /// Container type mismatch (expected array, got object; expected object, got string).
  /// Occurs when `nestedUnkeyedContainer` or `nestedContainer` fails.
  case invalidContainer = 40

  /// Two distinct JSON keys convert to the same `T` (collision after conversion).
  /// First wins, subsequent dropped.
  ///
  /// **Example:** JSON `{"tags": {"7": {"type": "a"}, "07": {"type": "b"}}}` decoding `tags: [Int: Doc]`
  case keyCollision = 41

  /// A `DecodingError` case not mapped to a specific code.
  case unknownDecodingError = 50

  /// Internal-only: a synthetic issue created by infrastructure code
  /// (e.g. double injection, invalid userInfo type). Not a real decode failure.
  case unexpectedCodeEntrance = 100
}
