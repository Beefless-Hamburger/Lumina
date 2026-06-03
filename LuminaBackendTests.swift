#if LUMINA_BACKEND_TESTS
import Foundation

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
    var running = false
    var launchSucceeds = true
    var refreshOutput = ""
    var commandDelayNanoseconds: UInt64 = 0
    private var delayedSleeper: ManualSleeper?

    func attachDelayedSleeper(_ sleeper: ManualSleeper) {
        delayedSleeper = sleeper
    }

    func setRefreshOutput(_ output: String) {
        refreshOutput = output
    }

    func ensureRunning(context: String) async -> Bool {
        events.append(.ensure(context))
        guard launchSucceeds else { return false }
        running = true
        return true
    }

    func run(arguments: [String], context: String, captureOutput: Bool) async -> BetterDisplayExecutionResult? {
        events.append(.run(arguments, captureOutput))

        if commandDelayNanoseconds > 0 {
            if let delayedSleeper {
                try? await delayedSleeper.sleep(nanoseconds: commandDelayNanoseconds)
            } else {
                try? await Task.sleep(nanoseconds: commandDelayNanoseconds)
            }
        }

        if arguments == ["get", "-identifiers"] {
            return BetterDisplayExecutionResult(output: refreshOutput, errorOutput: "", exitCode: 0)
        }

        return BetterDisplayExecutionResult(output: "", errorOutput: "", exitCode: 0)
    }
}

actor ManualSleeper: DisplaySleeper {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sleepCount = 0

    func sleep(nanoseconds: UInt64) async throws {
        sleepCount += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        let continuation = waiters.removeFirst()
        continuation.resume()
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

struct ImmediateSleeper: DisplaySleeper {
    func sleep(nanoseconds: UInt64) async throws {}
}

@main
struct LuminaBackendTests {
    static func main() async {
        await testRefreshParsing()
        await testPowerOnSequence()
        await testStaleSequenceCancellation()
        print("Lumina backend tests passed.")
    }

    private static func testRefreshParsing() async {
        let transport = MockDisplayTransport()
        await transport.setRefreshOutput("""
        {"name":"Display Beta"}
        {"name":"Default Group"}
        {"name":"Display Alpha"}
        """)

        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())
        let names = await backend.refreshDisplayNames()
        expect(names == ["Display Alpha", "Display Beta"], "refresh parsing and sorting")

        let events = await transport.events
        expect(events.count == 2, "refresh should launch BetterDisplay and request identifiers")
        expect(events[0] == .ensure("refresh displays"), "refresh should ensure the backend is running")
        expect(events[1] == .run(["get", "-identifiers"], true), "refresh should query identifiers")
    }

    private static func testPowerOnSequence() async {
        let transport = MockDisplayTransport()
        let backend = BetterDisplayService(transport: transport, sleeper: ImmediateSleeper())

        await backend.powerOn(targets: ["Display Alpha", "Display Beta"])

        let events = await transport.events
        expect(events.count == 11, "power-on should issue all launch and display commands")
        expect(events[0] == .ensure("power on"), "power-on should ensure BetterDisplay is running")
        expect(events[1] == .run(["set", "-name=Display Alpha", "-connected=on"], false), "power-on should connect the first display")
        expect(events[2] == .run(["set", "-name=Display Alpha", "-ddc", "-vcp=powerMode", "-value=1"], false), "power-on should send DDC on for the first display")
        expect(events[3] == .run(["set", "-name=Display Beta", "-connected=on"], false), "power-on should connect the second display")
        expect(events[4] == .run(["set", "-name=Display Beta", "-ddc", "-vcp=powerMode", "-value=1"], false), "power-on should send DDC on for the second display")
        expect(events[5] == .run(["perform", "-name=Display Alpha", "-reinitialize"], false), "power-on should reinitialize the first display")
        expect(events[6] == .run(["perform", "-name=Display Beta", "-reinitialize"], false), "power-on should reinitialize the second display")
        expect(events[7] == .run(["set", "-name=Display Alpha", "-hardwareBacklight=on"], false), "power-on should recover the first backlight")
        expect(events[8] == .run(["set", "-name=Display Alpha", "-ddc", "-vcp=powerMode", "-value=1"], false), "power-on should finish DDC on for the first display")
        expect(events[9] == .run(["set", "-name=Display Beta", "-hardwareBacklight=on"], false), "power-on should recover the second backlight")
        expect(events[10] == .run(["set", "-name=Display Beta", "-ddc", "-vcp=powerMode", "-value=1"], false), "power-on should finish DDC on for the second display")
    }

    private static func testStaleSequenceCancellation() async {
        let transport = MockDisplayTransport()
        let sleeper = ManualSleeper()
        await transport.attachDelayedSleeper(sleeper)
        let backend = BetterDisplayService(transport: transport, sleeper: sleeper)

        let powerOnTask = Task {
            await backend.powerOn(targets: ["Display Alpha"])
        }

        await waitUntil {
            let events = await transport.events
            return events.contains(.run(["set", "-name=Display Alpha", "-connected=on"], false))
        }

        await backend.powerOff(targets: ["Display Alpha"])
        await sleeper.resumeAll()
        _ = await powerOnTask.value

        let events = await transport.events
        expect(events.contains(.ensure("power on")), "stale-sequence test should start power-on")
        expect(events.contains(.ensure("power off")), "stale-sequence test should start power-off")
        expect(events.contains(.run(["set", "-name=Display Alpha", "-connected=on"], false)), "stale-sequence test should record the initial on pulse")
        expect(!events.contains(.run(["perform", "-name=Display Alpha", "-reinitialize"], false)), "stale-sequence test should suppress stale reinitialize")
        expect(!events.contains(.run(["set", "-name=Display Alpha", "-hardwareBacklight=on"], false)), "stale-sequence test should suppress stale backlight recovery")
    }

    private static func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<100 {
            if await predicate() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Lumina backend test failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
#endif
