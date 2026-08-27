//
//  PendingEntriesLogger.swift
//  LenientCodable
//
//  Created by Dmitriy Ignatyev on 26.08.2026.
//

// MARK: PendingEntries Logger

/// Buffers log entries received before the global logger is injected.
///
/// Created automatically at library init time.
/// The buffer is capped at ``_pendingEntriesLimit`` entries.
internal final class PendingEntriesLogger: Sendable {
  private let _pendingEntriesLimit: UInt8 = 5
  private let _state = _NSLock<State>((pendingEntries: [], injectedLogger: nil, isOverflowLogged: false))

  /// Atomically drains buffered entries and installs the injected logger.
  ///
  /// Returns the buffered entries to ``inject_once``.
  /// After this call, ``append(logEntry:)`` routes new entries directly to `injectedLogger`.
  internal func extractPendingEntriesAndForwardNew(toInjectedLogger injectedLogger: @escaping LenientDecodingLogHandler)
    -> [LenientDecodingLogEntry] {
    _state.withLock { state in
      let entries = state.pendingEntries
      state.pendingEntries = []
      state.injectedLogger = injectedLogger
      return entries
    }
  }

  internal func append(logEntry: LenientDecodingLogEntry) {
    lazy var overflowMessage = "pending buffer overflow: some decoding issues were dropped because the global "
      + "logger was not injected yet"

    #if DEBUG
      func overflowDebugLog() {
        var logEntry = logEntry
        logEntry.annotatePendingBufferOverflow(message: overflowMessage)
        LenientErrorLogger._debug_GlobalLogHandler(logEntry)
      }
    #endif

    // FIXME: - log out of lock
    
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
  
  private typealias State =
    (pendingEntries: [LenientDecodingLogEntry], injectedLogger: LenientDecodingLogHandler?, isOverflowLogged: Bool)
}
