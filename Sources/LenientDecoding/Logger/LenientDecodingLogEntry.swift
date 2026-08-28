//
//  LenientDecodingLogEntry.swift
//  LenientCodable
//
//  Created by Dmitriy Ignatyev on 26.08.2026.
//

// MARK: Log Entry

/// Accumulates all issues for a single decoded object.
/// One instance is created per decoded object.
///
/// Rate limiting is applied at two levels:
/// - **Per decoded object:** `perDecodingReportedFieldsLimit` caps the total number
///   of fields (properties + collections) with tracked issues. Overflow is tracked in
///   ``overflowedFieldIdentities``.
/// - **Per collection element:** `collectionElementIssuesLimit` caps the number
///   of per-element issues stored under a single collection. Overflow is
///   tracked in the `overflowCount` field of ``collectionElementIssues``.
public struct LenientDecodingLogEntry: Sendable {
  /// The highest severity encountered while decoding this object.
  /// Defaults to `.warning`; upgraded to `.failure` if any `@Strict` property fails.
  public private(set) var severity: LenientDecodingLogSeverity = .warning

  /// Issues keyed by their `errorIdentity` (e.g. `"keyNotFound:path.to.field"`).
  /// Capped at `perDecodingReportedFieldsLimit` entries per decoded object.
  public private(set) var propertyDecodingIssues: [String: LenientDecodingIssue] = [:]

  /// Per-collection element issues.
  ///
  /// Keyed by `"<identityPrefix>:" + collectionPath` (e.g. `"nilPadding:scores"`, `"dropOnFailure:orders"`).
  /// This key is computed locally, not from the issue's `errorIdentity`,
  /// because the `DecodingError` context includes the element index, making
  /// each issue's `errorIdentity` unique per element. Using that would
  /// split issues across multiple keys but we want them grouped by collection.
  /// Each value contains up to `collectionElementIssuesLimit` issues
  /// and an `overflowCount` for additional dropped elements beyond the limit.
  public private(set) var collectionElementIssues: [String: (issues: [LenientDecodingIssue], overflowCount: UInt)] = [:]

  /// Field identities for issues that could not be stored because the total
  /// per-object rate limit (`perDecodingReportedFieldsLimit`) was reached.
  /// This includes both property-level issues (from `@NilOnFailure`/`@Strict`)
  /// and collection element issues that couldn't create a new entry.
  public private(set) var overflowedFieldIdentities: Set<String> = []

  // MARK: - Rate Limits
  
  private let perDecodingReportedFieldsLimit: UInt8
  private let collectionElementIssuesLimit: UInt8

  /// `true` when the combined count of `propertyDecodingIssues` and
  /// `collectionElementIssues` has reached `perDecodingReportedFieldsLimit`.
  private var isPerDecodingReportedFieldsLimitReached: Bool {
    (propertyDecodingIssues.count + collectionElementIssues.count) >= perDecodingReportedFieldsLimit
  }

  /// Creates a new entry, snapshotting the current rate limits from ``_rateLimits``.
  internal init() {
    let rateLimits = LenientErrorLogger._rateLimits
    perDecodingReportedFieldsLimit = rateLimits.perDecodingReportedFieldsLimit
    collectionElementIssuesLimit = rateLimits.elementsPerCollectionLimit
  }
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Append Issue

extension LenientDecodingLogEntry {
  /// Records a property-level decoding failure.
  ///
  /// If the total rate limit has not been reached, the issue is stored in
  /// ``propertyDecodingIssues``; otherwise only the `errorIdentity` is
  /// recorded in ``overflowedFieldIdentities``.
  ///
  /// - Parameters:
  ///   - propertySingleValueDecodingError: The `DecodingError` absorbed by a `LenientDecoding`.
  ///   - decodingStrategy: The strategy annotation (e.g. `"@Strict"`).
  ///   - severity: The severity of this issue (`.warning` for lenient, `.failure` for `@Strict`).
  package mutating func append(propertySingleValueDecodingError: DecodingError,
                               decodingStrategy: String,
                               severity: LenientDecodingLogSeverity) {
    self.severity.upgradeBy(severity)
    let issue = propertySingleValueDecodingError.asIssue(decodingStrategy: decodingStrategy, severity: severity)
    if isPerDecodingReportedFieldsLimitReached {
      overflowedFieldIdentities.insert(issue.errorIdentity)
    } else {
      propertyDecodingIssues[issue.errorIdentity] = issue
    }
  }

  /// Records a dictionary value decoding failure for a specific key.
  package mutating func append<Key: CodingKey>(dictionaryValueError: DecodingError,
                                               dictionaryPropertyKey key: Key,
                                               keyedContainer: KeyedDecodingContainer<Key>,
                                               strategy: String,
                                               severity: LenientDecodingLogSeverity) {
    let identity = errorIdentity(prefix: strategy, path: loggingPath(ofKeyedContainer: keyedContainer, key: key))
    append(elementError: dictionaryValueError, identity: identity, strategy: strategy, severity: severity)
  }

  /// Records an array element decoding failure for a specific index.
  package mutating func append(arrayElementError: DecodingError,
                               arrayPropertyKey key: some CodingKey,
                               unkeyedContainer: UnkeyedDecodingContainer,
                               strategy: String,
                               severity: LenientDecodingLogSeverity) {
    let identity = errorIdentity(prefix: strategy, path: loggingPath(ofUnkeyedContainer: unkeyedContainer, key: key))
    append(elementError: arrayElementError, identity: identity, strategy: strategy, severity: severity)
  }
  
  /// Records a collection element error for a specific array or dictionary key.
  ///
  /// Used by both ``LenientDecoding/nilPadding(_:in:forKey:decoder:)`` (for `[T?]`/`[T?]?`)
  /// and ``LenientDecoding/dropOnFailure(_:in:forKey:decoder:)`` (for `[T]`/`[K: V]`).
  ///
  /// The first ``collectionElementIssuesLimit`` issues per collection
  /// are stored in ``collectionElementIssues``; beyond that only an
  /// `overflowCount` is incremented. If the total rate limit has already been
  /// reached, the identity is added to ``overflowedFieldIdentities``
  /// instead of creating a new entry.
  ///
  /// - Parameters:
  ///   - elementError: The `DecodingError` absorbed for this element.
  ///   - identity: The stable identity key for grouping issues (e.g., `"@NilOnFailure:orders"`).
  ///     This is precomputed by the caller using the strategy name and the collection's coding path.
  ///     All failures sharing the same identity are grouped under one entry in ``collectionElementIssues``
  ///     with a shared `overflowCount`.
  ///   - strategy: The lenient strategy annotation (e.g. `"@DropOnFailure"`, `"@NilOnFailure"`).
  ///   - severity: The severity of this issue (`.warning` for lenient, `.failure` for `@Strict`).
  ///     Upgrades the log entry's overall severity via ``LenientDecodingLogSeverity/upgradeBy(_:)``.
  private mutating func append(elementError: DecodingError,
                               identity: String,
                               strategy: String,
                               severity: LenientDecodingLogSeverity) {
    self.severity.upgradeBy(severity)
    lazy var issue = elementError.asIssue(decodingStrategy: strategy, severity: severity)

    if let index = collectionElementIssues.index(forKey: identity) {
      if collectionElementIssues.values[index].issues.count < collectionElementIssuesLimit {
        collectionElementIssues.values[index].issues.append(issue)
      } else {
        collectionElementIssues.values[index].overflowCount += 1
      }
    } else {
      if isPerDecodingReportedFieldsLimitReached {
        // As total limit reached, it is not possible to add entry, so add info to ``overflowedFieldIdentities``
        // signaling that there were issues for Collection property as a whole instead of per-element info.
        overflowedFieldIdentities.insert(identity)
      } else {
        collectionElementIssues[identity, default: ([], 0)].issues.append(issue)
      }
    }
  }
}

/// Renders the full coding path of `key` inside `container` as a
/// dot-joined string (e.g. `"order.docs"` or `"orders.Index 2.status"`).
package func loggingPath<Key: CodingKey>(ofKeyedContainer container: KeyedDecodingContainer<Key>,
                                         key: Key) -> String {
  (container.codingPath + [key]).map { $0.stringValue }.joined(separator: ".")
}

package func loggingPath(ofUnkeyedContainer container: some UnkeyedDecodingContainer,
                         key: some CodingKey) -> String {
  (container.codingPath + [key]).map { $0.stringValue }.joined(separator: ".")
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Severity

/// The severity level of a lenient log entry.
///
/// Represents the highest-severity issue encountered while decoding a single object.
public enum LenientDecodingLogSeverity: String, Sendable, CustomStringConvertible {
  /// A lenient decoding issue occurred (absorbed by `@NilOnFailure` or `@DropOnFailure`).
  /// The decode succeeded but some data was substituted (`nil`, `[]`, dropped).
  case warning

  /// A decoding failure occurred from `@Strict` property.
  /// The decode threw and did not produce a value.
  case failure
  
  public var description: String { rawValue }

  /// Upgrades this severity if `newSeverity` is higher.
  internal mutating func upgradeBy(_ newSeverity: Self) {
    if self != .failure, newSeverity == .failure {
      self = .failure
    }
  }
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Synthetic issue

extension LenientDecodingLogEntry {
  internal static func internalsImpIssue(message: String,
                                         info: consuming [String: any Sendable & CustomStringConvertible & Encodable] = [:])
    -> Self {
    var entry = Self()
    info["internalsImpIssueMessage"] = message
    let code = LenientDecodingIssueCode.unexpectedCodeEntrance
    let issue = LenientDecodingIssue(errorIdentity: "\(code)",
                                     severity: .failure,
                                     code: code,
                                     path: "",
                                     decodingStrategy: "",
                                     underlyingError: nil,
                                     info: info)
    entry.propertyDecodingIssues[issue.errorIdentity] = issue
    return entry
  }

  /// Annotates issues in this entry with a `"pendingBufferOverflow"` info key.
  internal mutating func annotatePendingBufferOverflow(message: String) {
    let messageKey = "pendingBufferOverflow"
    if !propertyDecodingIssues.isEmpty {
      for index in propertyDecodingIssues.indices {
        propertyDecodingIssues.values[index].info[messageKey] = message
      }
    } else if !collectionElementIssues.isEmpty {
      for index in collectionElementIssues.indices where !collectionElementIssues.values[index].issues.isEmpty {
        collectionElementIssues.values[index].issues[0].info[messageKey] = message
      }
    }
  }
}
