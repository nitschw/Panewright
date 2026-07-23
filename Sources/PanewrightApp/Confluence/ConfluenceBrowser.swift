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
    }

    var isConfigured: Bool {
        provider?.isConfigured ?? false
    }

    /// Debounced so typing doesn't fire a request per keystroke.
    func searchDebounced() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    func search() async {
        guard let provider else { return }
        isLoading = true
        error = nil
        do {
            results = try await provider.search(query)
        } catch {
            self.error = "\(error)"
            results = []
        }
        isLoading = false
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

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            article
                .frame(minWidth: 460)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
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
            .padding(10)

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
                    if !page.space.isEmpty {
                        Text(page.space)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                    ArticleWebView(pageID: page.id, html: page.html)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("Search, or pick a favorite.")
                    .foregroundStyle(.secondary)
                Text("Headings collapse on click — your place is kept per article.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
final class ConfluenceWindowController {
    private var window: NSWindow?
    let model = ConfluenceModel()

    func show(host: String, email: String) {
        model.configure(host: host, email: email)
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
