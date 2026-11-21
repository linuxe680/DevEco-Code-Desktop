import SwiftUI

struct ProvidersView: View {
    @EnvironmentObject var providerStore: ProviderStore
    @State private var editingProvider: ProviderEntry?
    @State private var showEditor = false
    @State private var selectedDefault = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(NSLocalizedString("Models & Providers", comment: "")).font(.title2.weight(.semibold))
                Spacer()
                Button {
                    editingProvider = ProviderEntry(
                        id: "",
                        name: "",
                        npm: "@ai-sdk/openai-compatible",
                        rawOptions: [:],
                        rawModels: [:],
                        models: []
                    )
                    showEditor = true
                } label: {
                    Label(NSLocalizedString("Add Provider", comment: ""), systemImage: "plus")
                }
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    defaultModelSection
                    configuredSection
                    catalogSection
                }
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(16)
            }
        }
        .sheet(isPresented: $showEditor) {
            if let editingProvider {
                ProviderEditorView(
                    provider: Binding(
                        get: { self.editingProvider ?? editingProvider },
                        set: { self.editingProvider = $0 }
                    ),
                    isNew: editingProvider.id.isEmpty,
                    onSave: {
                        Task {
                            let ok = await providerStore.save(editingProvider)
                            if ok { showEditor = false }
                        }
                    },
                    onCancel: { showEditor = false }
                )
            }
        }
        .onAppear { selectedDefault = providerStore.defaultModel }
        .onChange(of: providerStore.defaultModel) { selectedDefault = $0 }
    }

    private var defaultModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Default model", comment: "")).font(.headline)
            HStack {
                Picker("", selection: $selectedDefault) {
                    Text(NSLocalizedString("None", comment: "")).tag("")
                    ForEach(providerStore.allModelChoices) { choice in
                        Text("\(choice.provider) · \(choice.name)").tag(choice.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Button(NSLocalizedString("Apply", comment: "")) {
                    Task { await providerStore.setDefaultModel(selectedDefault) }
                }
                .disabled(selectedDefault == providerStore.defaultModel)
            }
            Text(NSLocalizedString("Used when a session has no explicit model.", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var configuredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Configured providers", comment: "")).font(.headline)
            if providerStore.providers.isEmpty {
                Text(NSLocalizedString("No custom providers configured.", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(providerStore.providers) { provider in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(NSLocalizedString("Base URL", comment: "")).foregroundStyle(.secondary)
                            Text(provider.baseURL.isEmpty ? "—" : provider.baseURL)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        HStack {
                            Text(NSLocalizedString("API key", comment: "")).foregroundStyle(.secondary)
                            Text(provider.apiKey.isEmpty ? "—" : String(repeating: "•", count: min(provider.apiKey.count, 12)))
                            Spacer()
                        }
                        Divider()
                        ForEach(provider.models) { model in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.name)
                                    Text(model.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.reasoning {
                                    Text(NSLocalizedString("reasoning", comment: ""))
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.18))
                                        .clipShape(Capsule())
                                }
                                Text("\(model.context / 1000)k ctx")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.vertical, 6)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(provider.name)
                            Text(provider.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(provider.models.count) models")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            editingProvider = provider
                            showEditor = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) {
                            Task { await providerStore.delete(provider) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Available providers", comment: "")).font(.headline)
            Text(NSLocalizedString("Built-in and plugin providers reported by deveco.", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(providerStore.catalog) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.displayName)
                        Text(item.source ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(item.modelCount) models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let envKey = item.env?.first, !envKey.isEmpty {
                        Text(envKey)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !providerStore.providers.contains(where: { $0.id == item.id }),
                       let template = providerStore.providerFromCatalog(item) {
                        Button(NSLocalizedString("Configure", comment: "")) {
                            editingProvider = template
                            showEditor = true
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
