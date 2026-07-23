import AppKit
import PanewrightCore
import SwiftUI

@MainActor @Observable
final class ConfluenceModel {
    var query = ""
    var results: [ConfluencePage] = []
    var favorites: [ConfluencePage] = []
    var selected: ConfluencePage?
    var isLoading = false
    var error: String?

    private var provider: ConfluenceProvider?
    private let favoritesURL = ConfluenceFavorites.defaultURL()
    private var searchTask: Task<Void, Never>?

    init() {
        favorites = ConfluenceFavorites.load(from: favoritesURL)
    }

    func configure(host: String, email: String) {
        provider = ConfluenceProvider(host: host, email: email)
        hasHost = !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isConfigured: Bool {
        provider?.isConfigured ?? false
    }

    private(set) var hasHost = false

    var siteHost: String { provider?.siteHost ?? "" }
    var authorizationHeader: String? { provider?.authorizationHeader() }

    /// Debounced so typing doesn't fire a request per keystroke.
    func searchDebounced() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    var scope: ConfluenceProvider.SearchScope = .all {
        didSet { searchDebounced() }
    }

    func search() async {
        guard let provider, provider.isConfigured else { return }
        isLoading = true
        error = nil
        do {
            results = try await provider.search(query, scope: scope)
        } catch {
            self.error = "\(error)"
            results = []
        }
        isLoading = false
    }

    /// Deep link: open a page by ID even if it isn't in the current list.
    func openPage(id: String) {
        guard let provider else { return }
        Task { @MainActor in
            do {
                selected = try await provider.page(id: id)
            } catch {
                self.error = "\(error)"
            }
        }
    }

    func open(_ page: ConfluencePage) {
        guard let provider else { return }
        selected = page
        Task { @MainActor in
            do {
                let full = try await provider.page(id: page.id)
                if selected?.id == full.id {
                    selected = full
                }
            } catch {
                self.error = "\(error)"
            }
        }
    }

    func isFavorite(_ page: ConfluencePage) -> Bool {
        favorites.contains { $0.id == page.id }
    }

    func toggleFavorite(_ page: ConfluencePage) {
        if let index = favorites.firstIndex(where: { $0.id == page.id }) {
            favorites.remove(at: index)
        } else {
            // Store metadata only; bodies are always fetched fresh.
            favorites.append(
                ConfluencePage(
                    id: page.id, title: page.title, space: page.space, url: page.url))
        }
        try? ConfluenceFavorites.save(favorites, to: favoritesURL)
    }
}

struct ConfluenceBrowserView: View {
    @Bindable var model: ConfluenceModel
    @State private var selection: ConfluencePage.ID?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            article
                .frame(minWidth: 460)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    /// Missing host or token is a setup problem, not an error — say so, and
    /// offer the fix inline.
    private var setupNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Confluence isn't set up yet", systemImage: "gearshape")
                .font(.callout.weight(.medium))
            Text(
                model.hasHost
                    ? "Add an Atlassian API token to start searching."
                    : "Set your site host (and email) in Open Editor… → Integrations, then add a token."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Add Confluence token…") {
                TokenPrompt.ask(service: "confluence", displayName: "Confluence") {
                    Task { await model.search() }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .padding(10)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if !model.isConfigured {
                setupNotice
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Confluence", text: $model.query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.search() } }
                    .onChange(of: model.query) { model.searchDebounced() }
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Picker("", selection: $model.scope) {
                ForEach(ConfluenceProvider.SearchScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            List {
                if !model.favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(model.favorites) { page in
                            row(page)
                        }
                    }
                }
                Section(model.query.isEmpty ? "Recently updated" : "Results") {
                    if let error = model.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.results) { page in
                        row(page)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .task {
            if model.results.isEmpty { await model.search() }
        }
    }

    private func row(_ page: ConfluencePage) -> some View {
        Button {
            model.open(page)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    let meta = [page.space, page.lastEditor]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if model.isFavorite(page) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            model.selected?.id == page.id ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    @ViewBuilder
    private var article: some View {
        if let page = model.selected {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(page.title).font(.headline).lineLimit(1)
                        if !page.space.isEmpty {
                            Text(page.space).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        model.selected = nil
                    } label: {
                        Label("Activity", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to recent activity")
                    Button {
                        model.toggleFavorite(page)
                    } label: {
                        Image(
                            systemName: model.isFavorite(page) ? "star.fill" : "star"
                        )
                        .foregroundStyle(model.isFavorite(page) ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Favorite")
                    Button {
                        NSWorkspace.shared.open(page.url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Open in browser")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                if page.html.isEmpty {
                    VStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    ArticleWebView(
                        pageID: page.id,
                        html: page.html,
                        host: model.siteHost,
                        authorization: model.authorizationHeader)
                }
            }
        } else {
            activityHome
        }
    }

    /// Home view: who's been editing what, most recent first.
    private var activityHome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recent activity").font(.headline)
                    Text("What your workspace has been working on")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.search() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if !model.isConfigured {
                Text("Set up Confluence to see activity.")
                    .foregroundStyle(.secondary)
                    .padding(16)
                Spacer()
            } else if model.results.isEmpty {
                if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Nothing recent found.")
                        .foregroundStyle(.secondary)
                        .padding(16)
                    Spacer()
                }
            } else {
                Table(model.results, selection: $selection) {
                    TableColumn("Title") { page in
                        Text(page.title).lineLimit(1)
                    }
                    .width(min: 180, ideal: 280)
                    TableColumn("Space") { page in
                        Text(page.space).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .width(min: 80, ideal: 120)
                    TableColumn("Last edited by") { page in
                        Text(page.lastEditor).lineLimit(1)
                    }
                    .width(min: 100, ideal: 150)
                    TableColumn("Updated") { page in
                        Text(Self.relative(page.updated)).foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 110)
                    TableColumn("Created") { page in
                        Text(Self.absolute(page.created)).foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)
                }
                .onChange(of: selection) {
                    if let id = selection,
                        let page = model.results.first(where: { $0.id == id }) {
                        model.open(page)
                        selection = nil
                    }
                }
            }
        }
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.relative(presentation: .numeric))
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

@MainActor
final class ConfluenceWindowController {
    private var window: NSWindow?
    let model = ConfluenceModel()

    func show(host: String, email: String, pageID: String? = nil) {
        model.configure(host: host, email: email)
        if let pageID {
            model.openPage(id: pageID)
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosted = NSWindow(
            contentViewController: NSHostingController(
                rootView: ConfluenceBrowserView(model: model)))
        hosted.title = "Confluence"
        hosted.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        hosted.setContentSize(NSSize(width: 1020, height: 680))
        hosted.isReleasedWhenClosed = false
        hosted.center()
        hosted.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = hosted
    }
}
