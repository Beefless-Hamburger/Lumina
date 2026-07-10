import AppKit
import Foundation
import os

actor SystemBetterDisplayTransport: BetterDisplayTransport {
    private enum LaunchRequestResult {
        case requested
        case unavailable
        case failed(String)
    }

    private let fallbackApplicationPath = "/Applications/BetterDisplay.app"
    private let fallbackCLIPath = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
    private let appBundleID = "pro.betterdisplay.BetterDisplay"
    private let logger = Logger(subsystem: "io.github.lumina-app.Lumina", category: "BetterDisplayTransport")
    private let processRunner: AsyncProcessRunner

    private var launchInProgress = false
    private var commandTail: Task<Void, Never>?
    private var commandGeneration = 0

    init(processRunner: AsyncProcessRunner = AsyncProcessRunner()) {
        self.processRunner = processRunner
    }

    func ensureRunning(context: String) async -> BetterDisplayAvailability {
        if Task.isCancelled {
            return .cancelled
        }

        if await isBetterDisplayRunning() {
            return .running
        }

        let ownsLaunchAttempt = !launchInProgress
        if ownsLaunchAttempt {
            launchInProgress = true
        } else {
            logger.debug("Waiting for an existing BetterDisplay launch attempt before \(context, privacy: .private).")
        }

        defer {
            if ownsLaunchAttempt {
                launchInProgress = false
            }
        }

        if ownsLaunchAttempt {
            logger.info("Launching BetterDisplay before \(context, privacy: .private).")

            switch await Self.requestLaunch(bundleIdentifier: appBundleID, fallbackApplicationPath: fallbackApplicationPath) {
            case .requested:
                break
            case .unavailable:
                logger.error("BetterDisplay was not found for bundle identifier \(self.appBundleID, privacy: .public).")
                return .unavailable
            case let .failed(message):
                logger.error("BetterDisplay launch failed: \(message, privacy: .private)")
                return .launchFailed(message)
            }
        }

        return await waitForBetterDisplayToRun()
    }

    func run(arguments: [String], context: String, captureOutput: Bool) async -> BetterDisplayExecutionResult {
        if Task.isCancelled {
            return .failure(.cancelled)
        }

        guard let executableURL = await betterDisplayExecutableURL() else {
            logger.error("BetterDisplay executable was not found while \(context, privacy: .private).")
            return .failure(.executableMissing)
        }

        commandGeneration += 1
        let generation = commandGeneration
        let previousCommand = commandTail
        let runner = processRunner

        let executionTask = Task<BetterDisplayExecutionResult, Never> {
            if let previousCommand {
                await previousCommand.value
            }

            if Task.isCancelled {
                return .failure(.cancelled)
            }

            return await runner.run(
                executableURL: executableURL,
                arguments: arguments,
                captureOutput: captureOutput
            )
        }

        let tailTask = Task<Void, Never> {
            _ = await executionTask.value
        }
        commandTail = tailTask

        let result = await withTaskCancellationHandler {
            await executionTask.value
        } onCancel: {
            executionTask.cancel()
        }

        if generation == commandGeneration {
            commandTail = nil
        }

        log(result: result, context: context)
        return result
    }

    private func waitForBetterDisplayToRun() async -> BetterDisplayAvailability {
        for _ in 0..<20 {
            if Task.isCancelled {
                logger.debug("Cancelled BetterDisplay launch wait.")
                return .cancelled
            }

            if await isBetterDisplayRunning() {
                return .running
            }

            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                logger.debug("Cancelled BetterDisplay launch wait.")
                return .cancelled
            }
        }

        logger.warning("Timed out waiting for BetterDisplay to launch.")
        return .timedOut
    }

    private func isBetterDisplayRunning() async -> Bool {
        await MainActor.run { [appBundleID] in
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == appBundleID }
        }
    }

    @MainActor
    private static func requestLaunch(bundleIdentifier: String, fallbackApplicationPath: String) async -> LaunchRequestResult {
        let workspace = NSWorkspace.shared
        let applicationURL: URL

        if let discoveredURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            applicationURL = discoveredURL
        } else {
            let fallbackURL = URL(fileURLWithPath: fallbackApplicationPath, isDirectory: true)
            guard FileManager.default.fileExists(atPath: fallbackURL.path) else {
                return .unavailable
            }
            applicationURL = fallbackURL
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false

        return await withCheckedContinuation { continuation in
            workspace.openApplication(at: applicationURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(returning: .failed(error.localizedDescription))
                } else {
                    continuation.resume(returning: .requested)
                }
            }
        }
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

    private func log(result: BetterDisplayExecutionResult, context: String) {
        let trimmedError = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        switch result.status {
        case .succeeded:
            if !trimmedError.isEmpty {
                logger.debug("BetterDisplay command \(context, privacy: .private) stderr: \(trimmedError, privacy: .private)")
            }
        case .executableMissing:
            logger.error("BetterDisplay executable was unavailable while \(context, privacy: .private).")
        case let .launchFailed(message):
            logger.error("Failed to start BetterDisplay while \(context, privacy: .private): \(message, privacy: .private)")
        case let .nonZeroExit(exitCode):
            logger.error("BetterDisplay command \(context, privacy: .private) failed with exit code \(exitCode, privacy: .public). stderr: \(trimmedError, privacy: .private)")
        case .timedOut:
            logger.error("BetterDisplay command timed out while \(context, privacy: .private).")
        case .cancelled:
            logger.debug("BetterDisplay command was cancelled while \(context, privacy: .private).")
        }

        if result.outputWasTruncated || result.errorOutputWasTruncated {
            logger.warning("BetterDisplay output was truncated while \(context, privacy: .private).")
        }
    }
}
