import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct AsyncProcessRunner: Sendable {
    let timeoutNanoseconds: UInt64
    let maximumCapturedBytes: Int

    init(timeoutNanoseconds: UInt64 = 15_000_000_000, maximumCapturedBytes: Int = 256 * 1024) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.maximumCapturedBytes = max(0, maximumCapturedBytes)
    }

    func run(executableURL: URL, arguments: [String], captureOutput: Bool) async -> BetterDisplayExecutionResult {
        if Task.isCancelled {
            return .failure(.cancelled)
        }

        let coordinator = ProcessExecutionCoordinator(
            executableURL: executableURL,
            arguments: arguments,
            captureOutput: captureOutput,
            timeoutNanoseconds: timeoutNanoseconds,
            maximumCapturedBytes: maximumCapturedBytes
        )

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                coordinator.start(continuation: continuation)
            }
        } onCancel: {
            coordinator.cancel()
        }
    }
}

private final class ProcessExecutionCoordinator: @unchecked Sendable {
    private enum Stream {
        case standardOutput
        case standardError
    }

    private enum StopReason {
        case cancelled
        case timedOut

        var status: BetterDisplayExecutionStatus {
            switch self {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .timedOut
            }
        }
    }

    private let process: Process
    private let standardOutputPipe: Pipe?
    private let standardErrorPipe = Pipe()
    private let timeoutNanoseconds: UInt64
    private let maximumCapturedBytes: Int
    private let lock = NSLock()

    private var continuation: CheckedContinuation<BetterDisplayExecutionResult, Never>?
    private var completedResult: BetterDisplayExecutionResult?
    private var outputData = Data()
    private var errorData = Data()
    private var outputWasTruncated = false
    private var errorOutputWasTruncated = false
    private var launchInProgress = false
    private var launched = false
    private var finished = false
    private var stopReason: StopReason?
    private var timeoutTask: Task<Void, Never>?
    private var forceKillTask: Task<Void, Never>?

    init(
        executableURL: URL,
        arguments: [String],
        captureOutput: Bool,
        timeoutNanoseconds: UInt64,
        maximumCapturedBytes: Int
    ) {
        process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        standardOutputPipe = captureOutput ? Pipe() : nil
        process.standardOutput = standardOutputPipe ?? FileHandle.nullDevice
        process.standardError = standardErrorPipe
        self.timeoutNanoseconds = timeoutNanoseconds
        self.maximumCapturedBytes = maximumCapturedBytes
    }

    func start(continuation: CheckedContinuation<BetterDisplayExecutionResult, Never>) {
        lock.lock()
        if let completedResult {
            lock.unlock()
            continuation.resume(returning: completedResult)
            return
        }

        self.continuation = continuation
        launchInProgress = true
        let shouldSkipLaunch = stopReason != nil
        lock.unlock()

        if shouldSkipLaunch {
            finish(status: .cancelled)
            return
        }

        installReadabilityHandlers()
        process.terminationHandler = { [weak self] terminatedProcess in
            self?.processDidTerminate(terminatedProcess)
        }

        do {
            try process.run()
        } catch {
            lock.lock()
            launchInProgress = false
            lock.unlock()
            finish(status: .launchFailed(error.localizedDescription))
            return
        }

        lock.lock()
        launchInProgress = false
        guard !finished else {
            lock.unlock()
            return
        }
        launched = true
        let pendingStopReason = stopReason
        lock.unlock()

        if let pendingStopReason {
            terminateProcess(for: pendingStopReason)
        } else {
            scheduleTimeout()
        }
    }

    func cancel() {
        requestStop(.cancelled)
    }

    private func requestStop(_ reason: StopReason) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }

        if stopReason == nil {
            stopReason = reason
        }

        let currentReason = stopReason ?? reason
        let isLaunching = launchInProgress
        let hasLaunched = launched
        lock.unlock()

        if isLaunching {
            return
        }

        if hasLaunched {
            terminateProcess(for: currentReason)
        } else {
            finish(status: currentReason.status)
        }
    }

    private func terminateProcess(for reason: StopReason) {
        guard process.isRunning else {
            finish(status: reason.status)
            return
        }

        let processIdentifier = process.processIdentifier
        _ = kill(processIdentifier, SIGTERM)
        scheduleForceKill(processIdentifier: processIdentifier)
    }

    private func scheduleTimeout() {
        guard timeoutNanoseconds > 0 else { return }

        let timeoutNanoseconds = timeoutNanoseconds
        let task = Task<Void, Never> { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            self?.requestStop(.timedOut)
        }

        lock.lock()
        if finished || stopReason != nil {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    private func scheduleForceKill(processIdentifier: pid_t) {
        let task = Task<Void, Never> { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            self?.forceKillIfNeeded(processIdentifier: processIdentifier)
        }

        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
            return
        }
        forceKillTask?.cancel()
        forceKillTask = task
        lock.unlock()
    }

    private func forceKillIfNeeded(processIdentifier: pid_t) {
        lock.lock()
        let shouldKill = !finished && stopReason != nil && launched
        lock.unlock()

        guard shouldKill, process.isRunning else { return }
        _ = kill(processIdentifier, SIGKILL)
    }

    private func installReadabilityHandlers() {
        standardOutputPipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.append(data, to: .standardOutput)
        }

        standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.append(data, to: .standardError)
        }
    }

    private func processDidTerminate(_ terminatedProcess: Process) {
        standardOutputPipe?.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil

        if let standardOutputPipe {
            append(standardOutputPipe.fileHandleForReading.readDataToEndOfFile(), to: .standardOutput)
        }
        append(standardErrorPipe.fileHandleForReading.readDataToEndOfFile(), to: .standardError)

        lock.lock()
        let stopReason = stopReason
        lock.unlock()

        if let stopReason {
            finish(status: stopReason.status)
        } else if terminatedProcess.terminationStatus == 0 {
            finish(status: .succeeded)
        } else {
            finish(status: .nonZeroExit(terminatedProcess.terminationStatus))
        }
    }

    private func append(_ data: Data, to stream: Stream) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        switch stream {
        case .standardOutput:
            appendBounded(data, to: &outputData, wasTruncated: &outputWasTruncated)
        case .standardError:
            appendBounded(data, to: &errorData, wasTruncated: &errorOutputWasTruncated)
        }
    }

    private func appendBounded(_ data: Data, to buffer: inout Data, wasTruncated: inout Bool) {
        let remainingCapacity = max(0, maximumCapturedBytes - buffer.count)
        if remainingCapacity > 0 {
            buffer.append(contentsOf: data.prefix(remainingCapacity))
        }
        if data.count > remainingCapacity {
            wasTruncated = true
        }
    }

    private func finish(status: BetterDisplayExecutionStatus) {
        standardOutputPipe?.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }

        finished = true
        timeoutTask?.cancel()
        forceKillTask?.cancel()
        timeoutTask = nil
        forceKillTask = nil

        let result = BetterDisplayExecutionResult(
            status: status,
            output: String(decoding: outputData, as: UTF8.self),
            errorOutput: String(decoding: errorData, as: UTF8.self),
            outputWasTruncated: outputWasTruncated,
            errorOutputWasTruncated: errorOutputWasTruncated
        )
        completedResult = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: result)
    }
}
