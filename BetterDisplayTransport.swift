import Foundation

struct BetterDisplayExecutionResult: Sendable {
    let output: String
    let errorOutput: String
    let exitCode: Int32
}

protocol BetterDisplayTransport: Sendable {
    func ensureRunning(context: String) async -> Bool
    func run(arguments: [String], context: String, captureOutput: Bool) async -> BetterDisplayExecutionResult?
}
