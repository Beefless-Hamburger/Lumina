#if LUMINA_BACKEND_TESTS
import Foundation

private func successfulExecution(output: String = "") -> BetterDisplayExecutionResult {
    BetterDisplayExecutionResult(
        status: .succeeded,
        output: output,
        errorOutput: "",
        outputWasTruncated: false,
        errorOutputWasTruncated: false
    )
}

actor ManualGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            resumeSatisfiedCountWaiters()
        }
    }

    func waitForWaiterCount(_ count: Int) async {
        if waiters.count >= count {
            return
        }

        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func resumeSatisfiedCountWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if waiters.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
    }
}

actor MockDisplayTransport: BetterDisplayTransport {
    enum Event: Equatable, CustomStringConvertible {
        case ensure(String)
        case run([String], Bool)

        var description: String {
            switch self {
            case let .ensure(context):
                return "ensure(\(context))"
            case let .run(arguments, captureOutput):
                return "run(\(arguments.joined(separator: " ")), captureOutput: \(captureOutput))"
            }
        }
    }

    private(set) var events: [Event] = []
    private var availability: BetterDisplayAvailability = .running
    private var refreshOutput = ""
    private var resultsByCommand: [String: BetterDisplayExecutionResult] = [:]
    private var gatesByCommand: [String: ManualGate] = [:]

    func setAvailability(_ availability: BetterDisplayAvailability) {
        self.availability = availability
    }

    func setRefreshOutput(_ output: String) {
        refreshOutput = output
    }

    func setResult(_ result: BetterDisplayExecutionResult, for arguments: [String]) {
        resultsByCommand[commandKey(arguments)] = result
    }

    func block(arguments: [String], on gate: ManualGate) {
        gatesByCommand[commandKey(arguments)] = gate
    }

    func ensureRunning(context: String) async -> BetterDisplayAvailability {
        events.append(.ensure(context))
        return availability
    }

    func run(arguments: [String], context: String, captureOutput: Bool) async -> BetterDisplayExecutionResult {
        events.append(.run(arguments, captureOutput))

        if let gate = gatesByCommand[commandKey(arguments)] {
            await gate.wait()
        }

        if Task.isCancelled {
            return .failure(.cancelled)
        }

        if arguments == ["get", "-identifiers"] {
            return successfulExecution(output: refreshOutput)
        }

        return resultsByCommand[commandKey(arguments)] ?? successfulExecution()
    }

    private func commandKey(_ arguments: [String]) -> String {
        arguments.joined(separator: "\u{1F}")
    }
}

actor ManualSleeper: DisplaySleeper {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var sleepCount = 0

    func sleep(nanoseconds: UInt64) async throws {
        sleepCount += 1
        resumeSatisfiedCountWaiters()
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitForSleepCount(_ count: Int) async {
        if sleepCount >= count {
            return
        }

        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func resumeSatisfiedCountWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if sleepCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
    }
}

struct ImmediateSleeper: DisplaySleeper {
    func sleep(nanoseconds: UInt64) async throws {}
}

private final class MockHeartbeatToken: HeartbeatTimerToken {
    private(set) var isInvalidated = false

    func invalidate() {
        isInvalidated = true
    }
}

@MainActor
private final class MockHeartbeatScheduler: HeartbeatScheduling {
    private(set) var scheduleCount = 0
    private(set) var tokens: [MockHeartbeatToken] = []
    private var handlers: [@MainActor @Sendable () -> Void] = []

    func schedule(
        interval: TimeInterval,
        tolerance: TimeInterval,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> any HeartbeatTimerToken {
        scheduleCount += 1
        let token = MockHeartbeatToken()
        tokens.append(token)
        handlers.append(handler)
        return token
    }

    func fireLatest() {
        guard let token = tokens.last, !token.isInvalidated, let handler = handlers.last else { return }
        handler()
    }
}

@MainActor
private final class HeartbeatProbe {
    var fireCount = 0
}

@main
struct LuminaBackendTests {
    static func main() async {
        await testRefreshParsing()
        await testPowerOnSequence()
        await testHDRBrightnessRecovery()
        await testHDRBrightnessPartialFailure()
        await testHDRBrightnessQualificationStates()
        await testHDRBrightnessFailureRecovery()
        await testHDRBrightnessCancellation()
        await testRepeatedHDRBrightnessCycles()
        await testPowerOffSequence()
        await testEmptyTargets()
        await testLaunchFailure()
        await testPartialCommandFailure()
        await testTerminalCommandFailure()
        await testStalePowerOnSupersededByPowerOff()
        await testStalePowerOffSupersededByPowerOn()
        await testHeartbeatLifecycle()
        await testAsyncProcessRunner()
        print("Lumina backend tests passed.")
    }

    private static func testRefreshParsing() async {
        let transport = MockDisplayTransport()
        await transport.setRefreshOutput("""
        {"UUID":"uuid-beta","name":"Display Beta"}
        {"name":"Default Group"}
        {"UUID":"uuid-alpha","name":"Display Alpha"}
        """)

        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())
        let targets = await backend.refreshDisplayTargets()
        expect(targets.map(\.name) == ["Display Alpha", "Display Beta"], "refresh parsing and sorting")

        let events = await transport.events
        expect(events.count == 2, "refresh should launch BetterDisplay and request identifiers")
        expect(events[0] == .ensure("refresh displays"), "refresh should ensure the backend is running")
        expect(events[1] == .run(["get", "-identifiers"], true), "refresh should query identifiers")
    }

    private static func testPowerOnSequence() async {
        let transport = MockDisplayTransport()
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        let result = await backend.powerOn(targets: ["Display Alpha", "Display Beta", "Display Alpha"])

        expect(result == DisplayOperationResult(status: .succeeded, attemptedCommandCount: 10, failedCommandCount: 0), "power-on should report successful command counts")
        let events = await transport.events
        expect(events.count == 11, "power-on should issue all launch and display commands")
        expect(events[0] == .ensure("power on"), "power-on should ensure BetterDisplay is running")
        expect(events[1] == .run(["set", "-UUID=Display Alpha", "-connected=on"], false), "power-on should connect the first display")
        expect(events[2] == .run(["set", "-UUID=Display Alpha", "-ddc", "-vcp=powerMode", "-value=1"], false), "power-on should send DDC on for the first display")
        expect(events[3] == .run(["set", "-UUID=Display Beta", "-connected=on"], false), "power-on should connect the second display")
        expect(events[5] == .run(["perform", "-UUID=Display Alpha", "-reinitialize"], false), "power-on should reinitialize the first display")
        expect(events[10] == .run(["set", "-UUID=Display Beta", "-ddc", "-vcp=powerMode", "-value=1"], false), "power-on should finish DDC on for the second display")
    }

    private static func testHDRBrightnessRecovery() async {
        let transport = MockDisplayTransport()
        for target in ["Display Alpha", "Display Beta"] {
            await transport.setResult(
                successfulExecution(output: "on\n"),
                for: ["get", "-UUID=\(target)", "-hdr", "-value"]
            )
        }
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        let result = await backend.powerOn(
            targets: ["Display Alpha", "Display Beta"],
            restoreHDRBrightness: true
        )

        expect(result == DisplayOperationResult(status: .succeeded, attemptedCommandCount: 12, failedCommandCount: 0), "enabled HDR recovery should add one brightness command per qualified display")
        let events = await transport.events
        for target in ["Display Alpha", "Display Beta"] {
            let hdr = MockDisplayTransport.Event.run(["get", "-UUID=\(target)", "-hdr", "-value"], true)
            let brightness = MockDisplayTransport.Event.run(["set", "-UUID=\(target)", "-brightness=1.0"], false)
            guard let hdrIndex = events.firstIndex(of: hdr), let brightnessIndex = events.firstIndex(of: brightness) else {
                expect(false, "HDR qualification and brightness commands should both run")
                return
            }
            expect(hdrIndex < brightnessIndex, "brightness must follow HDR qualification")
            expect(events[..<hdrIndex].contains(.run(["set", "-UUID=\(target)", "-hardwareBacklight=on"], false)), "brightness must follow hardware backlight recovery")
            expect(events[..<hdrIndex].contains(.run(["set", "-UUID=\(target)", "-ddc", "-vcp=powerMode", "-value=1"], false)), "brightness must follow final DDC power-on")
        }
    }

    private static func testHDRBrightnessPartialFailure() async {
        let transport = MockDisplayTransport()
        await transport.setResult(.failure(.nonZeroExit(7)), for: ["set", "-UUID=Display Alpha", "-connected=on"])
        await transport.setResult(successfulExecution(output: "on"), for: ["get", "-UUID=Display Beta", "-hdr", "-value"])
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        _ = await backend.powerOn(targets: ["Display Alpha", "Display Beta"], restoreHDRBrightness: true)
        let events = await transport.events
        expect(!events.contains(.run(["set", "-UUID=Display Alpha", "-brightness=1.0"], false)), "failed reconnect must not receive brightness recovery")
        expect(events.contains(.run(["set", "-UUID=Display Beta", "-brightness=1.0"], false)), "successfully reconnected display should receive brightness recovery")
    }

    private static func testHDRBrightnessQualificationStates() async {
        let transport = MockDisplayTransport()
        await transport.setResult(successfulExecution(output: "off"), for: ["get", "-UUID=SDR", "-hdr", "-value"])
        await transport.setResult(successfulExecution(output: "unexpected"), for: ["get", "-UUID=Malformed", "-hdr", "-value"])
        await transport.setResult(.failure(.timedOut), for: ["get", "-UUID=Unavailable", "-hdr", "-value"])
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        _ = await backend.powerOn(targets: ["SDR", "Malformed", "Unavailable"], restoreHDRBrightness: true)
        let events = await transport.events
        for target in ["SDR", "Malformed", "Unavailable"] {
            expect(!events.contains(.run(["set", "-UUID=\(target)", "-brightness=1.0"], false)), "Non-HDR or unavailable state must not trigger brightness recovery")
        }
    }

    private static func testHDRBrightnessFailureRecovery() async {
        let transport = MockDisplayTransport()
        let hdr = ["get", "-UUID=Display Alpha", "-hdr", "-value"]
        let brightness = ["set", "-UUID=Display Alpha", "-brightness=1.0"]
        await transport.setResult(successfulExecution(output: "on"), for: hdr)
        await transport.setResult(successfulExecution(output: "on"), for: ["get", "-UUID=Display Beta", "-hdr", "-value"])
        await transport.setResult(.failure(.nonZeroExit(8)), for: brightness)
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        let failedResult = await backend.powerOn(targets: ["Display Alpha", "Display Beta"], restoreHDRBrightness: true)
        expect(failedResult.status == .failed, "brightness failure should be reported")
        let failedEvents = await transport.events
        expect(failedEvents.contains(.run(["set", "-UUID=Display Beta", "-brightness=1.0"], false)), "one brightness failure must not prevent unaffected displays")
        await transport.setResult(successfulExecution(), for: brightness)
        let laterResult = await backend.powerOn(targets: ["Display Alpha"], restoreHDRBrightness: true)
        expect(laterResult.status == .succeeded, "brightness failure must not wedge a later power sequence")
    }

    private static func testHDRBrightnessCancellation() async {
        let transport = MockDisplayTransport()
        let gate = ManualGate()
        let finalPower = ["set", "-UUID=Display Alpha", "-ddc", "-vcp=powerMode", "-value=1"]
        await transport.block(arguments: finalPower, on: gate)
        await transport.setResult(successfulExecution(output: "on"), for: ["get", "-UUID=Display Alpha", "-hdr", "-value"])
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        let wakeTask = Task { await backend.powerOn(targets: ["Display Alpha"], restoreHDRBrightness: true) }
        await gate.waitForWaiterCount(1)
        let lockResult = await backend.powerOff(targets: ["Display Alpha"])
        await gate.resumeAll()
        let wakeResult = await wakeTask.value

        expect(lockResult.status == .succeeded, "newer lock operation should complete")
        expect(wakeResult.status == .superseded, "wake should be superseded before brightness recovery")
        let events = await transport.events
        expect(!events.contains(.run(["set", "-UUID=Display Alpha", "-brightness=1.0"], false)), "superseded wake must not restore brightness")
    }

    private static func testRepeatedHDRBrightnessCycles() async {
        let transport = MockDisplayTransport()
        await transport.setResult(successfulExecution(output: "on"), for: ["get", "-UUID=Display Alpha", "-hdr", "-value"])
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        for cycle in 1...10 {
            let offResult = await backend.powerOff(targets: ["Display Alpha"])
            let onResult = await backend.powerOn(targets: ["Display Alpha"], restoreHDRBrightness: true)
            expect(offResult.status == .succeeded, "Cycle \(cycle) power-off should succeed")
            expect(onResult.status == .succeeded, "Cycle \(cycle) HDR recovery should succeed")
        }
        let events = await transport.events
        let brightnessCount = events.filter { $0 == .run(["set", "-UUID=Display Alpha", "-brightness=1.0"], false) }.count
        expect(brightnessCount == 10, "Every repeated wake cycle should restore HDR brightness once")
    }

    private static func testPowerOffSequence() async {
        let transport = MockDisplayTransport()
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        let result = await backend.powerOff(targets: ["Display Alpha", "Display Beta"])
        expect(result == DisplayOperationResult(status: .succeeded, attemptedCommandCount: 4, failedCommandCount: 0), "power-off should report successful command counts")

        let events = await transport.events
        expect(events == [
            .ensure("power off"),
            .run(["set", "-UUID=Display Alpha", "-connected=off"], false),
            .run(["set", "-UUID=Display Alpha", "-ddc", "-vcp=powerMode", "-value=4"], false),
            .run(["set", "-UUID=Display Beta", "-connected=off"], false),
            .run(["set", "-UUID=Display Beta", "-ddc", "-vcp=powerMode", "-value=4"], false)
        ], "power-off should remain deterministic across displays")
    }

    private static func testEmptyTargets() async {
        let transport = MockDisplayTransport()
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        let onResult = await backend.powerOn(targets: [])
        let offResult = await backend.powerOff(targets: ["", ""])
        expect(onResult == .noTargets, "empty power-on targets should be skipped")
        expect(offResult == .noTargets, "empty power-off targets should be skipped")
        let events = await transport.events
        expect(events.isEmpty, "empty targets should not launch BetterDisplay or issue commands")
    }

    private static func testLaunchFailure() async {
        let transport = MockDisplayTransport()
        await transport.setAvailability(.launchFailed("test launch failure"))
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        let result = await backend.powerOn(targets: ["Display Alpha"])
        expect(result.status == .betterDisplayUnavailable(.launchFailed("test launch failure")), "launch failures should be reported distinctly")
        expect(result.attemptedCommandCount == 0, "launch failure should not issue commands")
    }

    private static func testPartialCommandFailure() async {
        let transport = MockDisplayTransport()
        let failedConnect = ["set", "-UUID=Display Alpha", "-connected=on"]
        await transport.setResult(.failure(.nonZeroExit(7)), for: failedConnect)
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        let result = await backend.powerOn(targets: ["Display Alpha", "Display Beta"])
        expect(result.status == .failed, "a partial multi-display failure should be reported")
        expect(result.failedCommandCount == 1, "partial failure should count the failed command")

        let events = await transport.events
        expect(!events.contains(.run(["perform", "-UUID=Display Alpha", "-reinitialize"], false)), "a display that failed to connect should not receive later wake stages")
        expect(events.contains(.run(["perform", "-UUID=Display Beta", "-reinitialize"], false)), "other displays should continue after a recoverable per-display failure")
    }

    private static func testTerminalCommandFailure() async {
        let transport = MockDisplayTransport()
        let firstCommand = ["set", "-UUID=Display Alpha", "-connected=on"]
        await transport.setResult(.failure(.timedOut), for: firstCommand)
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        let result = await backend.powerOn(targets: ["Display Alpha", "Display Beta"])
        expect(result == DisplayOperationResult(status: .failed, attemptedCommandCount: 1, failedCommandCount: 1), "timeout should terminate the sequence immediately")

        let events = await transport.events
        expect(events.count == 2, "terminal command failure should prevent later commands")
    }

    private static func testStalePowerOnSupersededByPowerOff() async {
        let transport = MockDisplayTransport()
        let sleeper = ManualSleeper()
        let backend = BetterDisplayService(transport: transport, sleeper: sleeper)

        let powerOnTask = Task {
            await backend.powerOn(targets: ["Display Alpha"])
        }

        await sleeper.waitForSleepCount(1)
        let powerOffResult = await backend.powerOff(targets: ["Display Alpha"])
        await sleeper.resumeAll()
        let powerOnResult = await powerOnTask.value

        expect(powerOffResult.status == .succeeded, "newer power-off should complete")
        expect(powerOnResult.status == .superseded, "older staged power-on should be superseded")

        let events = await transport.events
        expect(!events.contains(.run(["perform", "-UUID=Display Alpha", "-reinitialize"], false)), "superseded power-on should suppress stale reinitialize")
        expect(!events.contains(.run(["set", "-UUID=Display Alpha", "-hardwareBacklight=on"], false)), "superseded power-on should suppress stale backlight recovery")
    }

    private static func testStalePowerOffSupersededByPowerOn() async {
        let transport = MockDisplayTransport()
        let gate = ManualGate()
        let firstOffCommand = ["set", "-UUID=Display Alpha", "-connected=off"]
        await transport.block(arguments: firstOffCommand, on: gate)
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        let powerOffTask = Task {
            await backend.powerOff(targets: ["Display Alpha"])
        }

        await gate.waitForWaiterCount(1)
        let powerOnResult = await backend.powerOn(targets: ["Display Alpha"])
        await gate.resumeAll()
        let powerOffResult = await powerOffTask.value

        expect(powerOnResult.status == .succeeded, "newer power-on should complete")
        expect(powerOffResult.status == .superseded, "older power-off should be superseded")

        let events = await transport.events
        expect(!events.contains(.run(["set", "-UUID=Display Alpha", "-ddc", "-vcp=powerMode", "-value=4"], false)), "superseded power-off should not send its later DDC command")
    }

    private static func testHeartbeatLifecycle() async {
        await MainActor.run {
            let scheduler = MockHeartbeatScheduler()
            let controller = ShutdownHeartbeatController(scheduler: scheduler, interval: 10, tolerance: 1)
            let probe = HeartbeatProbe()

            controller.start {
                probe.fireCount += 1
            }
            controller.start {
                probe.fireCount += 100
            }
            expect(controller.isRunning, "heartbeat should report running after start")
            expect(scheduler.scheduleCount == 1, "heartbeat should create only one timer")

            scheduler.fireLatest()
            scheduler.fireLatest()
            expect(probe.fireCount == 2, "heartbeat should repeat through the installed handler")

            controller.stop()
            expect(!controller.isRunning, "heartbeat should stop cleanly")
            scheduler.fireLatest()
            expect(probe.fireCount == 2, "invalidated heartbeat should not fire")

            controller.start {
                probe.fireCount += 1
            }
            expect(scheduler.scheduleCount == 2, "heartbeat should be restartable after cleanup")
            controller.stop()
        }
    }

    private static func testAsyncProcessRunner() async {
        let runner = AsyncProcessRunner(timeoutNanoseconds: 2_000_000_000, maximumCapturedBytes: 4_096)

        let outputResult = await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["hello"],
            captureOutput: true
        )
        expect(outputResult.status == .succeeded, "process runner should report successful execution")
        expect(outputResult.output == "hello", "process runner should capture stdout")

        let failureResult = await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            captureOutput: true
        )
        expect(failureResult.status == .nonZeroExit(1), "process runner should report a nonzero exit")

        let timeoutRunner = AsyncProcessRunner(timeoutNanoseconds: 100_000_000, maximumCapturedBytes: 4_096)
        let timeoutResult = await timeoutRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            captureOutput: true
        )
        expect(timeoutResult.status == .timedOut, "process runner should terminate timed-out processes")

        let boundedOutputResult = await timeoutRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            captureOutput: true
        )
        expect(boundedOutputResult.status == .timedOut, "unbounded output process should be timed out")
        expect(boundedOutputResult.output.utf8.count <= 4_096, "captured output should remain bounded")
        expect(boundedOutputResult.outputWasTruncated, "bounded output should report truncation")

        let cancellationTask = Task {
            await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                captureOutput: true
            )
        }
        cancellationTask.cancel()
        let cancellationResult = await cancellationTask.value
        expect(cancellationResult.status == .cancelled, "process runner should report cancellation distinctly")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("Lumina backend test failed: \(message)")
            exit(1)
        }
    }
}
#endif
