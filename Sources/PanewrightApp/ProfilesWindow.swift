import AppKit
import PanewrightCore
import SwiftUI

/// Managing saved configs.
///
/// Profiles used to be a menu submenu that could only switch and save. A saved
/// config you can create but never rename or remove accumulates until the menu
/// is a list of names you no longer recognise, and the only way to clean it up
/// is to find the directory yourself.
@MainActor @Observable
final class ProfilesModel {
    private let appModel: AppModel
    private(set) var names: [String] = []
    var status = ""
    /// The profile being renamed, and the text being typed. Editing in place
    /// rather than in a sheet: the list is the thing you're editing.
    var renaming: String?
    var draftName = ""

    init(appModel: AppModel) {
        self.appModel = appModel
        refresh()
    }

    var active: String? { appModel.activeProfile }

    func refresh() {
        names = appModel.orchestrator.listProfiles()
    }

    func activate(_ name: String) {
        appModel.activateProfile(name)
        status = "Switched to \(name)"
    }

    func saveCurrent() {
        appModel.saveCurrentAsProfile()
        refresh()
    }

    func beginRename(_ name: String) {
        renaming = name
        draftName = name
    }

    func commitRename() {
        guard let old = renaming else { return }
        let new = draftName.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !new.isEmpty, new != old else { return }
        do {
            try appModel.orchestrator.renameProfile(from: old, to: new)
            // The active profile is remembered by name, so it has to follow.
            if appModel.activeProfile == old { appModel.setActiveProfile(new) }
            status = "Renamed to \(new)"
        } catch {
            status = "\(error)"
        }
        refresh()
    }

    func delete(_ name: String) {
        do {
            try appModel.orchestrator.deleteProfile(named: name)
            if appModel.activeProfile == name { appModel.setActiveProfile(nil) }
            status = "Deleted \(name)"
        } catch {
            status = "\(error)"
        }
        refresh()
    }
}

struct ProfilesView: View {
    @Bindable var model: ProfilesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profiles").font(.title2).bold()
                Text("Saved copies of your whole configuration. Switching applies one live.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            Divider()
            if model.names.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("No profiles saved yet.").foregroundStyle(.secondary)
                    Text("“Save Current…” stores your configuration as it is right now.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 420)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.names, id: \.self) { name in
                    HStack(spacing: 10) {
                        Image(systemName: name == model.active ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                name == model.active
                                    ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        if model.renaming == name {
                            TextField("Name", text: $model.draftName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.commitRename() }
                        } else {
                            Text(name).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button("Switch") { model.activate(name) }
                                .disabled(name == model.active)
                            Button("Rename") { model.beginRename(name) }
                            Button(role: .destructive) {
                                model.delete(name)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    Divider().padding(.leading, 22)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Save Current…") { model.saveCurrent() }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }
}

@MainActor
final class ProfilesWindowController {
    private var window: NSWindow?
    private var model: ProfilesModel?

    func show(appModel: AppModel) {
        let model = self.model ?? ProfilesModel(appModel: appModel)
        self.model = model
        // Profiles can be added from elsewhere (the Settings footer), so the
        // list is re-read every time rather than trusted from last time.
        model.refresh()
        if window == nil {
            let hosting = NSHostingController(rootView: ProfilesView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Profiles"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
