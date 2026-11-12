import Foundation

struct Rule: Codable, Identifiable, Equatable {
    var id = UUID()
    var ssid = ""
    var script = ""
    var directory = ""
}

struct RunResult: Codable {
    let ssid: String
    let date: Date
    let success: Bool
    let detail: String
}

struct Configuration: Codable {
    var rules: [Rule] = []
    var monitoring = true
    var showMenuBar = true
    var lastResult: RunResult?
}

enum ScriptRunner {
    static func run(_ rule: Rule) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", rule.script]
        if !rule.directory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: (rule.directory as NSString).expandingTildeInPath, isDirectory: true)
        }
        var environment = ProcessInfo.processInfo.environment
        // GUI applications do not inherit a terminal's interactive shell PATH.
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = ([environment["PATH"] ?? ""] + paths).filter { !$0.isEmpty }.joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let success = process.terminationReason == .exit && process.terminationStatus == 0
            let detail = success ? "正常に終了しました" : "終了コード: \(process.terminationStatus)"
            return RunResult(ssid: rule.ssid, date: Date(), success: success, detail: detail)
        } catch {
            return RunResult(ssid: rule.ssid, date: Date(), success: false, detail: "スクリプトを起動できませんでした。作業ディレクトリなどを確認してください。")
        }
    }

}

/// Coalesced observations of the same SSID do not start a script twice.
struct ConnectionTracker {
    private(set) var lastSSID: String?

    mutating func observe(_ ssid: String?, force: Bool = false) -> Bool {
        guard let ssid, !ssid.isEmpty else { lastSSID = nil; return false }
        guard force || ssid != lastSSID else { return false }
        lastSSID = ssid
        return true
    }

    mutating func reset() { lastSSID = nil }
}
