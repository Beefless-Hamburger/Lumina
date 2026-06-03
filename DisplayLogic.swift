import Foundation

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
        return availableDisplays
    }

    guard !targetDisplay.isEmpty, availableDisplays.contains(targetDisplay) else {
        return []
    }

    return [targetDisplay]
}
