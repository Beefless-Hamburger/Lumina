#if LUMINA_LOGIC_TESTS
import Foundation

@main
struct LuminaLogicTests {
    static func main() {
        testStatusTitle()
        testTargetResolution()
        testDisplayParsing()
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
        expect(resolvedTargets(targetAllDisplays: false, targetDisplay: "Display Alpha", availableDisplays: ["Display Alpha", "Display Beta"]) == ["Display Alpha"], "Single target resolution")
        expect(resolvedTargets(targetAllDisplays: false, targetDisplay: "", availableDisplays: ["Display Alpha"]) == [], "Empty target resolution")
        expect(resolvedTargets(targetAllDisplays: false, targetDisplay: "Missing", availableDisplays: ["Display Alpha"]) == [], "Unavailable target resolution")
    }

    private static func testDisplayParsing() {
        let payload = """
        {"name":"Display Beta"}
        {"name":"Default Group"}
        {"name":"Display Alpha"}
        """
        expect(parseDisplayNames(from: payload) == ["Display Alpha", "Display Beta"], "Line-delimited display parsing")

        let wrappedPayload = """
        {
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
        }
        """
        expect(parseDisplayNames(from: wrappedPayload) == ["Display Delta", "Display Gamma"], "Wrapped BetterDisplay payload parsing")

        let arrayPayload = """
        [{"name":"Zeta"},{"name":"Alpha"},{"name":"Default Group"}]
        """
        expect(parseDisplayNames(from: arrayPayload) == ["Alpha", "Zeta"], "Array display parsing")

        let noisyPayload = """
        [
          {"deviceType":"Display","name":"  Display Epsilon  "},
          {"deviceType":"Display","name":"Display Epsilon"},
          {"deviceType":"DisplayGroup","name":"Display Group"},
          {"deviceType":"Display","name":""},
          {"name":"Display Zeta"}
        ]
        """
        expect(parseDisplayNames(from: noisyPayload) == ["Display Epsilon", "Display Zeta"], "Display parsing should trim, deduplicate, and filter groups")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Lumina logic test failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
#endif
