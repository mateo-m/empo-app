import GameProbe
import SwiftUI

// MARK: - Picker

/// Pin picker for one game, shared by Game Settings and the in-player
/// More sheet. Rows map 1:1 onto the stored pin states, and the
/// "Automatic" row names what the chain resolves to today.
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
                    row(label: "Automatic", detail: automaticResolution, target: .followChain)
                    if gameShipsLayout {
                        row(label: "Game layout", detail: nil, target: .gameLayout)
                    }
                    if LayoutProfilesManager.defaultProfileName != nil {
                        row(label: "Default profile", detail: nil, target: .defaultProfile)
                    }
                } footer: {
                    Text(
                        "Automatic uses the game's own layout first. No layout? Your default profile. No default? Empo's built-in one."
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
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: reload)
    }

    private func reload() {
        let store = LayoutProfilesManager.store
        pin = store.loadPin(forGameFolder: container.url).pin
        profiles = store.listProfiles()
        // What Automatic yields, ignoring any pin. The SAME
        // resolver entry as the bound layout, so the row cannot
        // drift from what the player does.
        let ambient = LayoutResolution.resolve(
            pin: .followChain,
            gameRoot: container.gameURL,
            store: store,
            defaultProfileName: LayoutProfilesManager.defaultProfileName)
        // Game layout outranks the default in the pinless chain, so
        // the ambient outcome IS the occupancy signal.
        gameShipsLayout = ambient.provenance == .gameLayout
        switch ambient.provenance {
        case .gameLayout:
            automaticResolution = "Game layout"
        case .defaultProfile(let name):
            automaticResolution = name
        default:
            automaticResolution = "Empo default"
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
            pin = target
            LayoutProfilesManager.store.writePin(target, forGameFolder: container.url)
            LayoutProfilesManager.postPinChange(gameID: container.id, from: nil)
        }
    }
}

// MARK: - Manager

/// App-settings list of layout profiles: create, rename, duplicate,
/// delete, set default. Row tap opens the editor.
struct LayoutProfilesSettingsView: View {
    @State private var profiles: [String] = []
    @State private var defaultName: String?
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var deleting: String?
    @State private var showCreateDialog = false
    @State private var createText = ""
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
                        BuiltinLayoutViewerView()
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
                    Text("Built in profiles")
                } footer: {
                    Text("Empo comes with this layout. Games use it when nothing else applies.")
                }
            }

            // ONE section with the ForEach as its direct content:
            // the rows read as one list, and List instantiates and
            // diffs them lazily by their stable name IDs. The shape
            // that stays smooth when the list grows.
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
                    createText = LayoutProfilesManager.store.uniqueName(base: "Layout")
                    showCreateDialog = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create profile")
            }
        }
        .onAppear(perform: reload)
        .alert("New profile", isPresented: $showCreateDialog) {
            TextField("Name", text: $createText)
            Button("Create") { createBlank() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new profile starts from the Empo default layout.")
        }
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
                    Button("Delete, make \(successor) the default") {
                        performDelete(successor: successor)
                    }
                }
                Button("Delete, no default", role: .destructive) {
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

    private var deleteTitle: String {
        guard let deleting else { return "" }
        let count = LayoutProfilesManager.store.gamesPinned(to: deleting).count
        let games = count == 1 ? "1 game uses it." : "\(count) games use it."
        return "Delete \(deleting)? \(games)"
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
            LayoutProfileEditorView(profileName: name)
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
                Button("Remove default") {
                    LayoutProfilesManager.defaultProfileName = nil
                    reload()
                }
            }
            Button("Rename") {
                renameText = name
                renaming = name
            }
            Button("Duplicate") {
                _ = LayoutProfilesManager.store.duplicateProfile(name)
                reload()
            }
            Button("Delete", role: .destructive) {
                deleting = name
            }
        }
    }

    private func createBlank() {
        let store = LayoutProfilesManager.store
        guard let name = LayoutProfileStore.validatedName(createText),
            !store.profileExists(name)
        else {
            showNameError = true
            return
        }
        LayoutProfilesManager.createProfileFromBuiltins(named: name)
        reload()
    }

    private func performRename() {
        guard let oldName = renaming else { return }
        renaming = nil
        guard let newName = LayoutProfileStore.validatedName(renameText), newName != oldName
        else {
            showNameError = true
            return
        }
        guard LayoutProfilesManager.renameProfile(from: oldName, to: newName) else {
            showNameError = true
            return
        }
        reload()
    }

    private func performDelete(successor: String?) {
        guard let name = deleting else { return }
        deleting = nil
        _ = LayoutProfilesManager.deleteProfile(name)
        if let successor {
            LayoutProfilesManager.defaultProfileName = successor
        }
        reload()
    }
}

// MARK: - Canvas geometry

/// Mock-canvas geometry shared by the profile editor and the
/// built-in viewer. Device-stable: everything derives from the
/// reference metrics, so clamping matches the player exactly.
enum EditorCanvas {
    /// Canvas size in device points per orientation.
    static func size(for orientation: ControlsOrientation) -> CGSize {
        let metrics = TouchZoneMetrics.reference
        let isLandscape = orientation == .landscape
        return CGSize(
            width: metrics.width(isLandscape: isLandscape),
            height: metrics.height(isLandscape: isLandscape))
    }

    /// Synthetic WINDOW safe-area insets (notch and home indicator),
    /// not the zone metrics. Those already contain the game height
    /// and toolbar line, and stacking them again empties the clamp
    /// band. The values match the reference device.
    static func safeArea(for orientation: ControlsOrientation) -> EdgeInsets {
        if orientation == .portrait {
            return EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        }
        return EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
    }

    /// The placeholder stands in for the game picture: a 4:3 fit at
    /// the top of the safe area, like a typical RPG Maker viewport.
    static func fakeGameRect(for orientation: ControlsOrientation) -> CGRect {
        let size = size(for: orientation)
        let safeArea = safeArea(for: orientation)
        if orientation == .portrait {
            let width = size.width
            let height = width * 3 / 4
            return CGRect(x: 0, y: safeArea.top, width: width, height: height)
        }
        let height = size.height
        let width = height * 4 / 3
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
    }
}

// MARK: - Editor

/// Out-of-player profile editor: the real overlay components on a
/// mock canvas. Its own `ControlsLayout` instance (the singleton may
/// be bound to a paused game), synthetic metrics, full device-point
/// layout with only the rendering scaled, so clamping matches the
/// player exactly.
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
    @State private var showAddSheet = false
    @State private var editingButton: ButtonModel?
    @State private var editingActionButton: ActionButtonModel?
    @State private var editingDPad = false
    @State private var draggingDPad = false
    @State private var draggingButtonID: UUID?

    init(profileName: String) {
        self.profileName = profileName
        _currentName = State(initialValue: profileName)
        _layout = State(
            initialValue: ControlsLayout(
                editorForProfile: profileName, metrics: .reference))
    }

    private var canvasSize: CGSize { EditorCanvas.size(for: editingOrientation) }
    private var canvasSafeArea: EdgeInsets { EditorCanvas.safeArea(for: editingOrientation) }
    private var fakeGameRect: CGRect { EditorCanvas.fakeGameRect(for: editingOrientation) }

    /// The profile's screen entry for the shown orientation, with
    /// this session's pending edit and the in-flight drag on top.
    /// Same precedence as the player, through the shared helper, so
    /// the placeholder and the controls follow a drag live here too.
    private var screenPlacement: ScreenPlacement? {
        layout.effectiveScreenPlacement(
            stored: editingOrientation == .portrait ? diskScreen?.portrait : diskScreen?.landscape)
    }

    /// The placement as a rect on the MOCK canvas. A preset
    /// computes against the reference canvas and the placeholder's
    /// 4:3 aspect. The same per-device rule the player applies to
    /// the real window.
    private var screenRegion: ScreenRegion? {
        guard let placement = screenPlacement else { return nil }
        switch placement {
        case .region(let region):
            return region
        case .preset(let preset):
            let size = canvasSize
            let safeArea = canvasSafeArea
            return ScreenPresetPlacement.region(
                preset: preset,
                canvasWidth: Double(size.width),
                canvasHeight: Double(size.height),
                safeTop: Double(safeArea.top),
                safeBottom: Double(safeArea.bottom),
                safeLeading: Double(safeArea.leading),
                safeTrailing: Double(safeArea.trailing),
                isPortrait: editingOrientation == .portrait,
                aspect: 4.0 / 3.0)
        }
    }

    /// Region rect on the canvas, when a placement exists.
    private var screenRegionRect: CGRect? {
        guard let region = screenRegion else { return nil }
        let size = canvasSize
        return CGRect(
            x: region.x * size.width, y: region.y * size.height,
            width: region.w * size.width, height: region.h * size.height)
    }

    /// The placeholder is the 4:3 fit INSIDE the region, the
    /// engine letterboxes centered inside it, so the controls
    /// clamp against what the player will show.
    private var placeholderGameRect: CGRect {
        guard let regionRect = screenRegionRect else { return fakeGameRect }
        var width = regionRect.width
        var height = width * 3 / 4
        if height > regionRect.height {
            height = regionRect.height
            width = height * 4 / 3
        }
        return CGRect(
            x: regionRect.midX - width / 2, y: regionRect.midY - height / 2,
            width: width, height: height)
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            Picker("Orientation", selection: $editingOrientation) {
                Text("Portrait").tag(ControlsOrientation.portrait)
                Text("Landscape").tag(ControlsOrientation.landscape)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.xl)
            .onChange(of: editingOrientation) { _, new in
                layout.editorSave()
                layout.setOrientation(new)
                layout.beginEditSession()
                diskScreen = LayoutProfilesManager.store.readScreen(currentName)
            }

            EditorCanvasShell(
                layout: layout,
                actions: actions,
                orientation: editingOrientation,
                editMode: true,
                placeholderRect: placeholderGameRect,
                forcedOverlay: screenRegion?.overlay,
                editingButton: $editingButton,
                editingActionButton: $editingActionButton,
                editingDPad: $editingDPad,
                draggingDPad: $draggingDPad,
                draggingButtonID: $draggingButtonID
            ) { size, gameRect in
                screenGizmoLayers(size: size, gameRect: gameRect)
            }

            HStack(spacing: Spacing.xl) {
                Button("+ Add") { showAddSheet = true }
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
        .toolbar {
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
        .onAppear {
            layout.setOrientation(editingOrientation)
            layout.beginEditSession()
            diskScreen = LayoutProfilesManager.store.readScreen(currentName)
        }
        .onDisappear {
            layout.endEditSession()
            layout.editorSave()
        }
        .controlsEditDialogs(
            layout: layout,
            showAddSheet: $showAddSheet,
            // Reset is a per-game concept (unpin, or back to the
            // ambient chain). The editor has neither. Rename and
            // delete live in the profiles list.
            showResetConfirm: .constant(false),
            editingButton: $editingButton,
            editingActionButton: $editingActionButton,
            editingDPad: $editingDPad
        )
    }

    /// Where the game sits in portrait: a named preset (computed
    /// per device at play time), the automatic engine placement, or
    /// the custom rect the gizmo drew.
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
                        withAnimation(.easeInOut(duration: 0.25)) {
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
        guard let newName = LayoutProfileStore.validatedName(renameText),
            newName != currentName,
            LayoutProfilesManager.renameProfile(from: currentName, to: newName)
        else {
            if LayoutProfileStore.validatedName(renameText) != currentName {
                showRenameError = true
            }
            return
        }
        currentName = newName
        layout.editorRenamed(to: newName)
    }

    /// The editor's extra canvas layers: the screen gizmo and its
    /// chips, BELOW the controls overlay (same order as the player),
    /// or the move surface would steal drags from any control
    /// inside the region rect. The allowed rect comes from the same
    /// policy helper the player uses, so the editor can never
    /// author a region the player forbids. No live engine here:
    /// drags stay local until editorSave merges them.
    @ViewBuilder
    private func screenGizmoLayers(size: CGSize, gameRect: CGRect) -> some View {
        ScreenRegionGizmo(
            canvasSize: size,
            allowedRect: layout.screenDragAllowedRect(
                isPortrait: editingOrientation == .portrait,
                overlayOn: screenRegion?.overlay ?? false,
                canvasSize: size, safeArea: canvasSafeArea),
            baseRect: screenRegionRect ?? gameRect,
            onDragBegan: {
                let auto = EditorCanvas.fakeGameRect(for: editingOrientation)
                layout.beginScreenDrag(
                    autoReference: screenPlacement == nil
                        ? ScreenRegion(
                            x: auto.minX / size.width, y: auto.minY / size.height,
                            w: auto.width / size.width, h: auto.height / size.height)
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
                withAnimation(.easeInOut(duration: 0.25)) {
                    layout.resetScreenEdit()
                }
            }
        )
    }
}

// MARK: - Shared canvas shell

/// The mock-canvas shell the editor and the builtin viewer share:
/// the scale-to-fit wrapper, the black canvas, the game-picture
/// placeholder, and the controls overlay. `underControls` injects
/// extra layers BETWEEN the placeholder and the controls (the
/// editor's screen gizmo). The viewer leaves it empty.
struct EditorCanvasShell<UnderControls: View>: View {
    var layout: ControlsLayout
    var actions: PlayerActionRegistry
    let orientation: ControlsOrientation
    let editMode: Bool
    /// nil uses the canvas's fake game rect. The editor passes its
    /// region-aware placeholder.
    var placeholderRect: CGRect?
    /// The profile's overlay choice, forwarded to the zone split.
    var forcedOverlay: Bool?
    var editingButton: Binding<ButtonModel?> = .constant(nil)
    var editingActionButton: Binding<ActionButtonModel?> = .constant(nil)
    var editingDPad: Binding<Bool> = .constant(false)
    var draggingDPad: Binding<Bool> = .constant(false)
    var draggingButtonID: Binding<UUID?> = .constant(nil)
    /// The read-only viewer turns hit testing off entirely, so no
    /// touch reaches the controls and nothing can write.
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

            // Game-picture placeholder.
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Text("Game")
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
                    editingButton: editingButton,
                    editingActionButton: editingActionButton,
                    editingDPad: editingDPad,
                    draggingDPad: draggingDPad,
                    draggingButtonID: draggingButtonID
                )
            }
            .allowsHitTesting(hitTesting)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
}

extension View {
    /// The shared "Name not allowed" alert, so the wording exists
    /// once for the editor, the viewer, and the settings list.
    func profileNameErrorAlert(isPresented: Binding<Bool>) -> some View {
        alert("Name not allowed", isPresented: isPresented) {
            Button("OK") {}
        } message: {
            Text(
                "Profile names cannot be empty, start with $ or a dot, contain slashes, or repeat an existing name."
            )
        }
    }
}

// MARK: - Built-in viewer

/// Read-only view of the built-in layout on the same mock canvas the
/// editor uses. The overlay is display-only (hit testing off), so no
/// touch reaches the controls and nothing can write.
struct BuiltinLayoutViewerView: View {
    @State private var layout = ControlsLayout(viewerForBuiltins: .reference)
    @State private var actions = PlayerActionRegistry()
    @State private var orientation: ControlsOrientation = .portrait
    @State private var showCreateDialog = false
    @State private var createText = ""
    @State private var showNameError = false

    var body: some View {
        VStack(spacing: Spacing.md) {
            Picker("Orientation", selection: $orientation) {
                Text("Portrait").tag(ControlsOrientation.portrait)
                Text("Landscape").tag(ControlsOrientation.landscape)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.xl)
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
                Text(
                    "Empo comes with this layout. A game uses it when the game has no layout of its own and no profile applies."
                )
                Text(
                    "You cannot edit this layout. Empo keeps it unchanged as a fallback that works for every game. To make your own version, duplicate it as a profile and edit the copy."
                )
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.xl)

            Button("Duplicate as a profile") {
                createText = LayoutProfilesManager.store.uniqueName(base: "My layout")
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
        .alert("New profile", isPresented: $showCreateDialog) {
            TextField("Name", text: $createText)
            Button("Create") { duplicateAsProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The new profile starts as a copy of the Empo default layout.")
        }
        .profileNameErrorAlert(isPresented: $showNameError)
    }

    private func duplicateAsProfile() {
        let store = LayoutProfilesManager.store
        guard let name = LayoutProfileStore.validatedName(createText),
            !store.profileExists(name)
        else {
            showNameError = true
            return
        }
        LayoutProfilesManager.createProfileFromBuiltins(named: name)
    }

}
