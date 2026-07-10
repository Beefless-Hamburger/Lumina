#if LUMINA_LOGIC_TESTS
import Foundation

@main
struct LuminaLogicTests {
    static func main() {
        testStatusTitle()
        testTargetResolution()
        testLifecycleState()
        testLifecycleCoordinatorRepeatedCycles()
        testLifecycleCoordinatorReconciliation()
        testLifecycleCoordinatorOverlapAndDuplicates()
        testDisplayParsing()
        testMalformedAndLargeDisplayPayloads()
        print("Lumina logic tests passed.")
    }

    private static func testStatusTitle() {
        expect(statusTitle(targetAllDisplays: true, targetDisplay: "Display Alpha", availableDisplays: ["Display Alpha"]) == "Targeting: All Displays", "All-displays status title")
        expect(statusTitle(targetAllDisplays: false, targetDisplay: "", availableDisplays: []) == "No Display Selected", "Empty target status title")
        expect(statusTitle(targetAllDisplays: false, targetDisplay: "Display Alpha", availableDisplays: ["Display Alpha"]) == "Target: Display Alpha", "Resolved target status title")
        expect(statusTitle(targetAllDisplays: false, targetDisplay: "Display Alpha", availableDisplays: ["Display Beta"]) == "Target Unavailable: Display Alpha", "Unavailable target status title")
    }

    private static func testTargetResolution() {
        expect(resolvedTargets(targetAllDisplays: true, targetDisplay: "Display Alpha", availableDisplays: ["Display Alpha", "Display Beta"]) == ["Display Alpha", "Display Beta"], "All displays resolution")
        expect(resolvedTargets(targetAllDisplays: true, targetDisplay: "", availableDisplays: ["Display Alpha", "", "Display Alpha"]) == ["Display Alpha"], "All displays resolution should remove empty and duplicate targets")
        expect(resolvedTargets(targetAllDisplays: false, targetDisplay: "Display Alpha", availableDisplays: ["Display Alpha", "Display Beta"]) == ["Display Alpha"], "Single target resolution")
        expect(resolvedTargets(targetAllDisplays: false, targetDisplay: "", availableDisplays: ["Display Alpha"]) == [], "Empty target resolution")
        expect(resolvedTargets(targetAllDisplays: false, targetDisplay: "Missing", availableDisplays: ["Display Alpha"]) == [], "Unavailable target resolution")
    }

    private static func testLifecycleState() {
        var state = DisplayLifecycleState()
        expect(!state.isInactive, "Lifecycle should start active")
        expect(state.apply(.screenLocked) == .becameInactive, "Lock should enter inactive state")
        expect(state.apply(.screenLocked) == .unchanged, "Duplicate lock should be ignored")
        expect(state.apply(.systemWillSleep) == .unchanged, "Sleep while locked should remain inactive")
        expect(state.apply(.systemDidWake) == .unchanged, "Wake while still locked should remain inactive")
        expect(state.isInactive, "Wake must not override an outstanding lock")
        expect(state.apply(.screenUnlocked) == .becameActive, "Unlock after wake should return active")
        expect(state.apply(.screenUnlocked) == .unchanged, "Duplicate unlock should be ignored")

        expect(state.apply(.systemWillSleep) == .becameInactive, "Sleep should enter inactive state")
        expect(state.apply(.screenLocked) == .unchanged, "Lock while asleep should remain inactive")
        expect(state.apply(.screenUnlocked) == .unchanged, "Unlock while asleep should remain inactive")
        expect(state.apply(.systemDidWake) == .becameActive, "Wake after unlock should return active")

        expect(state.apply(.screenLocked) == .becameInactive, "Rapid lock should enter inactive state")
        expect(state.apply(.screenUnlocked) == .becameActive, "Rapid unlock should return active")
        expect(state.apply(.screenLocked) == .becameInactive, "Second rapid lock should enter inactive state")
    }

    private static func testLifecycleCoordinatorRepeatedCycles() {
        var coordinator = DisplayLifecycleCoordinator()

        for cycle in 1...10 {
            let lock = coordinator.receive(.screenLocked, sessionScreenIsLocked: true)
            expect(lock.action == .powerOff, "Cycle \(cycle) lock should request immediate power-off")
            expect(lock.transition == .becameInactive, "Cycle \(cycle) lock should become inactive")

            let unlock = coordinator.receive(.screenUnlocked, sessionScreenIsLocked: false)
            expect(unlock.action == .powerOn, "Cycle \(cycle) unlock should request power-on")
            expect(unlock.transition == .becameActive, "Cycle \(cycle) unlock should become active")
        }
    }

    private static func testLifecycleCoordinatorReconciliation() {
        var coordinator = DisplayLifecycleCoordinator()
        let lock = coordinator.receive(.screenLocked, sessionScreenIsLocked: true)
        expect(lock.action == .powerOff, "Initial lock should request power-off")

        let staleUnlock = coordinator.receive(
            .screenUnlocked,
            sessionScreenIsLocked: true,
            finalReconciliationAttempt: false
        )
        expect(staleUnlock.disposition == .delayed, "Stale unlock evidence should delay reconciliation")
        expect(coordinator.state.isScreenLocked, "Delayed unlock must not mutate lifecycle state")

        let reconciledUnlock = coordinator.receive(.screenUnlocked, sessionScreenIsLocked: false)
        expect(reconciledUnlock.action == .powerOn, "Reconciled unlock should request power-on")
        expect(!coordinator.state.isScreenLocked, "Reconciled unlock should clear the lock state")

        let staleLock = coordinator.receive(
            .screenLocked,
            sessionScreenIsLocked: false,
            finalReconciliationAttempt: false
        )
        expect(staleLock.disposition == .delayed, "Stale lock evidence should delay reconciliation")
        expect(!coordinator.state.isScreenLocked, "Delayed lock must not mutate lifecycle state")

        let reconciledLock = coordinator.receive(.screenLocked, sessionScreenIsLocked: true)
        expect(reconciledLock.action == .powerOff, "Reconciled lock should request immediate power-off")

        let unavailableSession = coordinator.receive(.screenUnlocked, sessionScreenIsLocked: nil)
        expect(unavailableSession.action == .powerOn, "Unavailable session evidence should not veto a notification")

        let staleDelayedNotification = coordinator.receive(
            .screenLocked,
            sessionScreenIsLocked: false,
            finalReconciliationAttempt: true
        )
        expect(staleDelayedNotification.disposition == .ignored, "A persistent mismatch should be ignored as stale")
        expect(!coordinator.state.isScreenLocked, "Ignored stale notification must not corrupt state")
    }

    private static func testLifecycleCoordinatorOverlapAndDuplicates() {
        var coordinator = DisplayLifecycleCoordinator()
        expect(coordinator.receive(.screenLocked, sessionScreenIsLocked: true).action == .powerOff, "Lock should power off")
        expect(coordinator.receive(.screenLocked, sessionScreenIsLocked: true).action == .none, "Duplicate lock should not issue another transition command")
        expect(coordinator.receive(.systemWillSleep).action == .none, "Sleep while locked should remain inactive")
        expect(coordinator.receive(.systemDidWake).action == .none, "Wake while locked must not power on")
        expect(coordinator.receive(.screenUnlocked, sessionScreenIsLocked: false).action == .powerOn, "Unlock after wake should power on")

        expect(coordinator.receive(.systemWillSleep).action == .powerOff, "Sleep should power off")
        expect(coordinator.receive(.screenLocked, sessionScreenIsLocked: true).action == .none, "Lock while asleep should not conflict")
        expect(coordinator.receive(.screenUnlocked, sessionScreenIsLocked: false).action == .none, "Unlock while asleep must not power on")
        expect(coordinator.receive(.systemDidWake).action == .powerOn, "Wake after unlock should power on")
        expect(coordinator.receive(.systemDidWake).action == .none, "Duplicate wake should not issue another command")
    }

    private static func testDisplayParsing() {
        let payload = """
        {"name":"Display Beta"}
        {"name":"Default Group"}
        {"name":"Display Alpha"}
        """
        expect(parseDisplayNames(from: payload) == ["Display Alpha", "Display Beta"], "Line-delimited display parsing")

        let wrappedPayload = """
        ,{
          "UUID" : "00000000-0000-0000-0000-000000000001",
          "deviceType" : "Display",
          "name" : "Display Gamma"
        },{
          "UUID" : "00000000-0000-0000-0000-000000000002",
          "deviceType" : "Display",
          "name" : "Display Delta"
        },{
          "deviceType" : "DisplayGroup",
          "name" : "Default Group"
        },
        """
        expect(parseDisplayNames(from: wrappedPayload) == ["Display Delta", "Display Gamma"], "Comma-delimited BetterDisplay payload parsing")

        let arrayPayload = """
        [{"name":"Zeta"},{"name":"Alpha"},{"name":"Default Group"}]
        """
        expect(parseDisplayNames(from: arrayPayload) == ["Alpha", "Zeta"], "Array display parsing")

        let singlePayload = """
        {"deviceType":"Display","name":"Studio Display"}
        """
        expect(parseDisplayNames(from: singlePayload) == ["Studio Display"], "Single-object display parsing")

        let noisyPayload = """
        [
          {"deviceType":"Display","name":"  Display Epsilon  "},
          {"deviceType":"Display","name":"Display Epsilon"},
          {"deviceType":"DisplayGroup","name":"Display Group"},
          {"deviceType":"Display","name":""},
          {"deviceType":"Audio","name":"Audio Device"},
          {"name":"Display Zeta"},
          {"deviceType":42,"name":"Wrong Type"},
          {"deviceType":"Display","name":42}
        ]
        """
        expect(parseDisplayNames(from: noisyPayload) == ["Display Epsilon", "Display Zeta"], "Display parsing should trim, deduplicate, and reject invalid device types")

        let unicodePayload = """
        {"deviceType":"Display","name":"Écran 東京"}
        {"deviceType":"Display","name":"alpha"}
        {"deviceType":"Display","name":"Alpha"}
        {"deviceType":"Display","name":"default group"}
        """
        expect(parseDisplayNames(from: unicodePayload) == ["Alpha", "alpha", "Écran 東京"], "Unicode parsing and deterministic case-insensitive sorting")
    }

    private static func testMalformedAndLargeDisplayPayloads() {
        let mixedPayload = """
        not-json
        {"deviceType":"Display","name":"Valid One"},
        {"deviceType":"Display","name":17},
        {malformed},
        {"deviceType":"Display","name":"Valid {Two}"}
        """
        expect(parseDisplayNames(from: mixedPayload) == ["Valid {Two}", "Valid One"], "Malformed records should not discard valid records")

        let largePayload = (0..<2_000)
            .map { index in
                "{\"deviceType\":\"Display\",\"name\":\"Display \(String(format: "%04d", index))\"}"
            }
            .joined(separator: "\n")
        let largeNames = parseDisplayNames(from: largePayload)
        expect(largeNames.count == 2_000, "Large payload should preserve every valid display")
        expect(largeNames.first == "Display 0000", "Large payload should sort deterministically at the beginning")
        expect(largeNames.last == "Display 1999", "Large payload should sort deterministically at the end")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            print("Lumina logic test failed: \(message)")
            exit(1)
        }
    }
}
#endif
