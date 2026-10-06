//
//  SteamLaunchLog.swift
//  Mythic
//

// Copyright © 2023-2026 vapidinfinity

import Foundation
import OSLog

/**
 A plain-text record of Steam title launches, kept on disk so a launch that ends without any alert can still be explained.

 Wine's own output is written to a file rather than read through a pipe: the file stays valid after the launcher
 process exits, so what the game it started goes on to print is captured too.
 */
enum SteamLaunchLog {
    private static let log: Logger = .custom(category: "SteamLaunchLog")

    static var directory: URL {
        Bundle.appHome!.appending(path: "Logs")
    }

    /// One line per event, across launches.
    static var summaryURL: URL {
        directory.appending(path: "steam-launch.log")
    }

    /// Wine's combined output for the most recent launch of `title`.
    static func outputURL(for title: String) -> URL {
        let name = title.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return directory.appending(path: "steam-\(name)-last-launch.log")
    }

    static func record(_ message: String) {
        log.notice("\(message, privacy: .public)")

        let line = "\(Date.now.formatted(.iso8601)) \(message)\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: summaryURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: summaryURL)
        }
    }

    /// Creates (or truncates) the output file for a launch and opens it for writing.
    static func openOutputFile(for title: String) throws -> FileHandle {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = outputURL(for: title)
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    static func tail(of url: URL, lines count: Int) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .init() }
        return text.split(whereSeparator: \.isNewline).suffix(count).joined(separator: "\n")
    }
}
