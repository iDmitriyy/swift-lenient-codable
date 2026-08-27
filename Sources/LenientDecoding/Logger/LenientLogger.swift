//
//  LenientLogger.swift
//  LenientCodable
//
//  Created by Omar Elsayed on 19/07/2026.
//

import Foundation
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
public enum LenientErrorLogger {
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
  @available(*, deprecated, message: "Use `Decoder.logHandler` instead")
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
/// Injected once globally via ``inject_once(lenientDecodingLogHandler:rateLimits:)``;
/// can be overridden per-decoder via ``JSONDecoder.setLenientDecodingLogHandler(_:)``.
///
/// **Behavior:**
/// - If a global logger is injected, it receives **all** lenient decoding failures
///   in both DEBUG and RELEASE builds.
/// - In DEBUG builds issues are additionally logged via `os.Logger` (iOS 14+,
///   macOS 11+, etc.) or `print` fallback.
/// - Per-decoder loggers (set via `JSONDecoder.setLenientDecodingLogHandler(_:)`)
///   take precedence over the global logger for that decoder.
public typealias LenientDecodingLogHandler = @Sendable (LenientDecodingLogEntry) -> Void

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Supporting Code

/// This exists because `Swift.Mutex` is only available on macOS 15+ /  iOS 18+.
/// This library supports iOS 13+ / macOS 10.15+, so we use `NSLock` as the
/// underlying implementation.
@available(macOS, deprecated: 15.0, message: "Use Swift.Mutex instead")
@available(iOS, deprecated: 18.0, message: "Use Swift.Mutex instead")
@available(tvOS, deprecated: 18.0, message: "Use Swift.Mutex instead")
@available(watchOS, deprecated: 11.0, message: "Use Swift.Mutex instead")
@available(macCatalyst, deprecated: 18.0, message: "Use Swift.Mutex instead")
internal final class _NSLock<Value: ~Copyable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: consuming Value) {
    self.value = value
  }

  func withLock<Result: ~Copyable>(_ body: (inout sending Value) -> sending Result)
    -> sending Result {
    lock.lock(); defer { lock.unlock() }
    return body(&value)
  }
}
