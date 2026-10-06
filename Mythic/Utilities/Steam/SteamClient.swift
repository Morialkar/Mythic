//
//  SteamClient.swift
//  Mythic
//

// Copyright © 2023-2026 vapidinfinity

import Foundation
import OSLog

/**
 The Windows Steam client, installed into a Wine container.

 Titles that authenticate through the live client (Steamworks) fail to start without it, and SteamCMD —
 which Mythic uses to acquire games — is no substitute. The client is installed per container and on
 demand, so containers whose games don't need it never pay for it, and every game sharing a container
 shares one install and one sign-in.

 Whether the client actually survives on a given Wine version is a property of the engine, not of this
 type: its Chromium helper is the usual casualty. Everything here reports what happened rather than
 assuming it worked.
 */
enum SteamClient {
    static let log: Logger = .custom(category: "SteamClient")

    /// Valve's own installer; the URL behind the "Install Steam" button on store.steampowered.com.
    static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    struct InstallError: LocalizedError {
        let reason: String
        var errorDescription: String? { String(localized: "Unable to install the Steam client.") + "\n" + reason }
    }

    struct SignInTimeoutError: LocalizedError {
        let waited: TimeInterval
        var errorDescription: String? {
            String(localized: """
                The Steam client didn't finish signing in within \(waited.formatted(.number.precision(.fractionLength(0)))) s.
                Its output is in \(logURL.prettyPath).
                """)
        }
    }

    // MARK: - Locations

    static func executableURL(in containerURL: URL) -> URL? {
        let directory = containerURL.appending(path: "drive_c/Program Files (x86)/Steam")

        return ["steam.exe", "Steam.exe"]
            .map { directory.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    static func isInstalled(in containerURL: URL) -> Bool {
        executableURL(in: containerURL) != nil
    }

    /// Everything the client prints, kept so a failure to start can be diagnosed afterwards.
    static var logURL: URL {
        SteamCMD.directory.appending(path: "WineSteamClient.log")
    }

    // MARK: - Installation

    /// Downloads Valve's installer and runs it silently inside the container.
    static func install(in containerURL: URL) async throws {
        SteamLaunchLog.record("Downloading the Steam installer for \(containerURL.lastPathComponent)")

        let (downloadedURL, response) = try await URLSession.shared.download(from: installerURL)
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw InstallError(reason: String(localized: "Valve's server answered with HTTP \(status)."))
        }

        // The installer is a PE executable of a couple of megabytes; anything else is not what we asked for.
        let installer = try Data(contentsOf: downloadedURL, options: .mappedIfSafe)
        guard installer.count > 500_000, installer.prefix(2) == Data("MZ".utf8) else {
            throw InstallError(reason: String(localized: "The download isn't a Windows installer."))
        }

        let installerURL = FileManager.default.temporaryDirectory.appending(path: "SteamSetup-\(UUID().uuidString).exe")
        try installer.write(to: installerURL)
        defer { try? FileManager.default.removeItem(at: installerURL) }

        let process: Process = .init()
        process.arguments = [installerURL.path(percentEncoded: false), "/S"]
        Wine.transformProcess(process, containerURL: containerURL)

        let result = try await process.runWrapped()
        SteamLaunchLog.record("Steam installer exited with status \(process.terminationStatus)")

        guard isInstalled(in: containerURL) else {
            let output = (result.standardError ?? "").split(separator: "\n").suffix(4).joined(separator: "\n")
            throw InstallError(reason: String(localized: "The installer finished, but steam.exe isn't in the container.") + "\n" + output)
        }

        if usesWebHelperWrapper {
            try await prepareWebHelper(in: containerURL)
        }
    }

    // MARK: - Browser wrapper
    //
    // On Wine 11 the client's Chromium helper paints its windows black unless it runs with software rendering in a
    // single process. A small stand-in executable, shipped with the engine, sits where steamwebhelper.exe was and
    // starts the real one (kept beside it as steamwebhelper_real.exe) with those options.

    /// The stand-in, as shipped with the engine. Engines that don't carry it don't need it.
    static var wrapperURL: URL {
        Engine.directory.appending(path: "extras/steamwebhelper_wrapper.exe")
    }

    static var usesWebHelperWrapper: Bool {
        FileManager.default.fileExists(atPath: wrapperURL.path(percentEncoded: false))
    }

    private static let wrapperMarker = Data("MYTHIC-STEAM-WRAPPER-1".utf8)
    private static let wrapperArguments = "--disable-gpu --single-process"

    private static func webHelperDirectory(in containerURL: URL) -> URL {
        containerURL.appending(path: "drive_c/Program Files (x86)/Steam/bin/cef/cef.win64")
    }

    /// Whether steamwebhelper.exe is the stand-in rather than Steam's own file.
    static func isWrapperInstalled(in containerURL: URL) -> Bool {
        let helper = webHelperDirectory(in: containerURL).appending(path: "steamwebhelper.exe")
        guard let data = try? Data(contentsOf: helper, options: .mappedIfSafe) else { return false }
        return data.range(of: wrapperMarker) != nil
    }

    /**
     Puts the stand-in in place of Steam's steamwebhelper.exe, and keeps Steam's own file as steamwebhelper_real.exe.

     The stand-in is padded to the size of the original: at startup Steam checks its files by size and puts back
     any that differ. Steam must not be running.
     */
    static func installWrapper(in containerURL: URL) throws {
        let directory = webHelperDirectory(in: containerURL)
        let helper = directory.appending(path: "steamwebhelper.exe")
        let real = directory.appending(path: "steamwebhelper_real.exe")

        guard FileManager.default.fileExists(atPath: helper.path(percentEncoded: false)) else {
            throw InstallError(reason: String(localized: "Steam's browser component isn't in the container yet."))
        }

        // Steam's own file, new or updated, is what the stand-in has to start.
        if !isWrapperInstalled(in: containerURL) {
            try? FileManager.default.removeItem(at: real)
            try FileManager.default.copyItem(at: helper, to: real)
        }

        let size = try FileManager.default.attributesOfItem(atPath: real.path(percentEncoded: false))[.size] as? Int ?? 0
        var wrapper = try Data(contentsOf: wrapperURL)

        guard wrapper.count <= size else {
            throw InstallError(reason: String(localized: "The browser stand-in is larger than Steam's own file."))
        }

        wrapper.append(Data(count: size - wrapper.count))
        try wrapper.write(to: helper, options: .atomic)
        try Data(wrapperArguments.utf8).write(to: directory.appending(path: "steamwebhelper_args.txt"), options: .atomic)

        SteamLaunchLog.record("Installed the Steam browser stand-in in \(containerURL.lastPathComponent) (\(size) bytes)")
    }

    /**
     Lets Steam update itself and download its browser component, then puts the stand-in in place.

     A fresh client updates, quits, and only fetches the browser component on a later start, so it is started up to
     three times, and stopped each time once its files stop changing.
     */
    private static func prepareWebHelper(in containerURL: URL) async throws {
        guard let executable = executableURL(in: containerURL) else {
            throw InstallError(reason: String(localized: "The Steam client isn't installed in this container."))
        }

        let helper = webHelperDirectory(in: containerURL).appending(path: "steamwebhelper.exe")
        let helperPath = helper.path(percentEncoded: false)

        func helperSize() -> Int {
            (try? FileManager.default.attributesOfItem(atPath: helperPath)[.size] as? Int) ?? 0
        }

        for round in 1...3 {
            if helperSize() > 1_000_000 { break }

            SteamLaunchLog.record("Letting Steam update itself (round \(round) of 3)")
            let process = try launchClient(executable, in: containerURL, arguments: ["-no-cef-sandbox"])
            _ = process

            // The component is done when it exists and has stopped growing for a few polls.
            var lastSize = 0, stablePolls = 0
            let deadline = Date.now.addingTimeInterval(180)

            while Date.now < deadline, stablePolls < 3 {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(3))

                let size = helperSize()
                stablePolls = (size > 1_000_000 && size == lastSize) ? stablePolls + 1 : 0
                lastSize = size
            }

            await Wine.stopAll(containerURL: containerURL)
        }

        guard helperSize() > 1_000_000 else {
            throw InstallError(reason: String(localized: "Steam didn't download its browser component."))
        }

        try installWrapper(in: containerURL)
    }

    /// Starts steam.exe without waiting for it, sending its output to the client log.
    private static func launchClient(_ executable: URL, in containerURL: URL, arguments: [String]) throws -> Process {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process: Process = .init()
        process.arguments = [executable.path(percentEncoded: false)] + arguments
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.standardOutput = logHandle
        process.standardError = logHandle
        Wine.transformProcess(process, containerURL: containerURL)

        try process.run()
        return process
    }

    private static func launchArguments(remembered: Bool) -> [String] {
        // The sandbox for Chromium's helper can't work under Wine; the flag is what makes the client viable at all.
        var arguments = ["-no-cef-sandbox"]

        // Steam checks its files at startup and restores any it finds different, which would undo the stand-in.
        if usesWebHelperWrapper { arguments += ["-noverifyfiles", "-norepairfiles", "-nobootstrapupdate"] }

        if remembered { arguments.append("-silent") }
        return arguments
    }

    // MARK: - Running

    /// Whether the client is up and signed in, which is when Steamworks titles can reach it.
    static func isSignedIn(in containerURL: URL) async -> Bool {
        guard let value = try? await Wine.queryRegistryKey(containerURL: containerURL,
                                                           key: #"HKCU\Software\Valve\Steam\ActiveProcess"#,
                                                           name: "ActiveUser",
                                                           type: .dword),
              let user = Int(value.trimmingPrefix("0x"), radix: 16) else { return false }

        return user != 0
    }

    /// Whether a previous sign-in was remembered, so the client can start without showing its window.
    private static func hasRememberedLogin(in containerURL: URL) async -> Bool {
        guard let user = try? await Wine.queryRegistryKey(containerURL: containerURL,
                                                          key: #"HKCU\Software\Valve\Steam"#,
                                                          name: "AutoLoginUser",
                                                          type: .string) else { return false }
        return !user.isEmpty
    }

    /**
     Starts the client if needed and waits for it to be signed in.

     - Parameter interactive: `true` when the user is being walked through setting the client up: it starts with its
       window shown, so they can sign in, and the wait is long. Otherwise this runs on every launch of a Steam
       title, where it must never hold the game up for long or fail it: the client is only started if a sign-in
       was remembered (there is nothing useful to start otherwise), silently, and the wait is short. A title that
       genuinely needs the client reports that itself.
     */
    static func ensureRunning(in containerURL: URL, interactive: Bool = false) async throws {
        guard let executable = executableURL(in: containerURL) else {
            throw InstallError(reason: String(localized: "The Steam client isn't installed in this container."))
        }

        if await isSignedIn(in: containerURL) { return }

        let remembered = await hasRememberedLogin(in: containerURL)

        if !interactive, !remembered {
            SteamLaunchLog.record("The Steam client is installed in \(containerURL.lastPathComponent) but not signed in; not starting it for this launch")
            return
        }

        let waited: TimeInterval = interactive ? (remembered ? 120 : 600) : 45

        // An update may have put Steam's own browser component back; the stand-in has to be in place before it starts.
        if usesWebHelperWrapper, FileManager.default.fileExists(
            atPath: webHelperDirectory(in: containerURL).appending(path: "steamwebhelper.exe").path(percentEncoded: false)
        ), !isWrapperInstalled(in: containerURL) {
            try installWrapper(in: containerURL)
        }

        let process = try launchClient(executable, in: containerURL, arguments: launchArguments(remembered: remembered))

        SteamLaunchLog.record("Starting the Steam client (remembered sign-in: \(remembered), interactive: \(interactive)); waiting up to \(Int(waited)) s")
        _ = process

        // The first steam.exe may exit after handing over to the real client, so only the sign-in matters.
        let deadline = Date.now.addingTimeInterval(waited)
        while Date.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(3))

            if await isSignedIn(in: containerURL) {
                SteamLaunchLog.record("The Steam client is signed in")
                return
            }
        }

        SteamLaunchLog.record("The Steam client wasn't signed in after \(Int(waited)) s")
        if interactive { throw SignInTimeoutError(waited: waited) }
    }
}
