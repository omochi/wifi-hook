import AppKit
import CoreLocation
import CoreWLAN
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: NSObject, ObservableObject, CLLocationManagerDelegate, CWEventDelegate, UNUserNotificationCenterDelegate {
    @Published var config: Configuration { didSet { save() } }
    @Published var currentSSID: String?
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published var loginStatus: SMAppService.Status = .notRegistered
    @Published var monitorError: String?
    @Published var settingsError: String?
    @Published var nearby: [String] = []
    @Published var remembered: [String] = []
    @Published var scanError: String?
    @Published var scanning = false
    @Published var executing = false
    @Published var selection: Page = .status

    enum Page: String, CaseIterable, Identifiable {
        case status = "監視状態", rules = "Wi-Fi の設定", settings = "アプリの設定"
        var id: Self { self }
        var symbol: String { switch self { case .status: "dot.radiowaves.left.and.right"; case .rules: "wifi"; case .settings: "gearshape" } }
    }

    private let wifi = CWWiFiClient.shared()
    private let location = CLLocationManager()
    private let notifications = UNUserNotificationCenter.current()
    private var eventWork: DispatchWorkItem?
    private var connectionTracker = ConnectionTracker()
    private var pendingSSID: String?
    private var isObserving = false
    var openMainWindow: (() -> Void)?
    private let defaultsKey = "configuration.v1"

    override init() {
        if let data = UserDefaults.standard.data(forKey: "configuration.v1"),
           let saved = try? JSONDecoder().decode(Configuration.self, from: data) {
            config = saved
        } else { config = Configuration() }
        super.init()
        location.delegate = self
        locationStatus = location.authorizationStatus
        notifications.delegate = self
        wifi.delegate = self
        refreshSystemStatus()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        if config.monitoring { startMonitoring() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func setMonitoring(_ enabled: Bool) {
        config.monitoring = enabled
        if enabled { startMonitoring() }
        else {
            eventWork?.cancel()
            try? wifi.stopMonitoringAllEvents()
            isObserving = false
            pendingSSID = nil
            connectionTracker.reset()
            monitorError = nil
        }
    }

    private func startMonitoring() {
        do {
            try wifi.startMonitoringEvent(with: .ssidDidChange)
            try wifi.startMonitoringEvent(with: .linkDidChange)
            try wifi.startMonitoringEvent(with: .powerDidChange)
            isObserving = true
            monitorError = nil
            scheduleEvaluation()
        } catch {
            try? wifi.stopMonitoringAllEvents()
            isObserving = false
            monitorError = "Wi-Fi の監視を開始できませんでした: \(error.localizedDescription)"
        }
    }

    var monitoringDescription: String {
        if !config.monitoring { return "停止中" }
        if monitorError != nil { return "監視を開始できませんでした" }
        if !locationAuthorized { return "位置情報の許可を確認してください" }
        return isObserving ? "監視中" : "準備中"
    }

    var locationAuthorized: Bool {
        locationStatus == .authorizedAlways
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) { Task { @MainActor in self.scheduleEvaluation() } }
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) { Task { @MainActor in self.scheduleEvaluation() } }
    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { Task { @MainActor in self.scheduleEvaluation() } }
    nonisolated func clientConnectionInterrupted() { Task { @MainActor in self.monitorError = "Wi-Fi の監視が一時的に中断されました。" } }
    nonisolated func clientConnectionInvalidated() { Task { @MainActor in self.isObserving = false; self.monitorError = "Wi-Fi の監視が切断されました。監視を入れ直してください。" } }
    @objc private func woke() { if config.monitoring { scheduleEvaluation() } }

    func scheduleEvaluation(force: Bool = false) {
        eventWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate(force: force) }
        eventWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func evaluate(force: Bool) {
        guard config.monitoring, isObserving else { return }
        let ssid = wifi.interface()?.ssid()
        currentSSID = ssid
        guard connectionTracker.observe(ssid, force: force), let ssid else {
            if ssid == nil || ssid?.isEmpty == true { pendingSSID = nil }
            return
        }
        guard config.rules.contains(where: { $0.ssid == ssid }) else { pendingSSID = nil; return }
        if executing { pendingSSID = ssid; return }
        executeRule(for: ssid)
    }

    private func executeRule(for ssid: String) {
        guard let rule = config.rules.first(where: { $0.ssid == ssid }) else { return }
        executing = true
        // Output is discarded: scripts may print credentials or .env contents.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ScriptRunner.run(rule)
            DispatchQueue.main.async {
                guard let self else { return }
                self.config.lastResult = result
                self.executing = false
                self.postNotification(result)
                if let pending = self.pendingSSID {
                    self.pendingSSID = nil
                    if self.config.monitoring && self.currentSSID == pending { self.executeRule(for: pending) }
                }
            }
        }
    }

    private func postNotification(_ result: RunResult) {
        let content = UNMutableNotificationContent()
        content.title = result.success ? "スクリプトを実行しました" : "スクリプトの実行に失敗しました"
        content.body = "\(result.ssid) · \(result.detail)"
        content.sound = .default
        notifications.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.selection = .status; self.showWindow(); completionHandler() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func showWindow() {
        if let window = NSApp.windows.first(where: { $0.canBecomeKey && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            openMainWindow?()
        }
    }
    func requestLocation() { location.requestWhenInUseAuthorization() }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.locationStatus = self.location.authorizationStatus
            if self.config.monitoring { self.scheduleEvaluation() }
        }
    }
    func requestNotifications() {
        notifications.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshSystemStatus() }
        }
    }
    func refreshSystemStatus() {
        locationStatus = location.authorizationStatus
        loginStatus = SMAppService.mainApp.status
        notifications.getNotificationSettings { [weak self] settings in
            Task { @MainActor in self?.notificationStatus = settings.authorizationStatus }
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settingsError = nil
        } catch { settingsError = "ログイン時起動を変更できませんでした: \(error.localizedDescription)" }
        loginStatus = SMAppService.mainApp.status
    }
    func openLocationSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) }
    func openNotificationSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }

    func loadNetworks() {
        guard locationAuthorized, !scanning else { return }
        scanning = true; scanError = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let interface = CWWiFiClient.shared().interface()
            let remembered = (interface?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []).compactMap { $0.ssid }.sorted()
            do {
                let networks = try interface?.scanForNetworks(withName: nil) ?? []
                let nearby = Array(Set(networks.compactMap { $0.ssid })).sorted()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.scanning = false
                    guard self.locationAuthorized else { return }
                    self.nearby = nearby
                    self.remembered = remembered
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.scanning = false
                    guard self.locationAuthorized else { return }
                    self.remembered = remembered
                    self.nearby = []
                    self.scanError = "周囲の Wi-Fi を取得できませんでした: \(error.localizedDescription)"
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main
struct WiFiHookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Wi-Fi Hook", id: "main") { ContentView().environmentObject(model) }
            .windowResizability(.contentMinSize)
        MenuBarExtra("Wi-Fi Hook", systemImage: "wifi", isInserted: Binding(
            get: { model.config.showMenuBar },
            set: { visible in
                guard model.config.showMenuBar != visible else { return }
                DispatchQueue.main.async {
                    if model.config.showMenuBar != visible { model.config.showMenuBar = visible }
                }
            }
        )) {
            Text(model.monitoringDescription)
            Text(model.currentSSID ?? "Wi-Fi 未接続")
            Divider()
            Button("Wi-Fi Hook を開く") { model.showWindow() }
            Button("Wi-Fi Hook を終了") { NSApp.terminate(nil) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            List(AppModel.Page.allCases, selection: $model.selection) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page)
            }.navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            switch model.selection {
            case .status: StatusView()
            case .rules: RulesView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshSystemStatus() }
    }
}

struct StatusView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section("現在の状態") {
                Toggle(isOn: Binding(get: { model.config.monitoring }, set: model.setMonitoring)) {
                    VStack(alignment: .leading) { Text("Wi-Fi を監視"); Text(model.monitoringDescription).font(.caption).foregroundStyle(.secondary) }
                }
                LabeledContent("接続中の Wi-Fi", value: model.currentSSID ?? "取得できません")
                LabeledContent("一致する設定", value: model.config.rules.contains(where: { $0.ssid == model.currentSSID }) ? "登録済み" : "なし")
                if let error = model.monitorError { Text(error).foregroundStyle(.red) }
                Button("再判定") { model.scheduleEvaluation(force: true) }.disabled(!model.config.monitoring)
            }
            Section("最後の実行") {
                if model.executing { Text("スクリプトを実行中…") }
                if let result = model.config.lastResult {
                    Label(result.detail, systemImage: result.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(result.success ? .green : .red)
                    LabeledContent("Wi-Fi", value: result.ssid)
                    LabeledContent("実行日時") { Text(result.date, format: .dateTime.year().month().day().hour().minute().second()) }
                } else { Text("まだスクリプトは実行されていません").foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped).navigationTitle("監視状態")
    }
}

struct RulesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: Rule?
    @State private var isNew = false
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("Wi-Fi の設定").font(.title2.bold()); Spacer(); Button("追加", systemImage: "plus") { isNew = true; editing = Rule() } }
            if model.config.rules.isEmpty {
                ContentUnavailableView("設定はまだありません", systemImage: "wifi", description: Text("「追加」から Wi-Fi とスクリプトを登録します。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else {
                List(model.config.rules) { rule in
                    HStack { Label(rule.ssid, systemImage: "wifi"); Spacer(); Button("編集") { isNew = false; editing = rule } }
                }
            }
        }.padding().sheet(item: $editing) { rule in RuleEditor(rule: rule, isNew: isNew) }
    }
}

struct RuleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    let isNew: Bool
    @State private var showingDelete = false
    private var duplicate: Bool { model.config.rules.contains { $0.id != rule.id && $0.ssid == rule.ssid.trimmingCharacters(in: .whitespacesAndNewlines) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Wi-Fi の設定を追加" : "Wi-Fi の設定を編集").font(.headline)
            HStack {
                Menu("Wi-Fi を選択") {
                    if !model.nearby.isEmpty { Section("周囲のネットワーク") { ForEach(model.nearby, id: \.self) { name in Button(name) { rule.ssid = name } } } }
                    if !model.remembered.isEmpty { Section("保存済みのネットワーク") { ForEach(model.remembered, id: \.self) { name in Button(name) { rule.ssid = name } } } }
                    if model.nearby.isEmpty && model.remembered.isEmpty { Text(model.scanning ? "取得中…" : "ネットワークがありません") }
                }.disabled(!model.locationAuthorized)
                Button("更新") { model.loadNetworks() }.disabled(!model.locationAuthorized || model.scanning)
            }
            if !model.locationAuthorized {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Wi-Fi の一覧と接続先の取得には位置情報の許可が必要です。Wi-Fi 名は直接入力することもできます。")
                            .font(.caption)
                        if model.locationStatus == .notDetermined {
                            Button("位置情報を許可する") { model.requestLocation() }
                        } else {
                            Button("位置情報の設定を開く") { model.openLocationSettings() }
                        }
                    }
                }
            }
            if let error = model.scanError { Text(error).font(.caption).foregroundStyle(.secondary) }
            TextField("Wi-Fi 名", text: $rule.ssid)
            if duplicate { Text("この Wi-Fi はすでに登録されています。").foregroundStyle(.red).font(.caption) }
            Text("スクリプト")
            TextEditor(text: $rule.script).font(.system(.body, design: .monospaced)).frame(height: 100).border(.quaternary)
            HStack { TextField("作業ディレクトリ（任意）", text: $rule.directory); Button("選択…") { chooseDirectory() } }
            HStack {
                if !isNew { Button("削除", role: .destructive) { showingDelete = true } }
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(rule.ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rule.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || duplicate)
            }
        }.padding(24).frame(width: 510)
            .onAppear { model.loadNetworks() }
            .onChange(of: model.locationStatus) {
                if model.locationAuthorized { model.loadNetworks() }
                else { model.nearby = []; model.remembered = []; model.scanError = nil }
            }
            .confirmationDialog("この Wi-Fi の設定を削除しますか？", isPresented: $showingDelete) {
                Button("削除", role: .destructive) { model.config.rules.removeAll { $0.id == rule.id }; dismiss() }
                Button("キャンセル", role: .cancel) {}
            }
    }
    private func save() {
        rule.ssid = rule.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.directory = rule.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = model.config.rules.firstIndex(where: { $0.id == rule.id }) { model.config.rules[index] = rule }
        else { model.config.rules.append(rule) }
        dismiss()
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { rule.directory = url.path }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section("起動と表示") {
                Toggle("ログイン時に起動", isOn: Binding(get: { model.loginStatus == .enabled }, set: model.setLogin))
                if model.loginStatus == .requiresApproval { Button("ログイン項目の設定を開く") { SMAppService.openSystemSettingsLoginItems() } }
                Toggle("メニューバーに表示", isOn: $model.config.showMenuBar)
            }
            Section("権限") {
                LabeledContent {
                    if model.locationStatus == .notDetermined { Button("許可する") { model.requestLocation() } }
                    else if model.locationAuthorized { Text("許可済み").foregroundStyle(.secondary) }
                    else { Button("システム設定を開く") { model.openLocationSettings() } }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("位置情報")
                        Text("周囲の Wi-Fi 一覧と現在の接続先の取得に使用します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("通知") {
                    if model.notificationStatus == .notDetermined { Button("許可する") { model.requestNotifications() } }
                    else if model.notificationStatus == .authorized || model.notificationStatus == .provisional { Text("許可済み").foregroundStyle(.secondary) }
                    else { Button("システム設定を開く") { model.openNotificationSettings() } }
                }
            }
            if let error = model.settingsError { Text(error).foregroundStyle(.red) }
        }.formStyle(.grouped).navigationTitle("アプリの設定")
    }
}
