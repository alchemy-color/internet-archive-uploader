import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = model.settings

        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section("Defaults") {
                    Picker("Default mediatype", selection: $settings.defaultMediatype) {
                        ForEach(Mediatype.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    Toggle("Make file names web-safe", isOn: $settings.sanitizeFileNames)
                    Toggle("Include hidden files", isOn: $settings.includeHiddenFiles)
                    Toggle("Keep a dropped folder's name as a folder in the item", isOn: $settings.keepTopFolder)
                }

                Section("Files already on archive.org") {
                    Picker("When a different file exists at the same path", selection: $settings.existingFilePolicy) {
                        ForEach(ExistingFilePolicy.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Verify identical files with MD5 checksums", isOn: $settings.verifyChecksums)
                    Text("Files are matched by their full path inside the item. Identical files are always skipped.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Uploading") {
                    Stepper(value: Binding(get: { settings.concurrency }, set: { settings.concurrency = $0; model.applyQueueSettings() }), in: 1...8) {
                        LabeledContent("Parallel uploads", value: "\(settings.concurrency)")
                    }
                    Stepper(value: Binding(get: { settings.maxRetries }, set: { settings.maxRetries = $0; model.applyQueueSettings() }), in: 0...8) {
                        LabeledContent("Retries per file", value: "\(settings.maxRetries)")
                    }
                    Toggle("Ask before quitting when nothing is uploading", isOn: $settings.confirmQuitWhenIdle)
                    Toggle("Create derivatives after upload", isOn: $settings.queueDerive)
                    Toggle("Request interactive queue priority", isOn: $settings.interactivePriority)
                    Toggle("Keep previous versions of replaced files", isOn: $settings.keepOldVersions)
                }

                Section("Account") {
                    Toggle("Remember my email address", isOn: $settings.rememberEmail)
                        .onChange(of: settings.rememberEmail) { _, remember in
                            if !remember {
                                model.clearRememberedEmail()
                            }
                        }

                    if let credentials = model.credentials {
                        LabeledContent("Signed in as", value: credentials.displayName)
                        if let email = credentials.email, !email.isEmpty {
                            LabeledContent("Email", value: email)
                        }
                        Button("Sign Out", role: .destructive) {
                            model.signOut()
                            dismiss()
                        }
                    } else {
                        LabeledContent("Status", value: "Not signed in")
                    }
                }

                Section("Recent uploads") {
                    if model.history.records.isEmpty {
                        Text("No uploads yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.history.records) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.title.isEmpty ? record.identifier : record.title).lineLimit(1)
                                Text("\(record.identifier) · \(record.fileCount) file\(record.fileCount == 1 ? "" : "s") · \(ByteCountFormatter.shortString(record.totalBytes)) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                model.openItem(record.identifier)
                                dismiss()
                            } label: { Image(systemName: "archivebox") }
                            .help("Manage this item")
                            Button {
                                model.history.remove([record.id])
                            } label: { Image(systemName: "trash") }
                            .help("Remove from history")
                        }
                        .buttonStyle(.borderless)
                    }
                    if !model.history.records.isEmpty {
                        Button("Clear Upload History", role: .destructive) {
                            model.history.clear()
                        }
                    }
                }

                Section("Hidden items") {
                    let hidden = model.hiddenItems.sorted()
                    if hidden.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(hidden, id: \.self) { id in
                        HStack {
                            Text(id).font(.system(.body, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Button("Show in My Items") { model.unhideItem(id) }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                Section {
                    Button("Reset Settings to Defaults") {
                        model.settings.resetToDefaults()
                    }
                } footer: {
                    Text("Settings are stored locally in your user defaults. Credentials are stored in a user-only file under ~/.config/IAUploader.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 560, height: 680)
    }
}
