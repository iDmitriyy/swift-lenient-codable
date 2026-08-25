//
//  LenientLogger.swift
//  LenientCodable
//
//  Created by Omar Elsayed on 19/07/2026.
//

import Foundation
import Synchronization
#if canImport(os)
  import os
#endif

/// The reporting channel for every leniency event in the package.
///
/// `LenientDecoding` never throws — a lenient decode "fails" by producing
/// `nil`, `[]`, or a dropped element instead. This logger is where that
/// swallowed evidence goes: every helper in ``LenientDecoding`` calls
/// ``log(_:)`` at the exact moment it absorbs a failure, so the log is the
/// *only* record that anything went wrong.
///
/// ## Behavior
///
/// Logging is compiled in **DEBUG builds only**; in release builds every call
/// is a no-op and the message is never even constructed (see ``log(_:)``).
///
/// On platforms with unified logging (iOS 14+, macOS 11+, tvOS 14+,
/// watchOS 7+, Mac Catalyst 14+), messages are emitted at `.error` level via
/// `os.Logger` under subsystem `LenientCodable`, category `decoding` — filter
/// on either in Console.app or with `log stream`:
///
/// ```sh
/// log stream --predicate 'subsystem == "LenientCodable"' --level error
/// ```
///
/// Everywhere else (older OS versions, non-Apple platforms), messages fall
/// back to `print` with a `[LenientCodable]` prefix.
///
/// - Note: This type is an implementation detail of the `LenientDecoding`
///   module. It has no cases and no instances — it is a namespace, not a
///   protocol hook, and there is currently no way to redirect its output.
enum LenientErrorLogger {
  /// Reports one absorbed decoding failure.
  ///
  /// Call sites describe what was substituted and where, in the shape
  /// `"<what happened> for '<coding path>' — <underlying error>"`, e.g.:
  ///
  /// ```
  /// decoded nil for 'order.status' — dataCorrupted(...)
  /// padded nil at element 2 of 'order.docs' — keyNotFound(...)
  /// ```
  ///
  /// - Parameter message: The report, taken as an `@autoclosure` so string
  ///   interpolation (often including an `Error` dump) is only evaluated
  ///   when a DEBUG build actually emits it. In release builds the closure
  ///   is never called.
  ///
  /// - Important: Messages are logged with `privacy: .public`, so decoded
  ///   payload fragments embedded in the underlying `DecodingError` appear
  ///   unredacted in the unified log. Do not route sensitive payloads
  ///   through it outside of local debugging.
  static func log(_ message: @escaping @autoclosure () -> String) {
    #if DEBUG
      #if canImport(os)
        if #available(iOS 14, macOS 11, tvOS 14, watchOS 7, macCatalyst 14, *) {
          Logger(subsystem: "LenientCodable", category: "decoding").error("\(message(), privacy: .public)")
          return
        }
      #endif
      print("[LenientCodable] \(message())")
    #endif
  }

  /// Renders the full coding path of `key` inside `container` as a
  /// dot-joined string — the `'order.docs'` part of every log message.
  ///
  /// The container's own `codingPath` (the walk from the JSON root to the
  /// container) is extended with `key`, and each component's `stringValue`
  /// is joined with `.`. A key at the top level therefore renders as just
  /// `"status"`; if the struct sits inside a JSON array, the synthesized
  /// index key appears in the path (e.g. `"orders.Index 2.status"`).
  ///
  /// - Parameters:
  ///   - container: The keyed container the failing value was read from.
  ///   - key: The key whose path is being reported.
  /// - Returns: The dot-joined path from the root to `key`.
  static func path<Key: CodingKey>(
    of container: KeyedDecodingContainer<Key>, key: Key,
  ) -> String {
    loggingPath(ofKeyedContainer: container, key: key)
  }
}

//===-------------------------------------------------------------------------------------------------------------------===//

/// The handler type for receiving lenient decoding log entries.
///
/// Injected once globally via ``inject_once(lenientDecodingLogger:rateLimits:...)``;
/// can be overridden per-decoder via ``JSONDecoder.setLenientDecodingLogger(_:)``.
///
/// **Behavior:**
/// - If a global logger is injected, it receives **all** lenient decoding failures
///   in both DEBUG and RELEASE builds.
/// - If no global logger is injected, DEBUG builds additionally log via `os.Logger` (iOS 14+,
///   macOS 11+, etc.) or `print` fallback. RELEASE builds are silent.
/// - Per-decoder loggers (set via `JSONDecoder.setLenientDecodingLogger(_:)`)
///   take precedence over the global logger for that decoder.
public typealias LenientDecodingLogger = @Sendable (LenientDecodingLogEntry) -> Void

// MARK: - Inject Logger Once

/// Injects the global log handler. Can only be called once.
/// Subsequent calls will log a ``LenientDecodingLogEntry`` instance via the existing handler.
///
/// The injected logger receives **all** lenient decoding failures in both
/// DEBUG and RELEASE builds. Without injection, DEBUG builds use the
/// internal `os.Logger`/`print` fallback and RELEASE builds are silent.
/// Per-decoder loggers (via `JSONDecoder.setLenientDecodingLogger(_:)`)
/// override the global logger for that decoder.
///
/// - Parameters:
///   - logger: The log handler to receive all lenient decoding errors.
///   - rateLimits: Optional custom rate limits. On macOS 15+/iOS 18+ these are
///     stored atomically and respected by every `LenientDecodingLogEntry` created
///     afterwards. On older OS versions the default `(3, 3)` is used and this
///     parameter is ignored.
///   - file: Source file (for assertion).
///   - line: Source line (for assertion).
public func inject_once(lenientDecodingLogger logger: @escaping LenientDecodingLogger,
                        rateLimits: (perDecodingReportedFieldsLimit: UInt8, elementsPerCollectionLimit: UInt8)? = nil,
                        file: StaticString = #file,
                        line: UInt = #line) {
  let (alreadyInjectedGlobalLogger, pendingEntries) = _globalLogger
    .withLock { variant -> (LenientDecodingLogger?, [LenientDecodingLogEntry]) in
      switch variant {
      case .injected(let injectedGlobalLogger):
        return (injectedGlobalLogger, [])
      case .pending(let pendingEntriesLogger):
        if #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *), let rateLimits {
          _rateLimits = rateLimits
        } // else {} // on older OS versions rate limit is constant and can not be overriden

        // Drain buffered entries and set forwarding single atomic transaction.
        // Stale references of `pendingEntriesLogger` after the drain route new entries
        // directly to `injected logger` instead of being silently lost.
        let pendingEntries = pendingEntriesLogger.extractPendingEntriesAndForwardNew(toInjectedLogger: logger)

        variant = .injected(logger)

        return (nil, pendingEntries)
      }
    }

  for entry in pendingEntries {
    logger(entry)
  }

  if let alreadyInjectedGlobalLogger {
    let message = "Attempted to inject lenient decoding logger more than once"
    let logEntry = LenientDecodingLogEntry.internalsImpIssue(message: message)
    // Intentionally call BOTH loggers: we cannot assume which
    // logger is the "real" destination for this error – the old one may
    // already be forwarding to the monitoring system, while the new one
    // may be the caller's debug sink. Both receive the logEntry so nothing
    // is silently lost.
    alreadyInjectedGlobalLogger(logEntry)
    logger(logEntry)
    assertionFailure(message, file: file, line: line)
  }
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Decoder Extension

extension JSONDecoder {
  /// Attaches a per-decoder log handler.
  ///
  /// When set, all lenient decoding failures decoded through this decoder
  /// are routed to `logger` instead of the global logger. Useful for
  /// isolating logs per decoder or for testing.
  ///
  /// - Parameter logger: The log handler to receive failures from this decoder.
  public func setLenientDecodingLogger(_ logger: @escaping LenientDecodingLogger) {
    userInfo[.lenientDecodingLogHandler] = _DecoderLoggerBox(loggerInstance: logger)
  }
}

extension Decoder {
  /// Returns either logger provided via `userInfo` or injected `globalLogger`.
  ///
  /// Checks `userInfo[.lenientDecodingLogHandler]` first. If a valid
  /// ``_DecoderLoggerBox`` is found its logger is returned. If the box is
  /// missing or has an invalid type, falls back to ``globalLogger`` and
  /// logs a logEntry instance about the misconfiguration.
  package var lenientDecodingLogger: LenientDecodingLogger {
    if let value = userInfo[.lenientDecodingLogHandler] {
      if let loggerBox = (value as? _DecoderLoggerBox) {
        return loggerBox.loggerInstance
      } else {
        let message = "Invalid logger type in Decoder.userInfo; falling back to global logger."
        let logEntry = LenientDecodingLogEntry.internalsImpIssue(message: message)

        let fallbackLogger = globalLogger
        fallbackLogger(logEntry)
        return fallbackLogger
      }
    } else {
      return globalLogger
    }
  }
}

/// Box used to store `LenientDecodingLogger` in `Decoder.userInfo`.
///
/// Closures cannot be stored directly in `[CodingUserInfoKey: any Sendable]`
/// because they are not `Sendable`-conforming types. This wrapper conforms to
/// `Sendable` and holds the logger for retrieval by ``Decoder.lenientDecodingLogger``.
fileprivate struct _DecoderLoggerBox: Sendable {
  let loggerInstance: LenientDecodingLogger
}

extension CodingUserInfoKey {
  /// UserInfo key for per-decoder log handler.
  ///
  /// Usage:
  /// ```swift
  /// let decoder = JSONDecoder()
  /// decoder.userInfo[.lenientDecodingLogHandler] = logger
  /// ```
  package static let lenientDecodingLogHandler = CodingUserInfoKey(rawValue: "lenientDecodingLogHandler")!
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Global Logger

/// Returns the current global logger.
///
/// On every call this reads ``_globalLogger`` inside the lock (fast),
/// then calls the returned logger outside the lock to avoid serializing
/// concurrent log calls.
///
/// Stale references to the `.pending` variant are safe: when ``inject_once``
/// calls ``extractPendingEntriesAndForwardNew(toInjectedLogger:)``, the old
/// ``PendingEntriesLogger`` is updated so any subsequent `append` calls on it
/// route directly to the injected logger.
package var globalLogger: LenientDecodingLogger {
  { logEntry in
    #if DEBUG
      _globalDebugLogger(logEntry)
    #endif
    let logger = _globalLogger.withLock { $0.instance }
    logger(logEntry)
  }
}

// MARK: PendingEntries Logger

/// Buffers log entries received before the global logger is injected.
///
/// Created automatically at library init time and stored inside
/// ``_GlobalLoggerVariant/pending(_:)``. When ``inject_once`` is called,
/// it calls ``extractPendingEntriesAndForwardNew(toInjectedLogger:)`` to
/// atomically drain the buffer and install the injected logger.
/// After that, all future `append` calls route directly to the injected handler.
/// The drained entries are also forwarded to the injected logger.
///
/// The buffer is capped at ``_pendingEntriesLimit`` entries. When full,
/// existing entries are annotated with a `"pendingBufferOverflow"` key
/// in their `info` dictionary to signal that some more entries were dropped.
fileprivate final class PendingEntriesLogger: Sendable {
  private let _pendingEntriesLimit: UInt8 = 5

  private typealias State =
    (pendingEntries: [LenientDecodingLogEntry], injectedLogger: LenientDecodingLogger?, isOverflowLogged: Bool)
  private let _state = NSLock_<State>((pendingEntries: [], injectedLogger: nil, isOverflowLogged: false))

  /// Atomically drains buffered entries and installs the injected logger.
  ///
  /// Returns the buffered entries so the caller (``inject_once``) can forward
  /// them to the injected logger. After this call, `append` routes new
  /// entries directly to `injectedLogger`.
  fileprivate func extractPendingEntriesAndForwardNew(toInjectedLogger injectedLogger: @escaping LenientDecodingLogger)
    -> [LenientDecodingLogEntry] {
    _state.withLock { state in
      let entries = state.pendingEntries
      state.pendingEntries = []
      state.injectedLogger = injectedLogger
      return entries
    }
  }

  fileprivate func append(logEntry: LenientDecodingLogEntry) {
    lazy var overflowMessage = "pending buffer overflow: some decoding issues were dropped because the global "
      + "logger was not injected yet"

    #if DEBUG
      func overflowDebugLog() {
        var logEntry = logEntry
        logEntry.annotatePendingBufferOverflow(message: overflowMessage)
        _globalDebugLogger(logEntry)
      }
    #endif

    _state.withLock { state in
      if let injectedLogger = state.injectedLogger {
        injectedLogger(logEntry)
      } else if state.pendingEntries.count < _pendingEntriesLimit {
        state.pendingEntries.append(logEntry)
      } else if !state.isOverflowLogged {
        for i in state.pendingEntries.indices {
          state.pendingEntries[i].annotatePendingBufferOverflow(message: overflowMessage)
        }

        state.isOverflowLogged = true

        #if DEBUG
          overflowDebugLog()
        #endif
      } else {
        #if DEBUG
          overflowDebugLog()
        #endif
      }
    }
  }
}

// MARK: Debug Global Logger

/// Default log handler used in DEBUG builds when no handler is injected.
/// Uses os.Logger on supported platforms, falls back to print.
#if DEBUG
  #if canImport(os)
    @available(iOS 14, macOS 11, tvOS 14, watchOS 7, macCatalyst 14, *)
    fileprivate let _osLogger = Logger(subsystem: "LenientCodable", category: "decoding")
  #endif

  fileprivate let _globalDebugLogger: LenientDecodingLogger = { logEntry in
    let message = String(describing: logEntry)
    #if canImport(os)
      if #available(iOS 14, macOS 11, tvOS 14, watchOS 7, macCatalyst 14, *) {
        return _osLogger.log(level: .error, "\(message)")
      } else {
        print(message)
      }
    #else
      print(message)
    #endif
  }
#endif

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Global Logger Config

/// Thread-safe storage for the current global logger variant.
///
/// Starts as `.pending(PendingEntriesLogger())` and transitions to
/// `.injected(logger)` exactly once, when ``inject_once`` is called.
/// Every log call through ``globalLogger`` reads the variant inside
/// this lock.
fileprivate let _globalLogger = NSLock_(_GlobalLoggerVariant.pending(PendingEntriesLogger()))

/// Represents the two states of the global logger lifecycle.
fileprivate enum _GlobalLoggerVariant {
  /// Logger not yet injected. Entries are buffered in the associated
  /// ``PendingEntriesLogger`` until ``inject_once`` drains and forwards
  /// them to the injected logger.
  case pending(PendingEntriesLogger)
  /// Logger injected. Entries are logged by associated handler.
  case injected(LenientDecodingLogger)

  /// Returns a ``LenientDecodingLogger`` closure for the current variant.
  ///
  /// For `.pending`, the closure appends to the buffer.
  /// For `.injected`, the closure forwards directly to the externally injected handler.
  var instance: LenientDecodingLogger {
    switch self {
    case .pending(let pendingEntriesLogger):
      { logEntry in pendingEntriesLogger.append(logEntry: logEntry) }
    case .injected(let injectedLogger):
      injectedLogger
    }
  }
}

// MARK: Rate Limits

/// Two rate-limit values packed into a single `UInt16` for lock-free atomic access.
///
/// - Lower byte: `perDecodingReportedFieldsLimit` – max issue entries per decoded object.
/// - Upper byte: `elementsPerCollectionLimit` – max per-element issues for collection (array/dictionary).
///
/// On macOS 15+/iOS 18+ the values can be overridden
/// via ``inject_once(lenientDecodingLogger:rateLimits:...)``.
/// On older OS versions the getter returns the hardcoded default `(3, 3)`
/// and the setter does not available.
fileprivate var _rateLimits: (perDecodingReportedFieldsLimit: UInt8, elementsPerCollectionLimit: UInt8) {
  get {
    if #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) {
      let bitpackedLimits = __bitpackedRateLimits.load(ordering: .relaxed)
      let perDecodingReportedFieldsLimit = UInt8(bitpackedLimits & 0xFF)
      let elementsPerCollectionLimit = UInt8((bitpackedLimits >> 8) & 0xFF)
      return (perDecodingReportedFieldsLimit, elementsPerCollectionLimit)
    } else {
      return (3, 3)
    }
  }

  @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
  set {
    let bitpackedLimits = UInt16.bitpackRateLimits(perDecodingReportedFieldsLimit: newValue.perDecodingReportedFieldsLimit,
                                                   elementsPerCollectionLimit: newValue.elementsPerCollectionLimit)
    __bitpackedRateLimits.store(bitpackedLimits, ordering: .relaxed)
  }
}

/// Atomic storage for the bitpacked rate limits.
///
/// Accessed via ``_rateLimits``. The `UInt16` is split into two bytes:
/// lower = `perDecodingReportedFieldsLimit`, upper = `elementsPerCollectionLimit`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
fileprivate let __bitpackedRateLimits = Atomic<UInt16>(.bitpackRateLimits(perDecodingReportedFieldsLimit: 3,
                                                                          elementsPerCollectionLimit: 3))
extension UInt16 {
  /// Packs two `UInt8` rate limits into a single `UInt16`.
  ///
  /// - `perDecodingReportedFieldsLimit` occupies the lower byte.
  /// - `elementsPerCollectionLimit` occupies the upper byte.
  fileprivate static func bitpackRateLimits(perDecodingReportedFieldsLimit: UInt8, elementsPerCollectionLimit: UInt8) -> UInt16 {
    let higherByte = UInt16(elementsPerCollectionLimit) << 8
    let lowerByte = UInt16(perDecodingReportedFieldsLimit)
    return higherByte | lowerByte
  }
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Logging DataModels

// MARK: LogEntry

/// The severity level of a lenient decoding log entry.
///
/// Represents the highest-severity issue encountered while decoding a single object.
/// Starts at `.warning` and upgrades to `.failure` if any `@Strict` property fails
/// to decode (since `@Strict` failures throw and halt the entire decode).
///
/// - Note: This is tracked per ``LenientDecodingLogEntry`` (one per decoded object)
///   and surfaced to the injected logger for filtering/alerting.
public enum LenientDecodingLogSeverity: String, Sendable, CustomStringConvertible {
  /// A lenient decoding issue occurred (absorbed by `@NilOnFailure` or `@DropOnFailure`).
  /// The decode succeeded but some data was substituted (`nil`, `[]`, dropped).
  case warning

  /// A strict decoding failure occurred (from `@Strict` property).
  /// The decode threw and did not produce a value.
  case failure
  
  public var description: String { rawValue }

  /// Upgrades this severity if `newSeverity` is higher.
  /// Used internally when recording multiple issues for the same object.
  fileprivate mutating func upgradeBy(_: Self) {
    guard !(self == .failure) else { return }
    self = .failure
  }
}

/// Accumulates all issues for a single decoded object.
///
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
  /// split issues across multiple keys; we want them grouped by collection.
  /// Each value contains up to `collectionElementIssuesLimit` issues
  /// and an `overflowCount` for additional dropped elements beyond the limit.
  public private(set) var collectionElementIssues: [String: (issues: [LenientDecodingIssue], overflowCount: UInt)] = [:]

  /// Field identities for issues that could not be stored because the total
  /// per-object rate limit (`perDecodingReportedFieldsLimit`) was reached.
  /// This includes both property-level issues (from `@NilOnFailure`/`@Strict`)
  /// and collection element issues that couldn't create a new entry.
  public private(set) var overflowedFieldIdentities: Set<String> = []

  // MARK: - Rate Limits

  /// Maximum number of fields (properties + collections) with tracked issues per decoded object.
  /// Captured from ``_rateLimits`` at initialization.
  private let perDecodingReportedFieldsLimit: UInt8

  /// Maximum number of element issues stored per collection.
  /// Captured from ``_rateLimits`` at initialization.
  private let collectionElementIssuesLimit: UInt8

  /// `true` when the combined count of `propertyDecodingIssues` and
  /// `collectionElementIssues` has reached `perDecodingReportedFieldsLimit`.
  private var isPerDecodingReportedFieldsLimitReached: Bool {
    (propertyDecodingIssues.count + collectionElementIssues.count) >= perDecodingReportedFieldsLimit
  }

  /// Creates a new entry, snapshotting the current rate limits from ``_rateLimits``.
  fileprivate init() {
    let rateLimits = _rateLimits
    perDecodingReportedFieldsLimit = rateLimits.perDecodingReportedFieldsLimit
    collectionElementIssuesLimit = rateLimits.elementsPerCollectionLimit
  }

  /// Records a property-level decoding failure.
  ///
  /// If the total rate limit has not been reached, the issue is stored in
  /// ``propertyDecodingIssues``; otherwise only the `errorIdentity` is
  /// recorded in ``propertyDecodingOverflowedIssues``.
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
  ///
  /// Used by ``LenientDecoding/nilPadding(_:_:in:forKey:decoder:)`` (for `[K: V?]`/`[K: V?]?`)
  /// and ``LenientDecoding/dropOnFailure(_:_:in:forKey:decoder:)`` (for `[K: V]`).
  ///
  /// The error is grouped under an identity key derived from the strategy name and the
  /// dictionary's property path (e.g., `"@NilOnFailure:user.addresses"`). This allows
  /// multiple failed values in the same dictionary to be grouped together in
  /// ``collectionElementIssues`` with a shared overflow counter.
  ///
  /// Rate limiting is applied at two levels:
  /// - **Per decoded object:** Capped by `perDecodingReportedFieldsLimit`
  /// - **Per dictionary:** Capped by `collectionElementIssuesLimit` (per-element issues stored)
  ///
  /// - Parameters:
  ///   - dictionaryValueError: The `DecodingError` absorbed while decoding a dictionary value.
  ///   - key: The dictionary property key.
  ///   - keyedContainer: The keyed container of dictionary key-value pairs.
  ///   - strategy: The leniency strategy annotation (e.g., `"@NilOnFailure"`, `"@DropOnFailure"`).
  ///   - severity: The severity of this issue (`.warning` for lenient, `.failure` for `@Strict`).
  package mutating func append<Key: CodingKey>(dictionaryValueError: DecodingError,
                                               dictionaryPropertyKey key: Key,
                                               keyedContainer: KeyedDecodingContainer<Key>,
                                               strategy: String,
                                               severity: LenientDecodingLogSeverity) {
    let identity = errorIdentity(prefix: strategy, path: loggingPath(ofKeyedContainer: keyedContainer, key: key))
    append(elementError: dictionaryValueError, identity: identity, strategy: strategy, severity: severity)
  }

  /// Records an array element decoding failure for a specific index.
  ///
  /// Used by ``LenientDecoding/nilPadding(_:in:forKey:decoder:)`` (for `[T?]`/`[T?]?`)
  /// and ``LenientDecoding/dropOnFailure(_:in:forKey:decoder:)`` (for `[T]`).
  ///
  /// The error is grouped under an identity key derived from the strategy name and the
  /// array's coding path (e.g., `"@DropOnFailure:orders"`).
  /// This allows multiple failed elements in the same array to be grouped together in
  /// ``collectionElementIssues`` with a shared overflow counter.
  ///
  /// Rate limiting is applied at two levels:
  /// - **Per decoded object:** Capped by ``perDecodingReportedFieldsLimit``
  /// - **Per array / dictionary:** Capped by ``collectionElementIssuesLimit``
  ///
  /// - Parameters:
  ///   - arrayElementError: The `DecodingError` absorbed while decoding an array element.
  ///   - key: The array property key.
  ///   - unkeyedContainer: The unkeyed container of array property.
  ///   - strategy: The leniency strategy annotation (e.g., `"@NilOnFailure"`, `"@DropOnFailure"`).
  ///   - severity: The severity of this issue (`.warning` for lenient, `.failure` for `@Strict`).
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
  /// reached, the identity is added to ``propertyDecodingOverflowedIssues``
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

extension LenientDecodingLogEntry {
  // MARK: Synthetic issue for internal logging

  /// Creates a synthetic entry containing a single internal issue.
  ///
  /// Used by ``inject_once`` and ``Decoder.lenientDecodingLogger`` to report
  /// infrastructure issues (e.g. double injection, invalid userInfo type)
  /// without going through the normal decode path.
  fileprivate static func internalsImpIssue(message: String) -> Self {
    var entry = Self()
    let code = LenientDecodingIssueCode.unexpectedCodeEntrance
    let issue = LenientDecodingIssue(errorIdentity: "\(code)",
                                     severity: .failure,
                                     code: code,
                                     path: "",
                                     decodingStrategy: "",
                                     underlyingError: nil,
                                     info: ["message": message])
    entry.propertyDecodingIssues[issue.errorIdentity] = issue
    return entry
  }

  /// Annotates issues in this entry with a `"pendingBufferOverflow"` info key.
  ///
  /// Called by ``PendingEntriesLogger`` when its buffer is full, signaling that
  /// some issues for this decoded object were dropped because the global
  /// logger had not been injected yet.
  fileprivate mutating func annotatePendingBufferOverflow(message: String) {
    let messageKey = "pendingBufferOverflowOccured"
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

/// Renders the full coding path of `key` inside `container` as a
/// dot-joined string (e.g. `"order.docs"` or `"orders.Index 2.status"`).
///
/// This path identifies the location of a value in the JSON structure.
/// It's used as part of the `errorIdentity` (e.g. `"keyNotFound:order.status"`)
/// to group and look up issues in ``LenientDecodingLogEntry/propertyDecodingIssues``
/// and ``LenientDecodingLogEntry/collectionElementIssues``.
///
/// The container's `codingPath` (the walk from the JSON root to the container)
/// is extended with `key`, and each component's `stringValue` is joined with `.`.
/// A key at the top level therefore renders as just `"status"`; if the struct
/// sits inside a JSON array, the synthesized index key appears in the path
/// (e.g. `"orders.Index 2.status"`).
///
/// - Parameters:
///   - container: The keyed container the failing value was read from.
///   - key: The key whose path is being reported.
/// - Returns: The dot-joined path from the JSON root to `key`.
package func loggingPath<Key: CodingKey>(ofKeyedContainer container: KeyedDecodingContainer<Key>,
                                         key: Key) -> String {
  (container.codingPath + [key]).map { $0.stringValue }.joined(separator: ".")
}

package func loggingPath(ofUnkeyedContainer container: some UnkeyedDecodingContainer,
                         key: some CodingKey) -> String {
  (container.codingPath + [key]).map { $0.stringValue }.joined(separator: ".")
}

/// Builds a stable string identity for an issue from a prefix and coding path.
///
/// Used as dictionary keys in ``LenientDecodingLogEntry/propertyDecodingIssues``
/// and ``LenientDecodingLogEntry/collectionElementIssues``. The format is
/// `"<prefix>:<path>"` (e.g. `"keyNotFound:order.status"`).
fileprivate func errorIdentity(prefix: String, path: String) -> String {
  prefix + ":" + path
}

// MARK: Decoding Issue

/// A single structured issue for a lenient decoding failure.
/// Contains all context needed for debugging and monitoring.
///
/// One ``LenientDecodingLogEntry`` (per decoded object) collects multiple
/// ``LenientDecodingIssue`` instances – one for each absorbed failure.
public struct LenientDecodingIssue: Sendable {
  /// Stable string used as the dictionary key in ``LenientDecodingLogEntry/propertyDecodingIssues``.
  /// Format: `"<errorType>:<codingPath>"` (e.g. `"keyNotFound:order.status"`).
  ///
  /// For property-level failures (`@NilOnFailure`, `@Strict`), this is the lookup key.
  ///
  /// For `@DropOnFailure` and `@NilOnFailure` collection elements, the `DecodingError` context includes the
  /// element key / index, so each element's `errorIdentity` is unique (e.g.
  /// `"typeMismatch:orders.Index 0"`). To group all element failures of the same collection, `append(elementError:forCollectionKey:container:strategy:identityPrefix:)` computes a separate
  /// identity without element key / index.
  fileprivate let errorIdentity: String

  /// Numeric category of the failure (see ``LenientDecodingErrorCode``).
  public let code: LenientDecodingIssueCode
  
  /// The underlying error from the `DecodingError.Context`, if available.
  /// This is the error that caused the decoding failure (e.g. a date parsing error
  /// that triggered a `typeMismatch`), not the `DecodingError` itself.
  public let underlyingError: (any Error)?
  /// Additional metadata. Includes `"strategy"` (e.g. `"@NilOnFailure"`).
  ///
  /// Examples:
  /// - `"contextDebugDescription"` — the `DecodingError.Context.debugDescription`.
  /// - `"expectedType"` — the type that was expected (for `typeMismatch`/`valueNotFound`).
  /// - `"missingKey"` — the absent key (for `keyNotFound`).
  public fileprivate(set) var info: [String: any Sendable & CustomStringConvertible & Encodable]
  
  fileprivate init(errorIdentity: String,
                   severity: LenientDecodingLogSeverity,
                   code: LenientDecodingIssueCode,
                   path: String,
                   decodingStrategy: String,
                   underlyingError: (any Error)?,
                   info: consuming [String: any Sendable & CustomStringConvertible & Encodable]) {
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
  /// - Parameters:
  ///   - decodingStrategy: The strategy annotation passed by the macro, e.g. `"@NilOnFailure"`, `"@DropOnFailure"`, `"@Strict"`.
  /// - Returns: A ``LenientDecodingIssue`` populated from the error's type, context, and underlying error.
  fileprivate func asIssue(decodingStrategy: String, severity: LenientDecodingLogSeverity) -> LenientDecodingIssue {
    let contextDebugDescrKey = "contextDebugDescription"
    switch self {
    case let .typeMismatch(type, context):
      let contextPath = context.codingPathString
      return LenientDecodingIssue(errorIdentity: errorIdentity(prefix: "typeMismatch", path: contextPath),
                                  severity: severity,
                                  code: .typeMismatch,
                                  path: contextPath,
                                  decodingStrategy: decodingStrategy,
                                  underlyingError: context.underlyingError,
                                  info: [contextDebugDescrKey: context.debugDescription, "expectedType": "\(type)"])

    case let .keyNotFound(key, context):
      let contextPath = context.codingPathString
      return LenientDecodingIssue(errorIdentity: errorIdentity(prefix: "keyNotFound", path: contextPath),
                                  severity: severity,
                                  code: .keyNotFound,
                                  path: contextPath,
                                  decodingStrategy: decodingStrategy,
                                  underlyingError: context.underlyingError,
                                  info: [contextDebugDescrKey: context.debugDescription, "missingKey": "\(key)"])

    case let .valueNotFound(type, context):
      let contextPath = context.codingPathString
      return LenientDecodingIssue(errorIdentity: errorIdentity(prefix: "valueNotFound", path: contextPath),
                                  severity: severity,
                                  code: .valueNotFound,
                                  path: contextPath,
                                  decodingStrategy: decodingStrategy,
                                  underlyingError: context.underlyingError,
                                  info: [contextDebugDescrKey: context.debugDescription, "expectedType": "\(type)"])

    case .dataCorrupted(let context):
      let contextPath = context.codingPathString
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

extension DecodingError.Context {
  /// The coding path rendered as a dot-joined string.
  fileprivate var codingPathString: String {
    codingPath.map { $0.stringValue }.joined(separator: ".")
  }
}

// MARK: Error Code

/// Internal error codes for categorizing lenient decoding failures.
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

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Supporting Code

/// A generic lock wrapper providing mutually exclusive access to a value.
///
/// This exists because `Swift.Mutex` is only available on macOS 15+ /  iOS 18+.
/// This library supports iOS 13+ / macOS 10.15+, so we use `NSLock` as the
/// underlying implementation.
@available(macOS, deprecated: 15.0, message: "Use Swift.Mutex instead")
@available(iOS, deprecated: 18.0, message: "Use Swift.Mutex instead")
@available(tvOS, deprecated: 18.0, message: "Use Swift.Mutex instead")
@available(watchOS, deprecated: 11.0, message: "Use Swift.Mutex instead")
@available(macCatalyst, deprecated: 18.0, message: "Use Swift.Mutex instead")
private final class NSLock_<Value: ~Copyable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: consuming Value) {
    self.value = value
  }

  public func withLock<Result: ~Copyable>(_ body: (inout sending Value) -> sending Result)
    -> sending Result {
    lock.lock(); defer { lock.unlock() }
    return body(&value)
  }
}
