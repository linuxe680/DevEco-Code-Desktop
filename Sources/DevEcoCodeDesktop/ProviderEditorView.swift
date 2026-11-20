import SwiftUI

struct ProviderEditorView: View {
    @Binding var provider: ProviderEntry
    let isNew: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var newModelID = ""
    @State private var newModelName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "Add Provider" : "Edit \(provider.name)").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(provider.id.trimmingCharacters(in: .whitespaces).isEmpty || provider.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeledField("Provider ID", text: $provider.id, placeholder: "my-provider")
                        .disabled(!isNew)
                    labeledField("Display name", text: $provider.name, placeholder: "My Provider")
                    labeledField("npm package", text: $provider.npm, placeholder: "@ai-sdk/openai-compatible")
                    labeledField("Base URL", text: Binding(
                        get: { provider.baseURL },
                        set: { provider.baseURL = $0 }
                    ), placeholder: "https://api.example.com/v1")
                    secureField("API key", text: Binding(
                        get: { provider.apiKey },
                        set: { provider.apiKey = $0 }
                    ))

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Models").font(.headline)
                        ForEach($provider.models) { $model in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    TextField("Model ID", text: $model.id)
                                    TextField("Display name", text: $model.name)
                                    Button(role: .destructive) {
                                        provider.models.removeAll { $0.id == model.id }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain)
                                }
                                HStack {
                                    Toggle("Reasoning", isOn: $model.reasoning)
                                    Spacer()
                                    Text("Context")
                                    TextField("Context", value: $model.context, format: .number)
                                        .frame(width: 90)
                                    Text("Output")
                                    TextField("Output", value: $model.output, format: .number)
                                        .frame(width: 90)
                                }
                                .font(.caption)
                            }
                            .padding(10)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        HStack {
                            TextField("New model ID", text: $newModelID)
                            TextField("Display name (optional)", text: $newModelName)
                            Button {
                                let id = newModelID.trimmingCharacters(in: .whitespaces)
                                guard !id.isEmpty, !provider.models.contains(where: { $0.id == id }) else { return }
                                provider.models.append(
                                    ModelEntry(
                                        id: id,
                                        name: newModelName.isEmpty ? id : newModelName,
                                        reasoning: false,
                                        context: 128000,
                                        output: 8192,
                                        variants: []
                                    )
                                )
                                newModelID = ""
                                newModelName = ""
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .disabled(newModelID.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 640, height: 560)
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            SecureField("Optional", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
