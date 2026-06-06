import AppKit
import Foundation
import os

actor SystemBetterDisplayTransport: BetterDisplayTransport {
    private let fallbackCLIPath = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
    private let appBundleID = "pro.betterdisplay.BetterDisplay"
    private let logger = Logger(subsystem: "io.github.lumina-app.Lumina", category: "BetterDisplayTransport")

    func ensureRunning(context: String) async -> Bool {
        let isRunning = await MainActor.run { [appBundleID] in
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == appBundleID }
        }

        if isRunning {
            return true
        }

        logger.info("Launching BetterDisplay before \(context, privacy: .private).")

        let launchLogger = logger
        let requestedLaunch = await MainActor.run { [appBundleID, launchLogger] in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) else {
                return false
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    launchLogger.error("BetterDisplay launch failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return true
        }

        guard requestedLaunch else {
            logger.error("BetterDisplay was not found for bundle identifier \(self.appBundleID, privacy: .public).")
            return false
        }

        let attempts = 20
        for _ in 0..<attempts {
            let isRunningNow = await MainActor.run { [appBundleID] in
                NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == appBundleID }
            }

            if isRunningNow {
                return true
            }

            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                logger.debug("Cancelled BetterDisplay launch wait.")
                return false
            }
        }

        logger.warning("Timed out waiting for BetterDisplay to launch.")
        return false
    }

    func run(arguments: [String], context: String, captureOutput: Bool) async -> BetterDisplayExecutionResult? {
        guard let executableURL = await betterDisplayExecutableURL() else {
            logger.error("BetterDisplay executable was not found while \(context, privacy: .private).")
            return nil
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = captureOutput ? standardOutput : FileHandle.nullDevice
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            logger.error("Failed to start BetterDisplay while \(context, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return nil
        }

        process.waitUntilExit()

        let outputData = captureOutput ? standardOutput.fileHandleForReading.readDataToEndOfFile() : Data()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let outputString = String(data: outputData, encoding: .utf8) ?? ""
        let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            logger.error("BetterDisplay command \(context, privacy: .private) failed with exit code \(process.terminationStatus, privacy: .public). stderr: \(errorString, privacy: .private)")
            return nil
        }

        if !errorString.isEmpty {
            logger.debug("BetterDisplay command \(context, privacy: .private) stderr: \(errorString, privacy: .private)")
        }

        return BetterDisplayExecutionResult(output: outputString, errorOutput: errorString, exitCode: process.terminationStatus)
    }

    private func betterDisplayExecutableURL() async -> URL? {
        let fileManager = FileManager.default
        let applicationURL = await MainActor.run { [appBundleID] in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID)
        }

        if let applicationURL {
            let executableURL = applicationURL.appendingPathComponent("Contents/MacOS/BetterDisplay")
            if fileManager.isExecutableFile(atPath: executableURL.path) {
                return executableURL
            }
        }

        guard fileManager.isExecutableFile(atPath: fallbackCLIPath) else {
            return nil
        }

        return URL(fileURLWithPath: fallbackCLIPath)
    }
}
