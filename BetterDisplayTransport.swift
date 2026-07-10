import Foundation

enum BetterDisplayAvailability: Sendable, Equatable {
    case running
    case unavailable
    case launchFailed(String)
    case timedOut
    case cancelled

    var isAvailable: Bool {
        self == .running
    }
}

enum BetterDisplayExecutionStatus: Sendable, Equatable {
    case succeeded
    case executableMissing
    case launchFailed(String)
    case nonZeroExit(Int32)
    case timedOut
    case cancelled
}

struct BetterDisplayExecutionResult: Sendable, Equatable {
    let status: BetterDisplayExecutionStatus
    let output: String
    let errorOutput: String
    let outputWasTruncated: Bool
    let errorOutputWasTruncated: Bool

    var succeeded: Bool {
        status == .succeeded
    }

    static func failure(_ status: BetterDisplayExecutionStatus) -> BetterDisplayExecutionResult {
        BetterDisplayExecutionResult(
            status: status,
            output: "",
            errorOutput: "",
            outputWasTruncated: false,
            errorOutputWasTruncated: false
        )
    }
}

protocol BetterDisplayTransport: Sendable {
    func ensureRunning(context: String) async -> BetterDisplayAvailability
    func run(arguments: [String], context: String, captureOutput: Bool) async -> BetterDisplayExecutionResult
}
