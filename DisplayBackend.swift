import Foundation

protocol DisplayBackend: Sendable {
    func refreshDisplayNames() async -> [String]
    func powerOff(targets: [String]) async
    func powerOn(targets: [String]) async
}
