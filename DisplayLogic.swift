import Foundation

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
