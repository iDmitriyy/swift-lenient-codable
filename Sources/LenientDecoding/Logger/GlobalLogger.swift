//
//  GlobalLogger.swift
//  LenientCodable
//
//  Created by Dmitriy Ignatyev on 26.08.2026.
//

import Synchronization
#if canImport(os)
  import os
#endif

// MARK: - Inject Once Global Handler

extension LenientErrorLogger {
  /// Injects the global log handler. Can only be called once.
  /// Per-decoder loggers (via ``JSONDecoder.setLenientDecodingLogHandler(_:)``)
  /// override the global logger for that decoder.
  ///
  /// The injected logger receives **all** lenient decoding failures in both
  /// DEBUG and RELEASE builds.
  /// Without injection, DEBUG builds use the internal `os.Logger`/`print`
  /// fallback, RELEASE builds are silent.
  ///
  /// - Parameters:
  ///   - logger: The log handler to receive all lenient decoding errors.
  ///   - rateLimits: Optional custom rate limits. On macOS 15+/iOS 18+ these are
  ///     stored atomically and respected by every `LenientDecodingLogEntry` created
  ///     afterwards. On older OS versions the default `(3, 3)` is used and this
  ///     parameter is ignored.
  ///   - file: Source file (for assertion).
  ///   - line: Source line (for assertion).
  public static func inject_once(
    lenientDecodingLogHandler logger: @escaping LenientDecodingLogHandler,
    rateLimits: (perDecodingReportedFieldsLimit: UInt8, elementsPerCollectionLimit: UInt8)? = nil,
    file: StaticString = #file,
    line: UInt = #line,
  ) {
    let (alreadyInjectedGlobalLogger, pendingEntries) = _globalLogHandler
      .withLock { variant -> (LenientDecodingLogHandler?, [LenientDecodingLogEntry]) in
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
}

// MARK: - Global Logger

extension LenientErrorLogger {
  /// Returns the current global logger.
  ///
  /// Stale references to the `.pending` variant are safe: when ``inject_once``
  /// calls ``extractPendingEntriesAndForwardNew(toInjectedLogger:)``, the old
  /// ``PendingEntriesLogger`` is updated so any subsequent `append` calls on it
  /// route directly to the injected log handler.
  internal static var globalLogHandler: LenientDecodingLogHandler {
    { logEntry in
      #if DEBUG
        _debug_GlobalLogHandler(logEntry)
      #endif
      let globalLogHandler = _globalLogHandler.withLock { $0.instance }
      globalLogHandler(logEntry)
    }
  }

  // MARK: Debug Global Logger

  /// Default log handler used in DEBUG builds.
  /// Uses os.Logger on supported platforms, falls back to print.
  #if DEBUG
    #if canImport(os)
      @available(iOS 14, macOS 11, tvOS 14, watchOS 7, macCatalyst 14, *)
      fileprivate static let _osLogger = Logger(subsystem: "LenientCodable", category: "decoding")
    #endif

    internal static let _debug_GlobalLogHandler: LenientDecodingLogHandler = { logEntry in
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
}

//===-------------------------------------------------------------------------------------------------------------------===//

// MARK: - Global Logger Config

extension LenientErrorLogger {
  /// Thread-safe storage for the current global logger variant.
  fileprivate static let _globalLogHandler = _NSLock(_GlobalLoggerVariant.pending(PendingEntriesLogger()))

  /// Represents the two states of the global logger lifecycle.
  fileprivate enum _GlobalLoggerVariant {
    /// Logger not yet injected. Entries are buffered in the associated
    /// ``PendingEntriesLogger`` until ``inject_once`` drains and forwards
    /// them to the injected logger.
    case pending(PendingEntriesLogger)
    
    /// Logger injected. Entries are logged by associated handler.
    case injected(LenientDecodingLogHandler)
    
    var instance: LenientDecodingLogHandler {
      switch self {
      case .pending(let pendingEntriesLogger):
        { logEntry in pendingEntriesLogger.append(logEntry: logEntry) }
      case .injected(let injectedLogger):
        injectedLogger
      }
    }
  }
}

// MARK: Rate Limits

extension LenientErrorLogger {
  /// Two rate-limit values packed into a single `UInt16` for lock-free atomic access.
  ///
  /// - Lower byte: `perDecodingReportedFieldsLimit` – max issue entries per decoded object.
  /// - Upper byte: `elementsPerCollectionLimit` – max per-element issues for collection (array/dictionary).
  ///
  /// On macOS 15+/iOS 18+ the values can be overridden
  /// via ``inject_once(LenientDecodingLogHandler:rateLimits:...)``.
  /// On older OS versions the getter returns the hardcoded default `(3, 3)`
  /// and the setter does not available.
  internal static var _rateLimits: (perDecodingReportedFieldsLimit: UInt8, elementsPerCollectionLimit: UInt8) {
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
  
  @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
  fileprivate static let __bitpackedRateLimits = Atomic<UInt16>(.bitpackRateLimits(perDecodingReportedFieldsLimit: 3,
                                                                                   elementsPerCollectionLimit: 3))
}

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
