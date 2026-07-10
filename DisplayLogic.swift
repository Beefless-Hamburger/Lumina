import Foundation

struct DisplayTarget: Sendable, Equatable {
    let identifier: String
    let name: String
    let selectionLabel: String
}

private let restoreHDRBrightnessDefaultsKey = "RestoreHDRBrightnessAfterWake"

func loadRestoreHDRBrightnessPreference(from defaults: UserDefaults) -> Bool {
    defaults.bool(forKey: restoreHDRBrightnessDefaultsKey)
}

func saveRestoreHDRBrightnessPreference(_ enabled: Bool, to defaults: UserDefaults) {
    defaults.set(enabled, forKey: restoreHDRBrightnessDefaultsKey)
}

enum DisplayLifecycleEvent: Sendable, Equatable {
    case screenLocked
    case screenUnlocked
    case systemWillSleep
    case systemDidWake
}

enum DisplayLifecycleTransition: Sendable, Equatable {
    case becameInactive
    case becameActive
    case unchanged
}

enum ScreenNotificationDisposition: Sendable, Equatable {
    case accepted
    case delayed
    case ignored
}

enum DisplayLifecycleAction: Sendable, Equatable {
    case powerOff
    case powerOn
    case none
}

struct DisplayLifecycleOutcome: Sendable, Equatable {
    let disposition: ScreenNotificationDisposition
    let transition: DisplayLifecycleTransition?
    let action: DisplayLifecycleAction
    let stateBefore: DisplayLifecycleState
    let stateAfter: DisplayLifecycleState
}

struct DisplayLifecycleState: Sendable, Equatable {
    private(set) var isScreenLocked = false
    private(set) var isSystemAsleep = false

    var isInactive: Bool {
        isScreenLocked || isSystemAsleep
    }

    mutating func apply(_ event: DisplayLifecycleEvent) -> DisplayLifecycleTransition {
        let wasInactive = isInactive

        switch event {
        case .screenLocked:
            isScreenLocked = true
        case .screenUnlocked:
            isScreenLocked = false
        case .systemWillSleep:
            isSystemAsleep = true
        case .systemDidWake:
            isSystemAsleep = false
        }

        switch (wasInactive, isInactive) {
        case (false, true):
            return .becameInactive
        case (true, false):
            return .becameActive
        default:
            return .unchanged
        }
    }
}

struct DisplayLifecycleCoordinator: Sendable {
    private(set) var state = DisplayLifecycleState()

    mutating func receive(
        _ event: DisplayLifecycleEvent,
        sessionScreenIsLocked: Bool? = nil,
        finalReconciliationAttempt: Bool = true
    ) -> DisplayLifecycleOutcome {
        let stateBefore = state
        if let expectedLockState = event.expectedSessionLockState,
           let sessionScreenIsLocked,
           sessionScreenIsLocked != expectedLockState {
            return DisplayLifecycleOutcome(
                disposition: finalReconciliationAttempt ? .ignored : .delayed,
                transition: nil,
                action: .none,
                stateBefore: stateBefore,
                stateAfter: state
            )
        }

        let transition = state.apply(event)
        let action: DisplayLifecycleAction
        switch transition {
        case .becameInactive:
            action = .powerOff
        case .becameActive:
            action = .powerOn
        case .unchanged:
            action = .none
        }

        return DisplayLifecycleOutcome(
            disposition: .accepted,
            transition: transition,
            action: action,
            stateBefore: stateBefore,
            stateAfter: state
        )
    }
}

private extension DisplayLifecycleEvent {
    var expectedSessionLockState: Bool? {
        switch self {
        case .screenLocked:
            return true
        case .screenUnlocked:
            return false
        case .systemWillSleep, .systemDidWake:
            return nil
        }
    }
}

func statusTitle(targetAllDisplays: Bool, targetDisplay: String, availableDisplays: [String]) -> String {
    if targetAllDisplays {
        return "Targeting: All Displays"
    }

    if targetDisplay.isEmpty {
        return "No Display Selected"
    }

    if availableDisplays.contains(targetDisplay) {
        return "Target: \(targetDisplay)"
    }

    return "Target Unavailable: \(targetDisplay)"
}

func resolvedTargets(targetAllDisplays: Bool, targetDisplay: String, availableDisplays: [String]) -> [String] {
    if targetAllDisplays {
        var seen = Set<String>()
        return availableDisplays.filter { display in
            !display.isEmpty && seen.insert(display).inserted
        }
    }

    guard !targetDisplay.isEmpty, availableDisplays.contains(targetDisplay) else {
        return []
    }

    return [targetDisplay]
}
