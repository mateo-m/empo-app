// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

// MARK: - Picker

struct LayoutProfilePickerSheet: View {
    let container: GameContainer

    @Environment(\.dismiss) private var dismiss
    @State private var pin: LayoutPin = .followChain
    @State private var profiles: [String] = []
    @State private var gameShipsLayout = false
    @State private var automaticResolution = ""
    @State private var searchText = ""

    private var visibleProfiles: [String] {
        LayoutProfilesManager.filtered(profiles, query: searchText)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(
                        label: String(
                            localized: "Automatic",
                            comment: "Layout profile choice that picks a layout on its own."),
                        detail: automaticResolution,
                        target: .followChain
                    )
                    if gameShipsLayout {
                        row(label: gameLayoutLabel, detail: nil, target: .gameLayout)
                    }
                    if LayoutProfilesManager.defaultProfileName != nil {
                        row(label: String(localized: "Default profile"), detail: nil, target: .defaultProfile)
                    }
                } footer: {
                    Text(
                        "Automatic tries the game's own layout, then your default profile, then the Empo default."
                    )
                }

                if !profiles.isEmpty {
                    Section("Profiles") {
                        ForEach(visibleProfiles, id: \.self) { name in
                            row(label: name, detail: nil, target: .profile(name))
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search profiles")
            .navigationTitle("Layout profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetBarButton.done { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: reload)
    }

    private var gameLayoutLabel: String {
        String(localized: "Game layout", comment: "The control layout that a game ships with.")
    }

    private func reload() {
        let store = LayoutProfilesManager.store
        pin = store.loadPin(forGameFolder: container.url).pin
        profiles = store.listProfiles()
        let ambient = LayoutResolution.resolve(
            pin: .followChain,
            gameRoot: container.gameURL,
            store: store,
            defaultProfileName: LayoutProfilesManager.defaultProfileName,
            metrics: .reference)
        // The game layout comes before the default profile in the
        // chain, so the game has a layout exactly when the chain
        // without a pin picks it.
        gameShipsLayout = ambient.provenance == .gameLayout
        switch ambient.provenance {
        case .gameLayout:
            automaticResolution = gameLayoutLabel
        case .defaultProfile(let name):
            automaticResolution = name
        default:
            automaticResolution = String(
                localized: "Empo default", comment: "The control layout that Empo ships with.")
        }
    }

    private func row(label: String, detail: String?, target: LayoutPin) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if pin == target {
                Image(systemName: "checkmark")
                    .foregroundStyle(.brand)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard pin != target else { return }
            do {
                try LayoutProfilesManager.writePin(target, for: container, from: nil)
                pin = target
            } catch {
                NSLog("layout pin: write failed for \(container.id): \(error)")
            }
        }
    }
}

// MARK: - Manager

struct LayoutProfilesSettingsView: View {
    @Environment(\.controlsLayout) private var playerLayout
    @State private var profiles: [String] = []
    @State private var defaultName: String?
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var deleting: String?
    @State private var showCreateDialog = false
    @State private var showNameError = false
    @State private var searchText = ""

    private var visibleProfiles: [String] {
        LayoutProfilesManager.filtered(profiles, query: searchText)
    }

    var body: some View {
        List {
            if profiles.isEmpty {
                Section {
                    Text("No profiles yet. Edit a game's controls, or create a profile here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    NavigationLink {
                        BuiltinLayoutViewerView(keys: playerLayout.gameKeys)
                    } label: {
                        HStack {
                            Text("Empo default")
                            Spacer()
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Built-in profile")
                } footer: {
                    Text("Empo comes with this layout. Games use it when nothing else applies.")
                }
            }

            // The ForEach must be the direct content of one section,
            // so that List makes and compares the rows lazily. Other
            // shapes stutter on a long list.
            if !visibleProfiles.isEmpty {
                Section("Custom profiles") {
                    ForEach(visibleProfiles, id: \.self) { name in
                        profileRow(name)
                    }
                }
            }
        }
        .navigationTitle("Layout profiles")
        .searchable(text: $searchText, prompt: "Search profiles")
        .animation(.default, value: visibleProfiles)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateDialog = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create profile")
            }
        }
        .onAppear(perform: reload)
        .newProfileAlert(isPresented: $showCreateDialog, onCreate: reload)
        .alert("Rename profile", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .profileNameErrorAlert(isPresented: $showNameError)
        .confirmationDialog(
            deleteTitle, isPresented: deleteBinding, titleVisibility: .visible
        ) {
            if deleting == defaultName, profiles.count > 1 {
                ForEach(profiles.filter { $0 != deleting }, id: \.self) { successor in
                    Button("Delete and make \(successor) the default", role: .destructive) {
                        performDelete(successor: successor)
                    }
                }
                Button("Delete and clear default", role: .destructive) {
                    performDelete(successor: nil)
                }
            } else {
                Button("Delete", role: .destructive) {
                    performDelete(successor: nil)
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    private var deleteTitle: Text {
        guard let deleting else { return Text(verbatim: "") }
        let count = LayoutProfilesManager.store.gamesPinned(to: deleting).count
        if count == 0 {
            return Text("Delete \(deleting)? No game uses it. You can't undo this.")
        }
        return Text(
            "Delete \(deleting)? \(count) games use it and will switch to Automatic. You can't undo this.")
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func reload() {
        profiles = LayoutProfilesManager.store.listProfiles()
        defaultName = LayoutProfilesManager.defaultProfileName
    }

    private func profileRow(_ name: String) -> some View {
        NavigationLink {
            LayoutProfileEditorView(profileName: name, keys: playerLayout.gameKeys)
        } label: {
            HStack {
                Text(name)
                Spacer()
                if defaultName == name {
                    Text("Default")
                        .font(.caption)
                        .foregroundStyle(.brand)
                }
            }
        }
        .contextMenu {
            if defaultName != name {
                Button("Set as default") {
                    LayoutProfilesManager.defaultProfileName = name
                    reload()
                }
            } else {
                Button("Clear default") {
                    LayoutProfilesManager.defaultProfileName = nil
                    reload()
                }
            }
            Button("Rename") {
                renameText = name
                renaming = name
            }
            Button("Duplicate") {
                do {
                    _ = try LayoutProfilesManager.store.duplicateProfile(name)
                } catch {
                    NSLog("layout profile: duplicate of \(name) failed: \(error)")
                }
                reload()
            }
            Button("Delete", role: .destructive) {
                deleting = name
            }
        }
    }

    private func performRename() {
        guard let oldName = renaming else { return }
        renaming = nil
        do {
            if try LayoutProfilesManager.renameProfile(oldName, toRawName: renameText) == nil {
                showNameError = true
            }
        } catch {
            showNameError = true
        }
        reload()
    }

    private func performDelete(successor: String?) {
        guard let name = deleting else { return }
        deleting = nil
        do {
            try LayoutProfilesManager.deleteProfile(name)
            if let successor {
                LayoutProfilesManager.defaultProfileName = successor
            }
        } catch {
            NSLog("layout profile: delete of \(name) failed: \(error)")
        }
        reload()
    }
}

// MARK: - Canvas geometry

enum EditorCanvas {
    static func size(for orientation: ControlsOrientation) -> CGSize {
        let metrics = TouchZoneMetrics.reference
        let isLandscape = orientation == .landscape
        return CGSize(
            width: metrics.width(isLandscape: isLandscape),
            height: metrics.height(isLandscape: isLandscape))
    }

    /// The window safe area, not the zone insets of the metrics. The
    /// zone insets already hold the game height and the toolbar line,
    /// and a second copy of them empties the clamp band.
    static func safeArea(for orientation: ControlsOrientation) -> EdgeInsets {
        let insets = TouchZoneMetrics.referenceWindowInsets(isLandscape: orientation == .landscape)
        return EdgeInsets(
            top: insets.top, leading: insets.leading, bottom: insets.bottom,
            trailing: insets.trailing)
    }

    static func fakeGameRect(for orientation: ControlsOrientation) -> CGRect {
        let size = size(for: orientation)
        let top = orientation == .portrait ? safeArea(for: orientation).top : 0
        let game = GameAspect.fit(width: size.width, height: size.height - top)
        return CGRect(x: (size.width - game.width) / 2, y: top, width: game.width, height: game.height)
    }

    static func gameRect(in rect: CGRect) -> CGRect {
        let game = GameAspect.fit(width: rect.width, height: rect.height)
        return CGRect(
            x: rect.midX - game.width / 2, y: rect.midY - game.height / 2,
            width: game.width, height: game.height)
    }
}

// MARK: - Editor

/// The editor has its own `ControlsLayout`, because
/// `ControlsLayout.shared` can belong to a paused game.
struct LayoutProfileEditorView: View {
    let profileName: String

    @State private var currentName: String
    @State private var renameText = ""
    @State private var showRename = false
    @State private var showRenameError = false
    @State private var diskScreen: ScreenRegionFile.ReadResult?
    @State private var layout: ControlsLayout
    @State private var actions = PlayerActionRegistry()
    @State private var editingOrientation: ControlsOrientation = .portrait
    @State private var editDialog: ControlsEditDialog?
    @State private var showSaveFailure = false
    @State private var savedOnLeave = false
    @Environment(\.dismiss) private var dismiss

    init(profileName: String, keys: [GameKey]) {
        self.profileName = profileName
        _currentName = State(initialValue: profileName)
        _layout = State(
            initialValue: ControlsLayout(
                editorForProfile: profileName, metrics: .reference, keys: keys))
    }

    private var canvas: ScreenCanvas {
        ScreenCanvas(
            size: EditorCanvas.size(for: editingOrientation),
            safeArea: EditorCanvas.safeArea(for: editingOrientation))
    }
    private var fakeGameRect: CGRect { EditorCanvas.fakeGameRect(for: editingOrientation) }

    private var screenPlacement: ScreenPlacement? {
        layout.effectiveScreenPlacement(
            stored: editingOrientation == .portrait ? diskScreen?.portrait : diskScreen?.landscape)
    }

    private var screenRegion: ScreenRegion? {
        screenPlacement.flatMap { canvas.region(for: $0, aspect: GameAspect.typical) }
    }

    private var screenRegionRect: CGRect? {
        screenRegion.map { canvas.rect(for: $0) }
    }

    private var placeholderGameRect: CGRect {
        screenRegionRect.map(EditorCanvas.gameRect(in:)) ?? fakeGameRect
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            EditorOrientationPicker(selection: $editingOrientation)
                .onChange(of: editingOrientation) { _, new in
                    try? layout.editorSave()
                    layout.setOrientation(new)
                    diskScreen = LayoutProfilesManager.store.readScreen(currentName)
                }

            EditorCanvasShell(
                layout: layout,
                actions: actions,
                orientation: editingOrientation,
                editMode: true,
                placeholderRect: placeholderGameRect,
                forcedOverlay: screenRegion?.overlay,
                editDialog: $editDialog
            ) { _, gameRect in
                screenGizmoLayers(gameRect: gameRect)
            }

            HStack(spacing: Spacing.xl) {
                Button("Add button") { editDialog = .addButton }
                Button {
                    layout.undoLastEdit()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!layout.canUndo)
                if editingOrientation == .portrait {
                    positionMenu
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.bottom, Spacing.md)
        }
        .navigationTitle(currentName)
        .navigationBarTitleDisplayMode(.inline)
        // Back saves first, so a failed save keeps the editor open.
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: leave) {
                    Image(systemName: "chevron.backward")
                }
                .tint(.primary)
                .accessibilityLabel("Back")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    renameText = currentName
                    showRename = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Rename profile")
            }
        }
        .alert("Rename profile", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) {}
        }
        .profileNameErrorAlert(isPresented: $showRenameError)
        .layoutSaveFailureAlert(isPresented: $showSaveFailure)
        .onAppear {
            layout.setOrientation(editingOrientation)
            layout.beginEditSession()
            diskScreen = LayoutProfilesManager.store.readScreen(currentName)
        }
        .onDisappear {
            layout.endEditSession()
            // A close of the whole sheet skips Back.
            if !savedOnLeave {
                try? layout.editorSave()
            }
        }
        .controlsEditDialogs(
            layout: layout,
            // The editor's registry has no game, so it reports fast
            // forward as off.
            actions: nil,
            dialog: $editDialog
        )
    }

    private func leave() {
        do {
            try layout.editorSave()
        } catch {
            showSaveFailure = true
            return
        }
        savedOnLeave = true
        dismiss()
    }

    private enum PositionChoice: Hashable {
        case automatic
        case preset(ScreenPreset)
        case custom
    }

    private var positionChoice: PositionChoice {
        switch screenPlacement {
        case nil: return .automatic
        case .preset(let preset): return .preset(preset)
        case .region: return .custom
        }
    }

    private var positionMenu: some View {
        Menu {
            Picker(
                "Screen position",
                selection: Binding(
                    get: { positionChoice },
                    set: { choice in
                        withAnimation(ScreenRegionGizmo.moveAnimation) {
                            switch choice {
                            case .automatic:
                                layout.resetScreenEdit()
                            case .preset(let preset):
                                layout.recordScreenEdit(.preset(preset))
                            case .custom:
                                break
                            }
                        }
                    })
            ) {
                Text("Automatic").tag(PositionChoice.automatic)
                Text("Top").tag(PositionChoice.preset(.top))
                Text("Top-center").tag(PositionChoice.preset(.topCenter))
                Text("Center").tag(PositionChoice.preset(.center))
                if positionChoice == .custom {
                    Text("Custom").tag(PositionChoice.custom)
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text("Screen position")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
        }
    }

    private func performRename() {
        do {
            guard
                let newName = try LayoutProfilesManager.renameProfile(
                    currentName, toRawName: renameText)
            else { return }
            currentName = newName
            layout.editorRenamed(to: newName)
        } catch {
            showRenameError = true
        }
    }

    /// These layers must stay below the controls overlay. Above it,
    /// the move surface takes drags from controls inside the region.
    @ViewBuilder
    private func screenGizmoLayers(gameRect: CGRect) -> some View {
        ScreenRegionGizmo(
            canvas: canvas,
            allowedRect: layout.screenDragAllowedRect(
                in: canvas, overlayOn: screenRegion?.overlay ?? false),
            baseRect: screenRegionRect ?? gameRect,
            onDragBegan: {
                layout.beginScreenDrag(
                    autoReference: screenPlacement == nil
                        ? canvas.region(for: fakeGameRect)
                        : nil)
            },
            onDragChanged: { region in
                layout.screenDragChanged(region)
            },
            onDragEnded: { region in
                layout.endScreenDrag(region: region)
            },
            // The flag must ride through editor drags too, or a
            // one-point nudge in the editor silently strips
            // "overlay": true from the profile.
            overlayOn: screenRegion?.overlay ?? false
        )

        ScreenRegionChips(
            rect: screenRegionRect ?? gameRect,
            showsReset: screenPlacement != nil,
            onReset: {
                // The mock canvas has no engine: the SwiftUI
                // animation on the placeholder IS the reset
                // animation.
                withAnimation(ScreenRegionGizmo.moveAnimation) {
                    layout.resetScreenEdit()
                }
            }
        )
    }
}

// MARK: - Shared canvas shell

struct EditorCanvasShell<UnderControls: View>: View {
    var layout: ControlsLayout
    var actions: PlayerActionRegistry
    let orientation: ControlsOrientation
    let editMode: Bool
    var placeholderRect: CGRect?
    var forcedOverlay: Bool?
    var editDialog: Binding<ControlsEditDialog?> = .constant(nil)
    var hitTesting = true
    @ViewBuilder let underControls: (CGSize, CGRect) -> UnderControls

    var body: some View {
        GeometryReader { outer in
            let size = EditorCanvas.size(for: orientation)
            let scale = min(
                outer.size.width / size.width, outer.size.height / size.height)
            canvas(size: size)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .frame(width: size.width * scale, height: size.height * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func canvas(size: CGSize) -> some View {
        let safeArea = EditorCanvas.safeArea(for: orientation)
        let gameRect = placeholderRect ?? EditorCanvas.fakeGameRect(for: orientation)
        let controlsMinY = ControlsZone.toolbarBottomY(
            isPortrait: orientation == .portrait,
            gameRect: gameRect,
            safeArea: safeArea,
            btnSize: IconButtonSize.sm.points,
            geoHeight: size.height,
            forcedOverlay: forcedOverlay)

        return ZStack {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Color.black)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Text("Game screen")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.3))
                )
                .frame(width: gameRect.width, height: gameRect.height)
                .position(x: gameRect.midX, y: gameRect.midY)

            underControls(size, gameRect)

            GeometryReader { geo in
                PlayerControlsOverlay(
                    layout: layout,
                    actions: actions,
                    geo: geo,
                    controlsMinY: controlsMinY,
                    editMode: editMode,
                    safeArea: safeArea,
                    isPreview: true,
                    editDialog: editDialog
                )
            }
            .allowsHitTesting(hitTesting)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
}

struct EditorOrientationPicker: View {
    @Binding var selection: ControlsOrientation

    var body: some View {
        Picker("Orientation", selection: $selection) {
            Text("Portrait").tag(ControlsOrientation.portrait)
            Text("Landscape").tag(ControlsOrientation.landscape)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Spacing.xl)
    }
}

private struct NewProfileAlert: ViewModifier {
    @Binding var isPresented: Bool
    let onCreate: () -> Void

    @Environment(\.controlsLayout) private var playerLayout
    @State private var name = ""
    @State private var showNameError = false
    @State private var showSaveFailure = false

    func body(content: Content) -> some View {
        content
            .alert("New profile", isPresented: $isPresented) {
                TextField("Name", text: $name)
                Button("Create", action: create)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A new profile starts from the Empo default layout.")
            }
            .profileNameErrorAlert(isPresented: $showNameError)
            .layoutSaveFailureAlert(isPresented: $showSaveFailure)
            .onChange(of: isPresented) { _, presented in
                guard presented else { return }
                name = LayoutProfilesManager.store.uniqueName(
                    base: String(localized: "My layout", comment: "Name of a new layout profile."))
            }
    }

    private func create() {
        do {
            try LayoutProfilesManager.createProfileFromBuiltins(rawName: name, keys: playerLayout.gameKeys)
            onCreate()
        } catch is LayoutProfileStore.StoreError {
            showNameError = true
        } catch {
            NSLog("layout profile: create of \(name) failed: \(error)")
            showSaveFailure = true
        }
    }
}

extension View {
    func newProfileAlert(isPresented: Binding<Bool>, onCreate: @escaping () -> Void) -> some View {
        modifier(NewProfileAlert(isPresented: isPresented, onCreate: onCreate))
    }

    func profileNameErrorAlert(isPresented: Binding<Bool>) -> some View {
        alert("Pick a different name", isPresented: isPresented) {
            Button("Got it") {}
        } message: {
            Text(
                "That name is taken or uses characters Empo can't save. Try letters, numbers and spaces."
            )
        }
    }

    func layoutSaveFailureAlert(isPresented: Binding<Bool>) -> some View {
        alert("Couldn't save your layout. Free up some space and try again.", isPresented: isPresented) {
            Button("Got it") {}
        }
    }
}

// MARK: - Built-in viewer

struct BuiltinLayoutViewerView: View {
    @State private var layout: ControlsLayout
    @State private var actions = PlayerActionRegistry()
    @State private var orientation: ControlsOrientation = .portrait
    @State private var showCreateDialog = false

    init(keys: [GameKey]) {
        _layout = State(initialValue: ControlsLayout(viewerForBuiltins: .reference, keys: keys))
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            EditorOrientationPicker(selection: $orientation)
                .onChange(of: orientation) { _, new in
                    layout.setOrientation(new)
                }

            EditorCanvasShell(
                layout: layout,
                actions: actions,
                orientation: orientation,
                editMode: false,
                hitTesting: false
            ) { _, _ in
                EmptyView()
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Empo comes with this layout. Games use it when nothing else applies.")
                Text(
                    "This layout is read-only. To make your own, duplicate it and edit the copy."
                )
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.xl)

            Button("Duplicate as profile") {
                showCreateDialog = true
            }
            .font(.footnote.weight(.semibold))
            .padding(.bottom, Spacing.md)
        }
        .navigationTitle("Empo default")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            layout.setOrientation(orientation)
        }
        .newProfileAlert(isPresented: $showCreateDialog, onCreate: {})
    }
}
