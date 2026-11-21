import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            ServerSettingsPane()
                .tabItem { Label("Server", systemImage: "server.rack") }
            ChatSettingsPane()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            PermissionsSettingsPane()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            UsageSettingsPane()
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            AboutSettingsPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @AppStorage(AppSettings.Keys.quitBehavior)
    private var quitBehaviorRaw = QuitBehavior.stopServer.rawValue
    @AppStorage(AppSettings.Keys.appLanguage)
    private var appLanguageRaw = "zh-Hans"
    @AppStorage(AppSettings.Keys.appAppearance)
    private var appAppearanceRaw = AppAppearance.dark.rawValue

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Picker("外观", selection: $appAppearanceRaw) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance.rawValue)
                }
            }
            .onChange(of: appAppearanceRaw) { _ in
                AppSettings.applyAppearanceOverride()
            }

            Divider()

            Picker("Language", selection: $appLanguageRaw) {
                Text("跟随系统 / System").tag("system")
                Text("简体中文").tag("zh-Hans")
                Text("English").tag("en")
            }
            Text("Takes effect after relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            Divider()

            Picker("When app quits:", selection: $quitBehaviorRaw) {
                Text("Stop server").tag(QuitBehavior.stopServer.rawValue)
                Text("Keep server running").tag(QuitBehavior.keepRunning.rawValue)
            }
            .pickerStyle(.radioGroup)
            Text("Keeping the server running lets the next launch skip the boot wait, but the deveco process stays alive in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        launchError = nil
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                        launchError = error.localizedDescription
                    }
                }
            if let launchError {
                Text(launchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
    }
}

// MARK: - Server

private struct ServerSettingsPane: View {
    @EnvironmentObject var server: ServerManager
    @AppStorage(AppSettings.Keys.devecoPath)
    private var devecoPath = ""
    @AppStorage(AppSettings.Keys.basePort)
    private var basePort = 4096
    @AppStorage(AppSettings.Keys.autoStartServer)
    private var autoStartServer = true

    @State private var resolvedPath = ""
    @AppStorage("nodeExecutablePath")
    private var nodePath = ""
    @State private var resolvedNodePath = ""
    @State private var backupStatus: String?
    @State private var backupFailed = false
    @State private var showLogViewer = false
    @State private var diagnosticsCopied = false

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 6) {
                Text("deveco CLI path")
                HStack {
                    TextField("/path/to/deveco", text: $devecoPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { refreshResolved() }
                    Button("Browse…") { browse() }
                    Button("Auto-detect") {
                        devecoPath = ""
                        refreshResolved()
                    }
                }
                Text(resolvedDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("Leave empty to auto-detect (common install paths, then your login shell's PATH).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("Node.js path (optional)")
                HStack {
                    TextField("/path/to/node", text: $nodePath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { refreshResolved() }
                    Button("Auto-detect") {
                        UserDefaults.standard.removeObject(forKey: "nodeExecutablePath")
                        refreshResolved()
                    }
                }
                Text(resolvedNodeDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("deveco runs on Node.js. Leave empty to auto-detect; the detected folder is added to the server's PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            Divider()

            LabeledContent {
                TextField("Port", value: $basePort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            } label: {
                Text("Starting port")
            }
            Text("The first port tried (default 4096). If it is busy the app picks the next free one.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Start server automatically on launch", isOn: $autoStartServer)

            Divider()

            HStack {
                Button("Reveal Log Folder") { reveal(ServerManager.logFileURL) }
                Button("Reveal Data Folder") { reveal(ServerManager.dataDirectory) }
                Button("View Log…") { showLogViewer = true }
                Spacer()
            }

            HStack {
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.diagnosticsReport(), forType: .string)
                    diagnosticsCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        diagnosticsCopied = false
                    }
                }
                if diagnosticsCopied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Backup")
                    .font(.headline)
                Text("Archive the deveco data directory (sessions, logs) as a zip. Restoring replaces the current data and restarts the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Backup Now…") { backupPanel() }
                    Button("Restore from Backup…") { restorePanel() }
                    Spacer()
                }
                if let status = backupStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(backupFailed ? .red : .secondary)
                }
            }
        }
        .padding(20)
        .onAppear(perform: refreshResolved)
        .sheet(isPresented: $showLogViewer) {
            LogViewerSheet()
        }
    }

    private var resolvedDisplay: String {
        if resolvedPath.isEmpty {
            return NSLocalizedString("Not found — install deveco or set a path above.", comment: "")
        }
        return String(format: NSLocalizedString("In use: %@", comment: ""), resolvedPath)
    }

    private var resolvedNodeDisplay: String {
        if resolvedNodePath.isEmpty {
            return NSLocalizedString("Node.js not found yet — it will be probed when the server starts.", comment: "")
        }
        return String(format: NSLocalizedString("In use: %@", comment: ""), resolvedNodePath)
    }

    private func refreshResolved() {
        let devecoPath = ServerManager.resolveDevecoExecutable()?.path ?? ""
        let nodePath = ServerManager.resolveNodeDirectory() ?? ""
        resolvedPath = devecoPath
        resolvedNodePath = nodePath
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        panel.prompt = "Use This Binary"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        devecoPath = url.path
        refreshResolved()
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func backupPanel() {
        let panel = NSSavePanel()
        let stamp = DateFormatter.timestamp()
        panel.nameFieldStringValue = "deveco-backup-\(stamp).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupStatus = "Backing up…"
        Task.detached(priority: .userInitiated) {
            do {
                try ServerManager.backupData(to: url)
                await MainActor.run {
                    backupFailed = false
                    backupStatus = "Backed up to \(url.lastPathComponent)."
                }
            } catch {
                await MainActor.run {
                    backupFailed = true
                    backupStatus = "Backup failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func restorePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose a deveco backup archive"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Restore this backup?", comment: "")
        alert.informativeText = NSLocalizedString("Current session data will be replaced and the server restarted. This cannot be undone.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Restore", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        backupStatus = "Restoring…"
        let server = server
        Task.detached(priority: .userInitiated) {
            do {
                await MainActor.run { server.stop() }
                try server.restoreData(from: url)
                await MainActor.run {
                    backupFailed = false
                    backupStatus = "Restored from \(url.lastPathComponent)."
                    server.start()
                }
            } catch {
                await MainActor.run {
                    backupFailed = true
                    backupStatus = "Restore failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

private extension DateFormatter {
    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}

// MARK: - Chat

private struct ChatSettingsPane: View {
    @EnvironmentObject var providers: ProviderStore

    @AppStorage(AppSettings.Keys.sendOnEnter)
    private var sendOnEnter = true
    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0
    @AppStorage(AppSettings.Keys.autoScroll)
    private var autoScroll = true
    @AppStorage(AppSettings.Keys.expandThinking)
    private var expandThinking = false
    @AppStorage(AppSettings.Keys.defaultSessionModel)
    private var defaultSessionModel = ""
    @AppStorage(AppSettings.Keys.notifyOnComplete)
    private var notifyOnComplete = false
    @AppStorage(AppSettings.Keys.playSoundOnComplete)
    private var playSoundOnComplete = false

    var body: some View {
        Form {
            Toggle("Enter sends message (Shift+Enter inserts newline)", isOn: $sendOnEnter)
            Toggle("Follow streaming output while generating", isOn: $autoScroll)
            Toggle("Expand Thinking sections by default", isOn: $expandThinking)
            Toggle("Notify when a generation completes", isOn: $notifyOnComplete)
                .onChange(of: notifyOnComplete) { enabled in
                    if enabled {
                        UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    }
                }
            Toggle("Play a sound when a generation completes", isOn: $playSoundOnComplete)

            LabeledContent {
                Stepper(
                    "\(Int(chatFontSize)) pt",
                    value: $chatFontSize,
                    in: ChatTypography.minFontSize...ChatTypography.maxFontSize,
                    step: 1
                )
                .fixedSize()
            } label: {
                Text("Chat text size")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Preview")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Readable replies, clear code blocks, and comfortable tool output.")
                    .font(.system(size: ChatTypography.body(chatFontSize)))
                    .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
                Text("let answer = 42")
                    .font(.system(size: ChatTypography.code(chatFontSize), design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8))

            Divider()

            LabeledContent {
                Picker("", selection: $defaultSessionModel) {
                    Text("Server default").tag("")
                    ForEach(providers.allModelChoices) { choice in
                        Text("\(choice.provider) · \(choice.name)").tag(choice.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            } label: {
                Text("Default model for new sessions")
            }
            Text("Preselected in the chat header. The server-configured default (Models & Providers) is used when left unset.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}


// MARK: - Permissions (saved "Always allow" rules)

private struct PermissionsSettingsPane: View {
    @EnvironmentObject var providers: ProviderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved permission rules")
                .font(.headline)
            Text("These were granted with “Always allow” on permission cards. Tools matching them run without asking — revoke any you no longer trust.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if providers.savedPermissions.isEmpty {
                Text("No saved permission rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                List {
                    ForEach(providers.savedPermissions) { saved in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(saved.resource ?? saved.id)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(saved.action ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke") {
                                Task { await providers.deleteSavedPermission(saved) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220)
            }
        }
        .padding(20)
        .onAppear {
            Task { await providers.loadSavedPermissions() }
        }
    }
}

// MARK: - Usage

private struct UsageSettingsPane: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project usage")
                .font(.headline)

            if let total = store.usage?.total {
                HStack(spacing: 20) {
                    statItem("\(Int(total.sessions ?? 0))", "Sessions")
                    statItem("\(Int(total.messages ?? 0))", "Messages")
                    statItem(String(format: "$%.2f", total.cost ?? 0), "Cost")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if let models = store.usage?.models, !models.isEmpty {
                Text("By model")
                    .font(.subheadline.weight(.semibold))
                List {
                    ForEach(models) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(model.providerID ?? "?") · \(model.modelID ?? "?")")
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text("\(Int(model.messages ?? 0)) messages")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "$%.2f", model.cost ?? 0))
                                .font(.callout.weight(.medium))
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220)
            }
        }
        .padding(20)
        .onAppear {
            Task { await store.loadUsage() }
        }
    }

    private func statItem(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - About

private struct AboutSettingsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DevEco Code Desktop")
                        .font(.title3.weight(.semibold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("A native macOS client for the local deveco CLI — sessions, streaming, approvals, diffs, and model management.")
                .font(.callout)
            Text("Protocol and UX reference: opencode (MIT) and OpenAI Codex (Apache-2.0). Design learned from their public sources; all code here is original Swift.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Logs: `log stream --predicate 'subsystem == \"com.local.deveco-codesktop\"'`")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Log viewer

/// Live tail of the managed server's log output (same content as server.log).
private struct LogViewerSheet: View {
    @EnvironmentObject var server: ServerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Server log")
                    .font(.headline)
                Text("\(server.logTail.count) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.logTail, forType: .string)
                }
                .controlSize(.small)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(server.logTail.isEmpty ? "(no output yet)" : server.logTail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("log-bottom")
                }
                .onChange(of: server.logTail.count) { _ in
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
        .frame(width: 720, height: 480)
    }
}
