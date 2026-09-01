import SwiftUI

struct ReaderSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ReadingAppearanceSettings()
                .environmentObject(model)
                .tabItem { Label("阅读", systemImage: "textformat.size") }

            ProviderSettings()
                .environmentObject(model)
                .tabItem { Label("模型", systemImage: "sparkles") }
        }
        .frame(width: 680, height: 500)
    }
}

private struct ReadingAppearanceSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("阅读主题") {
                Picker("主题", selection: $model.preferences.theme) {
                    ForEach(ReaderThemePreference.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("排版") {
                LabeledContent("字号 \(Int(model.preferences.fontSize)) pt") {
                    Slider(value: $model.preferences.fontSize, in: 12...30, step: 1)
                        .frame(width: 300)
                }
                LabeledContent("行宽 \(Int(model.preferences.lineWidth)) pt") {
                    Slider(value: $model.preferences.lineWidth, in: 480...1100, step: 20)
                        .frame(width: 300)
                }
                LabeledContent("行距 \(Int(model.preferences.lineSpacing)) pt") {
                    Slider(value: $model.preferences.lineSpacing, in: 0...18, step: 1)
                        .frame(width: 300)
                }
            }

            Section("PDF") {
                LabeledContent("默认缩放 \(Int(model.preferences.pdfScale * 100))%") {
                    Slider(value: $model.preferences.pdfScale, in: 0.5...2.5, step: 0.05)
                        .frame(width: 300)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ProviderSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectionID: String?
    @State private var displayName = ""
    @State private var kind: ProviderKind = .appleOnDevice
    @State private var endpoint = ""
    @State private var modelID = ""
    @State private var secret = ""
    @State private var isDefault = true
    @State private var contextWindow = 32_000
    @State private var timeoutSeconds = 120.0
    @State private var draftID = UUID().uuidString.lowercased()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectionID) {
                    ForEach(model.providerProfiles) { profile in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                            Text("\(profile.kind.displayName) · \(profile.modelID)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(profile.id)
                    }
                }
                Divider()
                Button {
                    resetDraft()
                } label: {
                    Label("新建 Provider", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .buttonStyle(.plain)
            }
            .frame(minWidth: 190, idealWidth: 220)

            Form {
                Section("Provider Profile") {
                    TextField("名称", text: $displayName)
                    Picker("类型", selection: $kind) {
                        ForEach(ProviderKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    TextField("Model ID", text: $modelID)
                    if kind != .appleOnDevice {
                        TextField("Endpoint（留空使用默认值）", text: $endpoint)
                    }
                    if kind.requiresSecret {
                        SecureField(existingProfile?.keychainReference == nil
                                    ? "API Key"
                                    : "API Key（留空保持不变）", text: $secret)
                    }
                    Toggle("设为全局默认", isOn: $isDefault)
                }

                Section("运行边界") {
                    Stepper(
                        "上下文窗口 \(contextWindow.formatted()) tokens",
                        value: $contextWindow,
                        in: 8_000...1_000_000,
                        step: 8_000
                    )
                    Stepper(
                        "超时 \(Int(timeoutSeconds)) 秒",
                        value: $timeoutSeconds,
                        in: 10...600,
                        step: 10
                    )
                }

                Section {
                    HStack {
                        Button("连接与工具能力测试") {
                            model.testProvider(draftProfile, secret: secret)
                        }
                        .disabled(!isDraftValid || model.providerTestInFlightID != nil)
                        if model.providerTestInFlightID != nil {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if let result = model.providerTestResult,
                           result.profileID == draftProfile.id {
                            Label(
                                result.succeeded ? "通过" : "失败：\(result.category)",
                                systemImage: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(result.succeeded ? ReaderTheme.teal : .red)
                        }
                        Spacer()
                        Button("保存") {
                            model.saveProviderProfile(draftProfile, secret: secret)
                            secret = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDraftValid)
                    }
                }

                Section {
                    Text("API Key 只写入 macOS Keychain。数据库与日志只保存引用；真实模型调用不会出现在 CI 中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 430)
        }
        .onAppear {
            selectionID = model.providerProfiles.first?.id
            loadSelection()
        }
        .onChange(of: selectionID) { _, _ in loadSelection() }
    }

    private var existingProfile: ProviderProfile? {
        guard let selectionID else { return nil }
        return model.providerProfiles.first { $0.id == selectionID }
    }

    private var draftProfile: ProviderProfile {
        ProviderProfile(
            id: existingProfile?.id ?? draftID,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
            modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            keychainReference: existingProfile?.keychainReference,
            isDefault: isDefault,
            contextWindow: contextWindow,
            timeoutSeconds: timeoutSeconds,
            capabilities: existingProfile?.capabilities ?? [],
            lastTestedAt: existingProfile?.lastTestedAt,
            lastTestSucceeded: existingProfile?.lastTestSucceeded,
            createdAt: existingProfile?.createdAt ?? .now,
            updatedAt: .now
        )
    }

    private var isDraftValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!kind.requiresSecret
                || !secret.isEmpty
                || existingProfile?.keychainReference != nil)
            && (endpoint.isEmpty || URL(string: endpoint) != nil)
    }

    private func loadSelection() {
        guard let profile = existingProfile else {
            resetDraft()
            return
        }
        displayName = profile.displayName
        kind = profile.kind
        endpoint = profile.endpoint?.absoluteString ?? ""
        modelID = profile.modelID
        secret = ""
        isDefault = profile.isDefault
        contextWindow = profile.contextWindow ?? 32_000
        timeoutSeconds = profile.timeoutSeconds
    }

    private func resetDraft() {
        draftID = UUID().uuidString.lowercased()
        selectionID = nil
        displayName = ""
        kind = .appleOnDevice
        endpoint = ""
        modelID = ""
        secret = ""
        isDefault = model.providerProfiles.isEmpty
        contextWindow = 32_000
        timeoutSeconds = 120
    }
}

private extension ProviderKind {
    var displayName: String {
        switch self {
        case .appleOnDevice: "Apple On-device"
        case .openAIResponses: "OpenAI Responses"
        case .anthropicMessages: "Anthropic Messages"
        case .ollama: "Ollama"
        }
    }
}
