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
    (container.codingPath + [key]).map(\.stringValue).joined(separator: ".")
  }
}

//===-------------------------------------------------------------------------------------------------------------------===//

/// The handler type for receiving lenient decoding log entries.
/// Injected once globally; can be overridden per-decoder via `userInfo`.
public typealias LenientDecodingLogger = @Sendable (LenientDecodingLogEntry) -> Void

// MARK: - Inject Logger Once

/// Injects the global log handler. Can only be called once.
/// Subsequent calls will log a warning via the existing handler.
/// - Parameters:
///   - logger: The log handler to receive all lenient decoding errors.
///   - file: Source file (for assertion).
///   - line: Source line (for assertion).
public func inject_once(lenientDecodingLogger logger: @escaping LenientDecodingLogger,
                        decodingSlotsLimit: UInt8 = 3,
                        dropElementsWarningLimit: UInt8 = 3,
                        file: StaticString = #file,
                        line: UInt = #line) {
  let (alreadyInjectedGlobalLogger, pendingLogs) = _globalLogger
    .withLock { variant -> (LenientDecodingLogger?, [LenientDecodingLogEntry]) in
      switch variant {
      case .injected(let injectedGlobalLogger):
        return (injectedGlobalLogger, [])
      case .pending(let pendingEntriesLogger):
        if #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) {
          __totalDecodingWarningsLimit.store(UInt(decodingSlotsLimit), ordering: .relaxed)
          __dropElementWarningsLimit.store(UInt(dropElementsWarningLimit), ordering: .relaxed)
        } // else {} // in older OS versions rate limit is constant and can not be overriden

        let pendingLogEntries = pendingEntriesLogger.pendingEntries.withLock { entries in
          let pendingLogEntries = entries
          entries = []
          return pendingLogEntries
        }

        variant = .injected(logger)

        return (nil, pendingLogEntries)
      }
    }

  if !pendingLogs.isEmpty {
    for log in pendingLogs {
      logger(log)
    }
  }

  if let alreadyInjectedGlobalLogger {
    let message = "Attempted to inject lenient decoding logger more than once"
    let code = LenientDecodingErrorCode.loggerReinjection
    let warning = LenientDecodingWarning(errorIdentity: "\(code)",
                                         code: code,
                                         path: "",
                                         strategy: "",
                                         underlyingError: nil,
                                         info: ["message": message])
    let logEntry = LenientDecodingLogEntry.loggerInjectionWarning(warning)
    alreadyInjectedGlobalLogger(logEntry)
    logger(logEntry)
    assertionFailure(message, file: file, line: line)
  }
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Decoder Extension

extension JSONDecoder {
  public func setLenientDecodingLogger(_ logger: @escaping LenientDecodingLogger) {
    userInfo[.lenientDecodingLogHandler] = _DecoderLoggerBox(loggerInstance: logger)
  }
}

extension Decoder {
  /// Returns either logger provided via `userInfo` or injected `globalLogger`
  package var lenientDecodingLogger: LenientDecodingLogger? {
    if let logger = (userInfo[.lenientDecodingLogHandler] as? _DecoderLoggerBox)?.loggerInstance {
      logger
    } else {
      globalLogger
    }
  }
}

/// Used to for storing `LenientDecodingLogger` in `userInfo` as closures can not be stored in `[CodingUserInfoKey: any Sendable] `.
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
  public static let lenientDecodingLogHandler = CodingUserInfoKey(rawValue: "lenientDecodingLogHandler")!
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Global Logger

package var globalLogger: LenientDecodingLogger {
  let globalInjectedLogger = _globalLogger.withLock { $0.instance }

  #if DEBUG
    let compositeLogger: LenientDecodingLogger = { logEntry in
      _globalDebugLogger(logEntry)
      globalInjectedLogger(logEntry)
    }
    return compositeLogger
  #else
    return globalInjectedLogger
  #endif
}

fileprivate final class PendingEntriesLogger: Sendable {
  private let _pendingEntriesLimit: UInt = 5
  fileprivate let pendingEntries = NSLock_<[LenientDecodingLogEntry]>([])

  func append(logEntry: LenientDecodingLogEntry) {
    pendingEntries.withLock { entries in
      guard entries.count < _pendingEntriesLimit else { return }
      entries.append(logEntry)
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

/// Global log handler storage with thread-safe access.
fileprivate let _globalLogger = NSLock_(_GlobalLoggerVariant.pending(PendingEntriesLogger()))

fileprivate enum _GlobalLoggerVariant {
  case pending(PendingEntriesLogger)
  case injected(LenientDecodingLogger)

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

fileprivate var _totalDecodingWarningsLimit: UInt {
  if #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) {
    __totalDecodingWarningsLimit.load(ordering: .relaxed)
  } else {
    3
  }
}

fileprivate var _dropElementsPerArrayWarningLimit: UInt {
  if #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) {
    __dropElementWarningsLimit.load(ordering: .relaxed)
  } else {
    3
  }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
fileprivate let __totalDecodingWarningsLimit = Atomic<UInt>(3)

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
fileprivate let __dropElementWarningsLimit = Atomic<UInt>(3)

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Logging DataModels

/// Used during Decoding to accumulate warnings.
public struct LenientDecodingLogEntry: Sendable {
  /// `[errorIdentity: warning]` pairs
  public private(set) var propertyDecodingWarnings: [String: LenientDecodingWarning] = [:]
  public private(set) var propertyDecodingWarningOverflowCounts: Set<String> = []

  /// `[arrayPropertyPath: (warnings:, overflowCount:)]` pairs
  public private(set) var dropOnFailureWarnings: [String: (warnings: [LenientDecodingWarning], overflowCount: UInt)] = [:]

  // MARK: - Rate Limits

  private let totalDecodingWarningsLimit = _totalDecodingWarningsLimit
  private let dropElementsPerArrayWarningLimit = _dropElementsPerArrayWarningLimit

  private var isRateLimitReached: Bool {
    (propertyDecodingWarnings.count + dropOnFailureWarnings.count) >= totalDecodingWarningsLimit
  }

  fileprivate init() {}

  package mutating func append(propertyDecodingError: DecodingError,
                               decodingStrategy: String) {
    let warning = propertyDecodingError.asWarning(decodingStrategy: decodingStrategy)
    if isRateLimitReached {
      propertyDecodingWarnings[warning.errorIdentity] = warning
    } else {
      propertyDecodingWarningOverflowCounts.insert(warning.errorIdentity)
    }
  }

  package mutating func append<Key: CodingKey>(dropOnFailureError: DecodingError,
                                               forArrayKey key: Key,
                                               container: KeyedDecodingContainer<Key>) {
    let decodingStrategy = "@DropOnFailure"
    let identity = errorIdentity(prefix: "dropOnFailure", path: path(for: container, key: key))
    lazy var warning = dropOnFailureError.asWarning(decodingStrategy: decodingStrategy)

    let index = dropOnFailureWarnings.index(forKey: identity)
    if let index {
      if dropOnFailureWarnings.values[index].warnings.count < dropElementsPerArrayWarningLimit {
        dropOnFailureWarnings.values[index].warnings.append(warning)
      } else {
        dropOnFailureWarnings.values[index].overflowCount += 1
      }
    } else {
      if isRateLimitReached {
        propertyDecodingWarningOverflowCounts.insert(identity)
      } else {
        let emptyInfo: (warnings: [LenientDecodingWarning], overflowCount: UInt) = ([], 0)
        dropOnFailureWarnings[identity, default: emptyInfo].warnings.append(warning)
      }
    }
  }

  fileprivate static func loggerInjectionWarning(_ warning: LenientDecodingWarning) -> Self {
    var entry = Self()
    entry.propertyDecodingWarnings[warning.errorIdentity] = warning
    return entry
  }
}

// TODO: duplicate of existing `LenientErrorLogger.path(of:, key:)` implementation
package func path<Key: CodingKey>(for container: KeyedDecodingContainer<Key>,
                                  key: Key) -> String {
  (container.codingPath + [key]).map { $0.stringValue }.joined(separator: ".")
}

fileprivate func errorIdentity(prefix: String, path: String) -> String {
  prefix + ":" + path
}

/// Structured log entry for a lenient decoding failure.
/// Contains all context needed for debugging and monitoring.
public struct LenientDecodingWarning: Sendable {
  fileprivate let errorIdentity: String

  public let code: LenientDecodingErrorCode
  public let path: String
  /// e.g. `@NilOnFailure`, `@DropOnFailure`, `@Strict`...
  public let strategy: String
  public let underlyingError: (any Error)?
  public let info: [String: any Sendable & CustomStringConvertible]
}

extension DecodingError {
  /// Formats a DecodingError into a human-readable description.
  /// - Parameters:
  ///   - decodingStrategy: passed  by Macro, e.g. `@NilOnFailure`, `@DropOnFailure`, `@Strict`
  /// - Returns: LenientDecodingLogEntry
  fileprivate func asWarning(decodingStrategy: String) -> LenientDecodingWarning {
    let contextDebugDescrKey = "contextDebugDescription"
    switch self {
    case let .typeMismatch(type, context):
      let contextPath = context.codingPathString
      return LenientDecodingWarning(errorIdentity: errorIdentity(prefix: "typeMismatch", path: contextPath),
                                    code: .typeMismatch,
                                    path: contextPath,
                                    strategy: decodingStrategy,
                                    underlyingError: context.underlyingError,
                                    info: [contextDebugDescrKey: context.debugDescription, "expectedType": "\(type)"])

    case let .keyNotFound(key, context):
      let contextPath = context.codingPathString
      return LenientDecodingWarning(errorIdentity: errorIdentity(prefix: "keyNotFound", path: contextPath),
                                    code: .keyNotFound,
                                    path: contextPath,
                                    strategy: decodingStrategy,
                                    underlyingError: context.underlyingError,
                                    info: [contextDebugDescrKey: context.debugDescription, "missingKey": "\(key)"])

    case let .valueNotFound(type, context):
      let contextPath = context.codingPathString
      return LenientDecodingWarning(errorIdentity: errorIdentity(prefix: "valueNotFound", path: contextPath),
                                    code: .valueNotFound,
                                    path: contextPath,
                                    strategy: decodingStrategy,
                                    underlyingError: context.underlyingError,
                                    info: [contextDebugDescrKey: context.debugDescription, "expectedType": "\(type)"])

    case .dataCorrupted(let context):
      let contextPath = context.codingPathString
      return LenientDecodingWarning(errorIdentity: errorIdentity(prefix: "dataCorrupted", path: contextPath),
                                    code: .dataCorrupted,
                                    path: contextPath,
                                    strategy: decodingStrategy,
                                    underlyingError: context.underlyingError,
                                    info: [contextDebugDescrKey: context.debugDescription])

    @unknown default:
      return LenientDecodingWarning(errorIdentity: "unknown:\(type(of: self)):" + decodingStrategy,
                                    code: .unknownDecodingError,
                                    path: "",
                                    strategy: decodingStrategy,
                                    underlyingError: nil,
                                    info: [:])
    }
  }
}

extension DecodingError.Context {
  fileprivate var codingPathString: String {
    codingPath.map { $0.stringValue }.joined(separator: ".")
  }
}

/// Internal error codes for categorizing lenient decoding failures.
/// These are stable identifiers used for filtering and aggregation.
/// Values match `DecodingError` codes where applicable (0-29), then lenient-specific (30+).
public enum LenientDecodingErrorCode: Int, Sendable {
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

  /// Container Key Issues.
  /// Container type mismatch (expected array, got object; expected object, got string).
  /// When `nestedUnkeyedContainer` or `nestedContainer` fails.
  case invalidContainer = 40

  /// Two distinct JSON keys convert to same `T` (collision after conversion).
  /// First wins, subsequent dropped.
  ///
  /// **Example:** JSON `{"tags": {"7": {"type": "a"}, "07": {"type": "b"}}}` decoding `tags: [Int: Doc]`
  case keyCollision = 41

  case unknownDecodingError = 50

  case loggerReinjection = 100
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Supporting Code

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
    body(&value)
  }
}
