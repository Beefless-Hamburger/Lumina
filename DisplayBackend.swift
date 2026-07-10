import Foundation

enum DisplayOperationStatus: Sendable, Equatable {
    case succeeded
    case noTargets
    case betterDisplayUnavailable(BetterDisplayAvailability)
    case superseded
    case failed
}

struct DisplayOperationResult: Sendable, Equatable {
    let status: DisplayOperationStatus
    let attemptedCommandCount: Int
    let failedCommandCount: Int

    static let noTargets = DisplayOperationResult(
        status: .noTargets,
        attemptedCommandCount: 0,
        failedCommandCount: 0
    )
}

protocol DisplayBackend: Sendable {
    func refreshDisplayNames() async -> [String]
    func powerOff(targets: [String]) async -> DisplayOperationResult
    func powerOn(targets: [String]) async -> DisplayOperationResult
}
