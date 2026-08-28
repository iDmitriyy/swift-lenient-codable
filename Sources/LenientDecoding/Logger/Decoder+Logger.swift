//
//  Decoder+Logger.swift
//  LenientCodable
//
//  Created by Dmitriy Ignatyev on 26.08.2026.
//

import Foundation

// MARK: - Decoder Extension

extension JSONDecoder {
  /// Attaches a per-decoder log handler.
  ///
  /// When set, all lenient decoding failures decoded through this decoder
  /// are routed to `logHandler` instead of the global log handler. Useful for
  /// isolating logs per decoder or for testing.
  ///
  /// - Parameter effectiveLogHandler: The log handler to receive failures from this decoder.
  public func setLenientDecodingLogHandler(_ logHandler: @escaping LenientDecodingLogHandler) {
    userInfo[.lenientDecodingLogHandler] = _LogHandlerBox(logHandler: logHandler)
  }
}

extension Decoder {
  /// Returns either logger provided via `Decoder.userInfo` or injected global log handler.
  ///
  /// Logging Pipeline:
  /// ```
  ///           ┌──────────────────────────────────────────┐
  ///           │                                          │
  ///           │    Decoder.effectiveLogHandler(entry)    │
  ///           └────────────────────┬─────────────────────┘
  ///                                │
  ///                                ▼
  ///           ┌──────────────────────────────────────────┐
  ///           │         effectiveLogHandler              │
  ///           │           (routing block)                │
  ///           └──────┬────────────────────────────┬──────┘
  ///                  │                            │
  ///                  │                            ▼
  ///                  │                   ┌────────────────────────┐
  ///                  │                   │ _debug_GlobalLogHandler│
  ///       Decoder handler is set         │    (only DEBUG builds) │
  ///                  ┬                   └────────────────────────┘
  ///    yes ┌─────────┴───────────┐ no
  ///        ▼                     ▼
  /// ┌─────────────┐ ┌──────────────────────────┐
  /// │ per-decoder │ │     globalLogHandler     │
  /// │  handler    │ │(injected via inject_once)│
  /// └─────────────┘ └──────────────────────────┘
  /// ```
  package var effectiveLogHandler: LenientDecodingLogHandler {
    let decoderLogHandler: LenientDecodingLogHandler?
    if let value = userInfo[.lenientDecodingLogHandler] {
      if let box = (value as? _LogHandlerBox) {
        decoderLogHandler = box.logHandler
      } else {
        lazy var message = "Invalid logger type in Decoder.userInfo; falling back to global logger."
        lazy var internalsIssue = LenientDecodingLogEntry.internalsImpIssue(message: message)

        #if DEBUG
          LenientErrorLogger._debug_GlobalLogHandler(internalsIssue)
        #endif
        LenientErrorLogger.globalLogHandler?(internalsIssue)
        
        decoderLogHandler = nil
      }
    } else {
      decoderLogHandler = nil
    }

    return { logEntry in
      #if DEBUG
        LenientErrorLogger._debug_GlobalLogHandler(logEntry)
      #endif
      let handler = decoderLogHandler ?? LenientErrorLogger.globalLogHandler
      handler?(logEntry)
    }
  }
}

/// Closures cannot be stored directly in `[CodingUserInfoKey: any Sendable]`
/// because they are not `Sendable`-conforming types. This wrapper conforms to
/// `Sendable` and holds the `LogHandler`.
internal final class _LogHandlerBox: Sendable {
  let logHandler: LenientDecodingLogHandler
  
  init(logHandler: @escaping LenientDecodingLogHandler) {
    self.logHandler = logHandler
  }
}

extension CodingUserInfoKey {
  /// UserInfo key for per-decoder log handler.
  package static let lenientDecodingLogHandler = CodingUserInfoKey(rawValue: "_lenientDecodingLogHandler")!
}
