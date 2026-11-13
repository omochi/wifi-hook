import Foundation

@main
struct ScriptRunnerTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-hook-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let success = ScriptRunner.run(Rule(ssid: "test", script: "printf 'hello' > result.txt\nprintf 'ignored output'", directory: directory.path))
        precondition(success.success && success.ssid == "test")
        let output = try String(contentsOf: directory.appendingPathComponent("result.txt"), encoding: .utf8)
        precondition(output == "hello")
        let failure = ScriptRunner.run(Rule(ssid: "test", script: "exit 42"))
        precondition(!failure.success && failure.detail == "終了コード: 42")
        let invalidDirectory = ScriptRunner.run(Rule(ssid: "test", script: "exit 0", directory: directory.appendingPathComponent("missing").path))
        precondition(!invalidDirectory.success)
        let original = Configuration(rules: [Rule(ssid: "Wi-Fi", script: "echo one\necho two", directory: directory.path)])
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(original))
        precondition(decoded.rules == original.rules && decoded.monitoring && decoded.showMenuBar)
        var tracker = ConnectionTracker()
        precondition(tracker.observe("Home"))
        precondition(!tracker.observe("Home"))
        precondition(tracker.observe("Office"))
        precondition(tracker.observe("Office", force: true))
        precondition(!tracker.observe(nil))
        precondition(tracker.observe("Office"))
        tracker.reset()
        precondition(tracker.observe("Office"))
        print("Script execution, settings round-trip, and connection transitions passed")
    }
}
