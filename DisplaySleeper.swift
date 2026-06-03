import Foundation

protocol DisplaySleeper: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

struct TaskDisplaySleeper: DisplaySleeper {
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
