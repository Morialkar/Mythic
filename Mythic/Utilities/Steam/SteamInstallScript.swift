//
//  SteamInstallScript.swift
//  Mythic
//

// Copyright © 2023-2026 vapidinfinity

import Foundation

/**
 Registry entries a Steam title declares in its `installscript.vdf`.

 Steam applies these when it installs a game; SteamCMD does not. Titles such as Skyrim read them back at
 runtime — its launcher shows "INSTALL" instead of "PLAY" when `Installed Path` is missing — so they
 have to be replayed into the Wine container before launch.

 Only the `registry` section is handled. `run process` (DirectX, redistributables) is deliberately left alone.
 */
enum SteamInstallScript {
    struct RegistryValue: Equatable, Sendable {
        /// Full key in `reg add` syntax, e.g. `HKLM\Software\Bethesda Softworks\Skyrim`.
        var key: String
        var name: String
        var data: String
        var isDWORD: Bool

        /// Steam writes `HKLM\Software` through the 32-bit view, which is where 32-bit titles read it back.
        var usesWow64View: Bool { key.uppercased().hasPrefix(#"HKLM\SOFTWARE"#) }
    }

    private static let hives: [String: String] = [
        "hkey_local_machine": "HKLM",
        "hkey_current_user": "HKCU",
        "hkey_classes_root": "HKCR"
    ]

    /// - Parameter installDirectory: Windows-style path substituted for `%INSTALLDIR%`.
    static func registryValues(from script: [String: ValveDataFormat.Value],
                               installDirectory: String) -> [RegistryValue] {
        guard let registry = script[caseInsensitive: "installscript"]?["registry"]?.objectValue else { return [] }

        var values: [RegistryValue] = []

        for (path, entry) in registry {
            guard let entries = entry.objectValue else { continue }

            let components = path.split(separator: "\\", maxSplits: 1, omittingEmptySubsequences: true)
            guard components.count == 2,
                  let hive = hives[components[0].lowercased()] else { continue }

            let key = hive + "\\" + components[1]

            for (typeName, isDWORD) in [("string", false), ("dword", true)] {
                guard let typed = entries[caseInsensitive: typeName]?.objectValue else { continue }

                for (name, value) in typed {
                    guard let raw = value.stringValue else { continue }
                    values.append(.init(
                        key: key,
                        name: name,
                        data: raw.replacingOccurrences(of: "%INSTALLDIR%", with: installDirectory,
                                                       options: .caseInsensitive),
                        isDWORD: isDWORD
                    ))
                }
            }
        }

        return values.sorted { ($0.key, $0.name) < ($1.key, $1.name) }
    }

    /// Locates `installscript.vdf` case-insensitively; Steam depots are not consistent about its casing.
    static func scriptURL(in installDirectory: URL) -> URL? {
        let contents = try? FileManager.default.contentsOfDirectory(at: installDirectory,
                                                                   includingPropertiesForKeys: nil)
        return contents?.first { $0.lastPathComponent.caseInsensitiveCompare("installscript.vdf") == .orderedSame }
    }

    static func registryValues(inInstallDirectory installDirectory: URL) throws -> [RegistryValue] {
        guard let url = scriptURL(in: installDirectory) else { return [] }

        // Wine exposes the host filesystem as drive Z:.
        let windowsPath = "Z:" + installDirectory.path(percentEncoded: false).replacingOccurrences(of: "/", with: "\\")

        return registryValues(from: try ValveDataFormat.parse(contentsOf: url), installDirectory: windowsPath)
    }
}
