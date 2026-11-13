import SwiftUI

struct RootView: View {
    let model: AppModel
    let undoManager: UndoManager

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                // One status strip for the one queue, visible everywhere.
                QueueStatusBar()
                if model.accountState == .signedIn {
                    WorkspaceView()
                        .environment(\.memoryScope, model.route == .newItem ? "new" : "item")
                } else {
                    LoginView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .environment(model)
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environment(model)
        }
        .sheet(isPresented: $model.showActivityLog) {
            ActivityLogView()
                .environment(model)
                .frame(width: 720, height: 460)
        }
        .alert(item: $model.banner) { banner in
            Alert(title: Text(alertTitle(for: banner.kind)), message: Text(banner.message), dismissButton: .default(Text("OK")))
        }
        .task {
            model.undoManager = undoManager
            if model.accountState == .signedIn {
                await model.loadMyUploads()
                if let id = model.route.identifier { model.openItem(id) }
            }
        }
        .onDisappear { model.saveState() }
    }

    private func alertTitle(for kind: AppModel.Banner.Kind) -> String {
        switch kind {
        case .info: return "Information"
        case .warning: return "Warning"
        case .error: return "Something went wrong"
        case .success: return "Done"
        }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    /// Several items can be selected (⌘/⇧-click) for deleting or hiding.
    /// A single selection opens that item.
    @State private var selection: Set<AppModel.Route> = []
    @State private var confirmDelete: [String] = []

    var body: some View {
        list
            .searchable(text: $search, placement: .sidebar, prompt: "Find an item")
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .navigationTitle("Archive")
            .confirmationDialog(confirmTitle, isPresented: confirmBinding) {
                Button(confirmDelete.count == 1 ? "Delete" : "Delete \(confirmDelete.count) Items", role: .destructive) {
                    model.deleteItems(confirmDelete)
                    selection = [model.route]
                    confirmDelete = []
                }
                Button("Cancel", role: .cancel) { confirmDelete = [] }
            } message: {
                Text("All files are permanently deleted from archive.org. This runs in the background. archive.org keeps an empty item page; test_collection items disappear by themselves after about 30 days.")
            }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            DeletionsPanel()
            SidebarFooter()
        }
    }

    private var confirmTitle: String {
        confirmDelete.count == 1 ? "Delete “\(confirmDelete.first ?? "")”?" : "Delete \(confirmDelete.count) items?"
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { !confirmDelete.isEmpty }, set: { if !$0 { confirmDelete = [] } })
    }

    private func navigate(to newValue: Set<AppModel.Route>) {
        guard newValue.count == 1, let route = newValue.first, route != model.route else { return }
        switch route {
        case .newItem: model.startNewItem()
        case .item(let id): model.openItem(id)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            Section {
                newItemRow.tag(AppModel.Route.newItem)
            }
            Section {
                ForEach(filteredItems, id: \.identifier) { item in
                    itemRow(item).tag(AppModel.Route.item(item.identifier))
                }
                if model.sidebarItems.isEmpty && !model.isLoadingMyUploads && model.accountState == .signedIn {
                    Text("No items yet").foregroundStyle(.secondary)
                }
            } header: {
                itemsHeader
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: AppModel.Route.self) { routes in
            itemMenu(routes.compactMap(\.identifier))
        }
        .onDeleteCommand {
            let ids = selection.compactMap(\.identifier)
            if !ids.isEmpty { confirmDelete = ids }
        }
        .onChange(of: selection) { _, newValue in navigate(to: newValue) }
        .onChange(of: model.route, initial: true) { _, route in
            if !selection.contains(route) || selection.count == 1 { selection = [route] }
        }
    }

    private var itemsHeader: some View {
        HStack {
            Text("My Items")
            Spacer()
            if model.isLoadingMyUploads {
                ProgressView().controlSize(.mini)
            } else {
                Button { Task { await model.loadMyUploads() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload your items from archive.org")
            }
        }
    }

    private var filteredItems: [RemoteItem] {
        let items = model.sidebarItems
        guard !search.isEmpty else { return items }
        return items.filter { $0.identifier.localizedCaseInsensitiveContains(search) || ($0.title ?? "").localizedCaseInsensitiveContains(search) }
    }

    private var newItemRow: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text("New Item").font(UIScale.font(14, .semibold))
                Text(model.files.isEmpty ? "Create an archive.org item" : "\(model.files.count) files ready")
                    .font(UIScale.font(11)).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "plus.square.fill").font(UIScale.font(18)).foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 3)
    }

    private func itemRow(_ item: RemoteItem) -> some View {
        let pending = model.queue.jobs.filter { $0.identifier == item.identifier && $0.status != .done }
        let failed = pending.contains { $0.status == .failed }
        return HStack(spacing: 8) {
            Image(systemName: "archivebox").font(UIScale.font(15)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? item.identifier).font(UIScale.font(13)).lineLimit(1)
                Text(item.identifier).font(UIScale.font(10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, UIScale.size(2))
            Spacer(minLength: 2)
            if model.linkedFolders[item.identifier] != nil {
                Image(systemName: "link").font(UIScale.font(10)).foregroundStyle(.secondary)
                    .help("Linked to a Finder folder")
            }
            if !pending.isEmpty {
                Text("\(pending.count)")
                    .font(UIScale.font(10, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(failed ? Color.orange : Color.accentColor, in: Capsule())
                    .help("\(pending.count) upload(s) not finished")
            }
        }
    }

    @ViewBuilder
    private func itemMenu(_ ids: [String]) -> some View {
        if ids.count == 1, let id = ids.first {
            Button("Open on archive.org") {
                if let url = URL(string: "https://archive.org/details/\(id)") { FilePicker.open(url) }
            }
            Button("Copy Identifier") { FilePicker.copyToPasteboard(id) }
            if model.linkedFolders[id] != nil {
                Divider()
                Button("Unlink Finder Folder") { model.linkedFolders[id] = nil }
            }
            Divider()
        }
        if !ids.isEmpty {
            Button(ids.count == 1 ? "Hide from My Items" : "Hide \(ids.count) Items") { ids.forEach(model.hideItem) }
            Button(ids.count == 1 ? "Delete Item…" : "Delete \(ids.count) Items…", role: .destructive) { confirmDelete = ids }
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 9) {
                if model.accountState == .signedIn, let credentials = model.credentials {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 26, height: 26)
                        .overlay(Text(initials(for: credentials)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(credentials.displayName).font(UIScale.font(11.5, .medium)).lineLimit(1)
                        Text(credentials.isS3Only ? "S3 keys" : "archive.org").font(UIScale.font(9.5)).foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "person.crop.circle.dashed").font(.system(size: 20)).foregroundStyle(.tertiary)
                    Text("Not signed in").font(UIScale.font(11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { model.showSettings = true } label: { Image(systemName: "gearshape").font(UIScale.font(13)) }
                    .buttonStyle(.borderless)
                    .help("Settings and account")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }

    private func initials(for credentials: ArchiveCredentials) -> String {
        let source = credentials.screenName ?? credentials.email ?? "IA"
        let parts = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
        let letters = parts.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "IA" : String(letters).uppercased()
    }
}

/// Background item deletions, at the bottom of the sidebar.
private struct DeletionsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.itemDeletions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Label("Deleting", systemImage: "trash").font(UIScale.font(11, .semibold)).foregroundStyle(.secondary)
                // Iterate over a snapshot of (id, progress) pairs: a deletion can
                // finish (and leave the dictionary) while this row redraws.
                ForEach(model.itemDeletions.sorted { $0.key < $1.key }, id: \.key) { id, op in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(id).font(UIScale.font(11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        if op.total > 0 {
                            ProgressView(value: Double(op.done), total: Double(op.total))
                                .controlSize(.small)
                            Text(op.detail ?? "\(op.done) of \(op.total) files").font(UIScale.font(10)).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }
}

