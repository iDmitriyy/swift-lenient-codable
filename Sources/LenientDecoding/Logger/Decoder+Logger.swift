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
  /// - Parameter logHandler: The log handler to receive failures from this decoder.
  public func setLenientDecodingLogHandler(_ logHandler: @escaping LenientDecodingLogHandler) {
    userInfo[.lenientDecodingLogHandler] = _LogHandlerBox(logHandler: logHandler)
  }
}

extension Decoder {
  /// Returns either logger provided via `Decoder.userInfo` or injected global log handler.
  package var logHandler: LenientDecodingLogHandler {
    if let value = userInfo[.lenientDecodingLogHandler] {
      if let box = (value as? _LogHandlerBox) {
        return box.logHandler
      } else {
        let message = "Invalid logger type in Decoder.userInfo; falling back to global logger."
        let internalsIssue = LenientDecodingLogEntry.internalsImpIssue(message: message)

        let fallbackLogHandler = LenientErrorLogger.globalLogHandler
        fallbackLogHandler(internalsIssue)
        return fallbackLogHandler
      }
    } else {
      return LenientErrorLogger.globalLogHandler
    }
  }
}

/// Closures cannot be stored directly in `[CodingUserInfoKey: any Sendable]`
/// because they are not `Sendable`-conforming types. This wrapper conforms to
/// `Sendable` and holds the `LogHandler`.
fileprivate struct _LogHandlerBox: Sendable {
  let logHandler: LenientDecodingLogHandler
}

extension CodingUserInfoKey {
  /// UserInfo key for per-decoder log handler.
  package static let lenientDecodingLogHandler = CodingUserInfoKey(rawValue: "lenientDecodingLogHandler")!
}
