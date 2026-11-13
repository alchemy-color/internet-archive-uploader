import SwiftUI

/// The "Archive Entry" column for a new item: everything archive.org needs
/// to create the item page.
struct NewEntryForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                itemCard($model)
                classificationCard($model)
                attributionCard($model)
                customFieldsCard($model)
            }
            .padding(12)
        }
        .task(id: model.metadata.identifier) {
            await model.checkIdentifierAvailability()
        }
    }

    // MARK: Item

    private func itemCard(_ model: Bindable<AppModel>) -> some View {
        Card("Item", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Title", required: true)
                    TextField("A clear, descriptive title", text: model.metadata.title)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .onChange(of: model.wrappedValue.metadata.title) { _, _ in
                            model.wrappedValue.titleDidChange()
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(
                        text: "Identifier",
                        required: true,
                        help: "The permanent tail of the item URL. 5–100 lowercase letters, numbers, periods, underscores, or dashes."
                    )
                    HStack(spacing: 8) {
                        TextField("my-item-identifier", text: model.metadata.identifier)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button {
                            model.wrappedValue.setIdentifierAuto(!model.wrappedValue.identifierAuto)
                        } label: {
                            Image(systemName: model.wrappedValue.identifierAuto ? "lock.open" : "lock")
                        }
                        .buttonStyle(.borderless)
                        .help(model.wrappedValue.identifierAuto ? "Identifier follows the title. Click to lock it." : "Identifier is locked. Click to follow the title again.")
                        .accessibilityLabel("Toggle automatic identifier")
                    }
                    identifierStatus
                    Text("archive.org/details/\(model.wrappedValue.metadata.identifier.isEmpty ? "your-identifier" : model.wrappedValue.metadata.identifier)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Description", required: true)
                    DescriptionEditor(text: model.metadata.descriptionText, minHeight: 130, maxHeight: 320)
                }
            }
        }
    }

    @ViewBuilder
    private var identifierStatus: some View {
        switch model.identifierCheck {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        case .available:
            Label("Available", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .taken:
            Label("Already used", systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .help("Pick another identifier, or open that item from My Items to add files to it.")
        case .invalid(let message):
            Label(message, systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .failed(let message):
            Label("Couldn't check", systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(message)
        }
    }

    // MARK: Attribution

    private func attributionCard(_ model: Bindable<AppModel>) -> some View {
        Card("Creator, date, and license", systemImage: "person.text.rectangle") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Creator", help: "A person, organization, or other entity. Separate multiple creators with semicolons.")
                        TextField("Who made this?", text: model.metadata.creator)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Date", help: "When the content was created. YYYY-MM-DD works best.")
                        HStack(spacing: 6) {
                            TextField("YYYY-MM-DD", text: model.metadata.date)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 130)
                            Button("Today") {
                                model.wrappedValue.metadata.date = ItemMetadata.todayString()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "Language", help: "ISO 639-2/B codes such as eng, spa, or fra. archive.org uses this to pick OCR settings for text items.")
                        HStack(spacing: 6) {
                            TextField("eng", text: model.metadata.language)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 82)
                                .font(.system(.body, design: .monospaced))
                            Menu {
                                ForEach(LanguageCatalog.languages, id: \.code) { language in
                                    Button("\(language.name) (\(language.code))") {
                                        model.wrappedValue.metadata.language = language.code
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            Text(LanguageCatalog.languages.first(where: { $0.code == model.wrappedValue.metadata.language })?.name ?? "Custom code")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "License", help: "Stored in the item's licenseurl field.")
                        HStack(spacing: 6) {
                            TextField("https://creativecommons.org/licenses/…", text: model.metadata.licenseURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                            Menu {
                                Button("No license") { model.wrappedValue.metadata.licenseURL = "" }
                                Divider()
                                ForEach(LicenseCatalog.licenses, id: \.url) { license in
                                    Button(license.name) {
                                        model.wrappedValue.metadata.licenseURL = license.url
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }
        }
    }

    // MARK: Classification

    private func classificationCard(_ model: Bindable<AppModel>) -> some View {
        Card("Classification", systemImage: "square.grid.2x2") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "Mediatype", help: "The mediatype determines how archive.org displays the item and which derivatives are created. It cannot be changed after upload.")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                        ForEach(Mediatype.allCases) { type in
                            mediatypeButton(type, model: model)
                        }
                    }
                    Text(model.wrappedValue.metadata.mediatype.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Collection", help: "The primary collection comes first. Community collections open to everyone: opensource (texts), opensource_audio, opensource_movies, opensource_image, opensource_media (data), open_source_software, etree. Use test_collection to validate an upload.")
                    HStack(spacing: 6) {
                        TextField("opensource", text: Binding(
                            get: { model.wrappedValue.metadata.collections },
                            set: { model.wrappedValue.updateCollections($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.wrappedValue.metadata.isTestItem)

                        Menu {
                            ForEach(CollectionCatalog.suggestions, id: \.id) { collection in
                                Button("\(collection.id) — \(collection.name)") {
                                    model.wrappedValue.updateCollections(collection.id)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(model.wrappedValue.metadata.isTestItem)
                    }
                    Text("Leave blank to let archive.org choose the default collection for this mediatype.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Upload as a test item", isOn: model.metadata.isTestItem)
                        .toggleStyle(.checkbox)
                        .padding(.top, 2)
                    if model.wrappedValue.metadata.isTestItem {
                        InfoBanner(
                            kind: .info,
                            message: "Test items go into test_collection and are removed by archive.org after about 30 days."
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Subjects", required: true, help: "Up to 10 tags. Press Return or comma to add each one.")
                    SubjectsEditor(subjects: model.metadata.subjects)
                }
            }
        }
    }

    private func mediatypeButton(_ type: Mediatype, model: Bindable<AppModel>) -> some View {
        let selected = model.wrappedValue.metadata.mediatype == type
        return Button {
            model.wrappedValue.setMediatype(type)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: type.symbol)
                    .font(.system(size: 15, weight: .medium))
                Text(type.title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .help(type.summary)
    }

    // MARK: Custom fields

    private func customFieldsCard(_ model: Bindable<AppModel>) -> some View {
        Card("Custom metadata", systemImage: "list.bullet.indent", subtitle: "Optional field/value pairs stored in the item's _meta.xml.") {
            VStack(alignment: .leading, spacing: 10) {
                if model.wrappedValue.metadata.customFields.isEmpty {
                    Text("No custom fields. Examples: source, contributor, coverage, rights.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.metadata.customFields) { $field in
                        HStack(spacing: 8) {
                            TextField("field_name", text: $field.key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: 120)
                            TextField("value", text: $field.value)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                model.wrappedValue.removeCustomField(field.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove custom field")
                        }
                    }
                }

                Button {
                    model.wrappedValue.addCustomField()
                } label: {
                    Label("Add Field", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct SubjectsEditor: View {
    @Binding var subjects: [String]
    @Environment(\.undoManager) private var undoManager
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !subjects.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(subjects, id: \.self) { subject in
                        HStack(spacing: 4) {
                            Text(subject)
                                .font(.caption)
                            Button {
                                let previous = subjects
                                let binding = $subjects
                                subjects.removeAll { $0 == subject }
                                registerUndo(previous: previous, binding: binding)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove subject \(subject)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.11), in: Capsule())
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add a subject and press Return", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDraft)
                    .disabled(subjects.count >= 10)
                Button("Add", action: addDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || subjects.count >= 10)
                Text("\(subjects.count)/10")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(subjects.count >= 10 ? .orange : .secondary)
            }
        }
    }

    private func addDraft() {
        let values = ItemMetadata.splitList(draft)
        guard !values.isEmpty else { return }
        let previous = subjects
        let binding = $subjects
        for value in values where !subjects.contains(value) {
            guard subjects.count < 10 else { break }
            subjects.append(value)
        }
        registerUndo(previous: previous, binding: binding)
        draft = ""
    }

    private func registerUndo(previous: [String], binding: Binding<[String]>) {
        guard let undoManager else { return }
        let anchor = UndoAnchor()
        undoManager.registerUndo(withTarget: anchor) { _ in
            binding.wrappedValue = previous
        }
        undoManager.setActionName("Edit Subjects")
    }
}
