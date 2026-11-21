import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label(NSLocalizedString("General", comment: ""), systemImage: "gearshape") }
            ServerSettingsPane()
                .tabItem { Label(NSLocalizedString("Server", comment: ""), systemImage: "server.rack") }
            ChatSettingsPane()
                .tabItem { Label(NSLocalizedString("Chat", comment: ""), systemImage: "bubble.left.and.bubble.right") }
            PermissionsSettingsPane()
                .tabItem { Label(NSLocalizedString("Permissions", comment: ""), systemImage: "lock.shield") }
            UsageSettingsPane()
                .tabItem { Label(NSLocalizedString("Usage", comment: ""), systemImage: "chart.bar") }
            AboutSettingsPane()
                .tabItem { Label(NSLocalizedString("About", comment: ""), systemImage: "info.circle") }
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

            Picker(NSLocalizedString("Language", comment: ""), selection: $appLanguageRaw) {
                Text(NSLocalizedString("Follow system", comment: "")).tag("system")
                Text("简体中文").tag("zh-Hans")
                Text("English").tag("en")
            }
            Text(NSLocalizedString("Takes effect after relaunch.", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            Divider()

            Picker(NSLocalizedString("When app quits:", comment: ""), selection: $quitBehaviorRaw) {
                Text(NSLocalizedString("Stop server", comment: "")).tag(QuitBehavior.stopServer.rawValue)
                Text(NSLocalizedString("Keep server running", comment: "")).tag(QuitBehavior.keepRunning.rawValue)
            }
            .pickerStyle(.radioGroup)
            Text(NSLocalizedString("Keeping the server running lets the next launch skip the boot wait, but the deveco process stays alive in the background.", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            Divider()

            Toggle(NSLocalizedString("Launch at login", comment: ""), isOn: $launchAtLogin)
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
                Text(NSLocalizedString("deveco CLI path", comment: ""))
                HStack {
                    TextField("/path/to/deveco", text: $devecoPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { refreshResolved() }
                    Button(NSLocalizedString("Browse…", comment: "")) { browse() }
                    Button(NSLocalizedString("Auto-detect", comment: "")) {
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
                Text(NSLocalizedString("Leave empty to auto-detect (common install paths, then your login shell's PATH).", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("Node.js path (optional)", comment: ""))
                HStack {
                    TextField("/path/to/node", text: $nodePath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { refreshResolved() }
                    Button(NSLocalizedString("Auto-detect", comment: "")) {
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
                Text(NSLocalizedString("deveco runs on Node.js. Leave empty to auto-detect; the detected folder is added to the server's PATH.", comment: ""))
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
                Text(NSLocalizedString("Starting port", comment: ""))
            }
            Text(NSLocalizedString("The first port tried (default 4096). If it is busy the app picks the next free one.", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(NSLocalizedString("Start server automatically on launch", comment: ""), isOn: $autoStartServer)

            Divider()

            HStack {
                Button(NSLocalizedString("Reveal Log Folder", comment: "")) { reveal(ServerManager.logFileURL) }
                Button(NSLocalizedString("Reveal Data Folder", comment: "")) { reveal(ServerManager.dataDirectory) }
                Button(NSLocalizedString("View Log…", comment: "")) { showLogViewer = true }
                Spacer()
            }

            HStack {
                Button(NSLocalizedString("Copy Diagnostics", comment: "")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.diagnosticsReport(), forType: .string)
                    diagnosticsCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        diagnosticsCopied = false
                    }
                }
                if diagnosticsCopied {
                    Label(NSLocalizedString("Copied", comment: ""), systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("Backup", comment: ""))
                    .font(.headline)
                Text(NSLocalizedString("Archive the deveco data directory (sessions, logs) as a zip. Restoring replaces the current data and restarts the server.", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(NSLocalizedString("Backup Now…", comment: "")) { backupPanel() }
                    Button(NSLocalizedString("Restore from Backup…", comment: "")) { restorePanel() }
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
        panel.prompt = NSLocalizedString("Use This Binary", comment: "")
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
        backupStatus = NSLocalizedString("Backing up…", comment: "")
        Task.detached(priority: .userInitiated) {
            do {
                try ServerManager.backupData(to: url)
                await MainActor.run {
                    backupFailed = false
                    backupStatus = String(
                        format: NSLocalizedString("Backed up to %@.", comment: ""),
                        url.lastPathComponent
                    )
                }
            } catch {
                await MainActor.run {
                    backupFailed = true
                    backupStatus = String(
                        format: NSLocalizedString("Backup failed: %@", comment: ""),
                        error.localizedDescription
                    )
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
        panel.message = NSLocalizedString("Choose a deveco backup archive", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Restore this backup?", comment: "")
        alert.informativeText = NSLocalizedString("Current session data will be replaced and the server restarted. This cannot be undone.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Restore", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        backupStatus = NSLocalizedString("Restoring…", comment: "")
        let server = server
        Task.detached(priority: .userInitiated) {
            do {
                await MainActor.run { server.stop() }
                try server.restoreData(from: url)
                await MainActor.run {
                    backupFailed = false
                    backupStatus = String(
                        format: NSLocalizedString("Restored from %@.", comment: ""),
                        url.lastPathComponent
                    )
                    server.start()
                }
            } catch {
                await MainActor.run {
                    backupFailed = true
                    backupStatus = String(
                        format: NSLocalizedString("Restore failed: %@", comment: ""),
                        error.localizedDescription
                    )
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
            Toggle(NSLocalizedString("Enter sends message (Shift+Enter inserts newline)", comment: ""), isOn: $sendOnEnter)
            Toggle(NSLocalizedString("Follow streaming output while generating", comment: ""), isOn: $autoScroll)
            Toggle(NSLocalizedString("Expand Thinking sections by default", comment: ""), isOn: $expandThinking)
            Toggle(NSLocalizedString("Notify when a generation completes", comment: ""), isOn: $notifyOnComplete)
                .onChange(of: notifyOnComplete) { enabled in
                    if enabled {
                        UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    }
                }
            Toggle(NSLocalizedString("Play a sound when a generation completes", comment: ""), isOn: $playSoundOnComplete)

            LabeledContent {
                Stepper(
                    "\(Int(chatFontSize)) pt",
                    value: $chatFontSize,
                    in: ChatTypography.minFontSize...ChatTypography.maxFontSize,
                    step: 1
                )
                .fixedSize()
            } label: {
                Text(NSLocalizedString("Chat text size", comment: ""))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(NSLocalizedString("Preview", comment: ""))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("Readable replies, clear code blocks, and comfortable tool output.", comment: ""))
                    .font(.system(size: ChatTypography.body(chatFontSize)))
                    .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
                Text(NSLocalizedString("let answer = 42", comment: ""))
                    .font(.system(size: ChatTypography.code(chatFontSize), design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8))

            Divider()

            LabeledContent {
                Picker("", selection: $defaultSessionModel) {
                    Text(NSLocalizedString("Server default", comment: "")).tag("")
                    ForEach(providers.allModelChoices) { choice in
                        Text("\(choice.provider) · \(choice.name)").tag(choice.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            } label: {
                Text(NSLocalizedString("Default model for new sessions", comment: ""))
            }
            Text(NSLocalizedString("Preselected in the chat header. The server-configured default (Models & Providers) is used when left unset.", comment: ""))
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
            Text(NSLocalizedString("Saved permission rules", comment: ""))
                .font(.headline)
            Text(NSLocalizedString("These were granted with “Always allow” on permission cards. Tools matching them run without asking — revoke any you no longer trust.", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)

            if providers.savedPermissions.isEmpty {
                Text(NSLocalizedString("No saved permission rules.", comment: ""))
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
                            Button(NSLocalizedString("Revoke", comment: "")) {
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
            Text(NSLocalizedString("Project usage", comment: ""))
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
                Text(NSLocalizedString("By model", comment: ""))
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
                    Text(NSLocalizedString("DevEco Code Desktop", comment: ""))
                        .font(.title3.weight(.semibold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text(NSLocalizedString("A native macOS client for the local deveco CLI — sessions, streaming, approvals, diffs, and model management.", comment: ""))
                .font(.callout)
            Text(NSLocalizedString("Protocol and UX reference: opencode (MIT) and OpenAI Codex (Apache-2.0). Design learned from their public sources; all code here is original Swift.", comment: ""))
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
                Text(NSLocalizedString("Server log", comment: ""))
                    .font(.headline)
                Text("\(server.logTail.count) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(NSLocalizedString("Copy All", comment: "")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.logTail, forType: .string)
                }
                .controlSize(.small)
                Button(NSLocalizedString("Done", comment: "")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(server.logTail.isEmpty ? NSLocalizedString("(no output yet)", comment: "") : server.logTail)
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
