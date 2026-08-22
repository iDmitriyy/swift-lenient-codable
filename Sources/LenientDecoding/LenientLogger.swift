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
    loggingPath(ofContainer: container, key: key)
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
                        rateLimits: (totalDecodingLimit: UInt8, dropElementsPerArrayLimit: UInt8)? = nil,
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

        // Drain buffered entries and set forwarding atomically.
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
    let logEntry = LenientDecodingLogEntry.internalsImpWarning(message: message)
    // Intentionally call BOTH loggers: we cannot assume which
    // logger is the "real" destination for this error – the old one may
    // already be forwarding to the monitoring system, while the new one
    // may be the caller's debug sink. Both receive the warning so nothing
    // is silently lost.
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
    if let value = userInfo[.lenientDecodingLogHandler] {
      if let loggerBox = (value as? _DecoderLoggerBox) {
        return loggerBox.loggerInstance
      } else {
        let message = "Invalid type of logger provided in Decoder.userInfo. This message was forwarded to global logger."
        let logEntry = LenientDecodingLogEntry.internalsImpWarning(message: message)

        let fallbackLogger = globalLogger
        fallbackLogger(logEntry)
        return fallbackLogger
      }
    } else {
      return globalLogger
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
  package static let lenientDecodingLogHandler = CodingUserInfoKey(rawValue: "lenientDecodingLogHandler")!
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Global Logger

/// Returns the current global logger.
///
/// Stale references to the `.pending` variant are safe: once
/// `inject_once` calls `extractPendingEntriesAndForwardNew(toInjectedLogger:)`, any `append` on the old
/// `PendingEntriesLogger` routes directly to the injected logger.
package var globalLogger: LenientDecodingLogger {
  { logEntry in
    #if DEBUG
      _globalDebugLogger(logEntry)
    #endif
    let logger = _globalLogger.withLock { $0.instance }
    logger(logEntry)
  }
}

fileprivate final class PendingEntriesLogger: Sendable {
  private let _pendingEntriesLimit: UInt8 = _rateLimits.totalDecodingLimit

  private typealias State = (pendingEntries: [LenientDecodingLogEntry], injectedLogger: LenientDecodingLogger?)
  private let _state = NSLock_<State>((pendingEntries: [], injectedLogger: nil))

  /// Atomically drains buffered entries and sets the `injectedLogger` for forwarding further entries .
  /// After this call, `append` routes new entries directly to `injectedLogger`.
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
    _state.withLock { state in
      if let injectedLogger = state.injectedLogger {
        injectedLogger(logEntry)
        return
      }

      guard state.pendingEntries.count < _pendingEntriesLimit else {
        let message = "pending buffer overflow: some decoding warnings were dropped because the global "
          + "logger was not injected yet"
        for i in state.pendingEntries.indices {
          state.pendingEntries[i].annotatePendingBufferOverflow(message: message)
        }
        
        _globalDebugLogger(logEntry)
        return
      }

      state.pendingEntries.append(logEntry)
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

fileprivate var _rateLimits: (totalDecodingLimit: UInt8, dropElementsPerArrayLimit: UInt8) {
  get {
    if #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) {
      let bitpackedLimits = __bitpackedRateLimits.load(ordering: .relaxed)
      let totalDecodingLimit = UInt8(bitpackedLimits & 0xFF)
      let dropElementsPerArrayLimit = UInt8((bitpackedLimits >> 8) & 0xFF)
      return (totalDecodingLimit, dropElementsPerArrayLimit)
    } else {
      return (3, 3)
    }
  }

  @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
  set {
    let bitpackedLimits = UInt16.bitpackRateLimits(totalDecodingLimit: newValue.totalDecodingLimit,
                                                   dropElementsPerArrayLimit: newValue.dropElementsPerArrayLimit)
    __bitpackedRateLimits.store(bitpackedLimits, ordering: .relaxed)
  }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
fileprivate let __bitpackedRateLimits = Atomic<UInt16>(.bitpackRateLimits(totalDecodingLimit: 3,
                                                                          dropElementsPerArrayLimit: 3))
extension UInt16 {
  fileprivate static func bitpackRateLimits(totalDecodingLimit: UInt8, dropElementsPerArrayLimit: UInt8) -> UInt16 {
    let higherByte = UInt16(dropElementsPerArrayLimit) << 8
    let lowerByte = UInt16(totalDecodingLimit)
    return higherByte | lowerByte
  }
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Logging DataModels

/// Used during Decoding to accumulate warnings.
public struct LenientDecodingLogEntry: Sendable {
  /// `[errorIdentity: warning]` pairs
  public private(set) var propertyDecodingWarnings: [String: LenientDecodingWarning] = [:]

  /// `[arrayPropertyPath: (warnings:, overflowCount:)]` pairs
  public private(set) var dropOnFailureWarnings: [String: (warnings: [LenientDecodingWarning], overflowCount: UInt)] = [:]

  public private(set) var propertyDecodingOverflowedWarnings: Set<String> = []

  // MARK: - Rate Limits

  private let totalDecodingWarningsLimit: UInt8
  private let dropElementsPerArrayWarningLimit: UInt8

  private var isTotalDecodingRateLimitReached: Bool {
    (propertyDecodingWarnings.count + dropOnFailureWarnings.count) >= totalDecodingWarningsLimit
  }

  fileprivate init() {
    let rateLimits = _rateLimits
    totalDecodingWarningsLimit = rateLimits.totalDecodingLimit
    dropElementsPerArrayWarningLimit = rateLimits.dropElementsPerArrayLimit
  }

  package mutating func append(propertyDecodingError: DecodingError,
                               decodingStrategy: String) {
    let warning = propertyDecodingError.asWarning(decodingStrategy: decodingStrategy)
    if isTotalDecodingRateLimitReached {
      propertyDecodingOverflowedWarnings.insert(warning.errorIdentity)
    } else {
      propertyDecodingWarnings[warning.errorIdentity] = warning
    }
  }

  package mutating func append<Key: CodingKey>(dropOnFailureError: DecodingError,
                                               forArrayKey key: Key,
                                               container: KeyedDecodingContainer<Key>) {
    let decodingStrategy = "@DropOnFailure"
    let identity = errorIdentity(prefix: "dropOnFailure", path: loggingPath(ofContainer: container, key: key))
    lazy var warning = dropOnFailureError.asWarning(decodingStrategy: decodingStrategy)

    let index = dropOnFailureWarnings.index(forKey: identity)
    if let index {
      if dropOnFailureWarnings.values[index].warnings.count < dropElementsPerArrayWarningLimit {
        dropOnFailureWarnings.values[index].warnings.append(warning)
      } else {
        dropOnFailureWarnings.values[index].overflowCount += 1
      }
    } else {
      if isTotalDecodingRateLimitReached {
        // As total limit reached, it is not possible to add entry, so add info to `propertyDecodingOverflowedWarnings`
        // signaling that there were warnings for Array property as a whole instead of per-element info.
        propertyDecodingOverflowedWarnings.insert(identity)
      } else {
        dropOnFailureWarnings[identity, default: ([], 0)].warnings.append(warning)
      }
    }
  }

  fileprivate static func internalsImpWarning(message: String) -> Self {
    var entry = Self()
    let code = LenientDecodingErrorCode.unexpectedCodeEntrance
    let warning = LenientDecodingWarning(errorIdentity: "\(code)",
                                         code: code,
                                         path: "",
                                         strategy: "",
                                         underlyingError: nil,
                                         info: ["message": message])
    entry.propertyDecodingWarnings[warning.errorIdentity] = warning
    return entry
  }

  fileprivate mutating func annotatePendingBufferOverflow(message: String) {
    if let firstKey = propertyDecodingWarnings.keys.first,
       let index = propertyDecodingWarnings.index(forKey: firstKey) {
      propertyDecodingWarnings.values[index].info["pendingBufferOverflow"] = message
    } else if let firstKey = dropOnFailureWarnings.keys.first,
              let index = dropOnFailureWarnings.index(forKey: firstKey),
              dropOnFailureWarnings.values[index].warnings.indices.contains(0) {
      dropOnFailureWarnings.values[index].warnings[0].info["pendingBufferOverflow"] = message
    }
  }
}

package func loggingPath<Key: CodingKey>(ofContainer container: KeyedDecodingContainer<Key>,
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
  public fileprivate(set) var info: [String: any Sendable & CustomStringConvertible]
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
      return LenientDecodingWarning(errorIdentity: "unknown:\(Self.self):" + decodingStrategy,
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

  case unexpectedCodeEntrance = 100
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
    lock.lock(); defer { lock.unlock() }
    return body(&value)
  }
}
