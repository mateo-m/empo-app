import Foundation

/// Model for a single action button's persistent state.
struct ButtonModel: Identifiable, Equatable {
    let id: UUID
    var label: String
    var scancode: Int32
    var relativeCenter: CGPoint  // fraction of superview size
    var size: CGFloat

    init(label: String, scancode: Int32, relativeCenter: CGPoint, size: CGFloat) {
        self.id = UUID()
        self.label = label
        self.scancode = scancode
        self.relativeCenter = relativeCenter
        self.size = size
    }

    init(from dict: [String: Any]) {
        self.id = UUID()
        self.label = dict["label"] as? String ?? ""
        self.scancode = Int32(dict["scancode"] as? Int ?? 0)
        let rx = dict["rx"] as? CGFloat ?? 0.5
        let ry = dict["ry"] as? CGFloat ?? 0.5
        self.relativeCenter = CGPoint(x: rx, y: ry)
        self.size = dict["size"] as? CGFloat ?? 56
    }

    func toDict() -> [String: Any] {
        return [
            "label": label,
            "scancode": Int(scancode),
            "rx": relativeCenter.x,
            "ry": relativeCenter.y,
            "size": size,
        ]
    }
}

/// Manages the layout of touch controls (d-pad + action buttons) with persistence.
class ControlsLayout: ObservableObject {
    static let shared = ControlsLayout()

    private static let savedLayoutKey = "touchControlsLayout"

    @Published var dpadRelativeCenter: CGPoint = CGPoint(x: 0.13, y: 0.72)
    @Published var dpadSize: CGFloat = 140
    @Published var buttons: [ButtonModel] = []

    private init() {
        if !loadLayout() {
            resetToDefaults()
        }
    }

    // MARK: - Defaults

    static let defaultDPadCenter = CGPoint(x: 0.13, y: 0.72)
    static let defaultDPadSize: CGFloat = 140
    static let defaultButtons: [ButtonModel] = [
        ButtonModel(label: "A",     scancode: Int32(MKXP_SCANCODE_RETURN), relativeCenter: CGPoint(x: 0.90, y: 0.75), size: 56),
        ButtonModel(label: "B",     scancode: Int32(MKXP_SCANCODE_ESCAPE), relativeCenter: CGPoint(x: 0.80, y: 0.68), size: 56),
        ButtonModel(label: "Shift", scancode: Int32(MKXP_SCANCODE_LSHIFT), relativeCenter: CGPoint(x: 0.72, y: 0.80), size: 50),
        ButtonModel(label: "Esc",   scancode: Int32(MKXP_SCANCODE_ESCAPE), relativeCenter: CGPoint(x: 0.92, y: 0.58), size: 38),
    ]

    func resetToDefaults() {
        dpadRelativeCenter = Self.defaultDPadCenter
        dpadSize = Self.defaultDPadSize
        buttons = Self.defaultButtons
    }

    // MARK: - Persistence

    func save() {
        let dpadDict: [String: Any] = [
            "rx": dpadRelativeCenter.x,
            "ry": dpadRelativeCenter.y,
            "size": dpadSize,
        ]
        let btnDicts = buttons.map { $0.toDict() }
        let layout: [String: Any] = [
            "dpad": dpadDict,
            "buttons": btnDicts,
        ]
        UserDefaults.standard.set(layout, forKey: Self.savedLayoutKey)
    }

    @discardableResult
    func loadLayout() -> Bool {
        guard let layout = UserDefaults.standard.dictionary(forKey: Self.savedLayoutKey) else {
            return false
        }

        if let dd = layout["dpad"] as? [String: Any] {
            let rx = dd["rx"] as? CGFloat ?? Self.defaultDPadCenter.x
            let ry = dd["ry"] as? CGFloat ?? Self.defaultDPadCenter.y
            dpadRelativeCenter = CGPoint(x: rx, y: ry)
            dpadSize = dd["size"] as? CGFloat ?? Self.defaultDPadSize
        }

        if let btnDicts = layout["buttons"] as? [[String: Any]] {
            buttons = btnDicts.map { ButtonModel(from: $0) }
        }

        return true
    }

    // MARK: - Mutations

    func addButton(label: String, scancode: Int32) {
        // Strip parenthetical descriptions for display
        var displayLabel = label
        if let range = label.range(of: " (") {
            displayLabel = String(label[..<range.lowerBound])
        }
        let button = ButtonModel(label: displayLabel, scancode: scancode,
                                 relativeCenter: CGPoint(x: 0.5, y: 0.5), size: 56)
        buttons.append(button)
    }

    func removeButton(id: UUID) {
        buttons.removeAll { $0.id == id }
    }

    func updateButton(id: UUID, label: String? = nil, scancode: Int32? = nil, size: CGFloat? = nil, relativeCenter: CGPoint? = nil) {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else { return }
        if let label { buttons[index].label = label }
        if let scancode { buttons[index].scancode = scancode }
        if let size { buttons[index].size = size }
        if let relativeCenter { buttons[index].relativeCenter = relativeCenter }
    }
}
