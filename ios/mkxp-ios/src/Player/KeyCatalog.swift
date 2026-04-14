import Foundation

struct KeyEntry: Identifiable {
    let id = UUID()
    let label: String
    let scancode: Int32
}

let keyCatalog: [KeyEntry] = [
    // Common RPG Maker keys
    KeyEntry(label: "Z (Confirm)",  scancode: Int32(MKXP_SCANCODE_Z)),
    KeyEntry(label: "X (Cancel)",   scancode: Int32(MKXP_SCANCODE_X)),
    KeyEntry(label: "Shift (Dash)", scancode: Int32(MKXP_SCANCODE_LSHIFT)),
    KeyEntry(label: "Ctrl (Skip)",  scancode: Int32(MKXP_SCANCODE_LCTRL)),
    KeyEntry(label: "Space",        scancode: Int32(MKXP_SCANCODE_SPACE)),
    KeyEntry(label: "Enter",        scancode: Int32(MKXP_SCANCODE_RETURN)),
    KeyEntry(label: "Escape",       scancode: Int32(MKXP_SCANCODE_ESCAPE)),
    KeyEntry(label: "Tab",          scancode: Int32(MKXP_SCANCODE_TAB)),
    // Letters
    KeyEntry(label: "A", scancode: Int32(MKXP_SCANCODE_A)),
    KeyEntry(label: "B", scancode: Int32(MKXP_SCANCODE_B)),
    KeyEntry(label: "C", scancode: Int32(MKXP_SCANCODE_C)),
    KeyEntry(label: "D", scancode: Int32(MKXP_SCANCODE_D)),
    KeyEntry(label: "E", scancode: Int32(MKXP_SCANCODE_E)),
    KeyEntry(label: "F", scancode: Int32(MKXP_SCANCODE_F)),
    KeyEntry(label: "G", scancode: Int32(MKXP_SCANCODE_G)),
    KeyEntry(label: "H", scancode: Int32(MKXP_SCANCODE_H)),
    KeyEntry(label: "I", scancode: Int32(MKXP_SCANCODE_I)),
    KeyEntry(label: "J", scancode: Int32(MKXP_SCANCODE_J)),
    KeyEntry(label: "K", scancode: Int32(MKXP_SCANCODE_K)),
    KeyEntry(label: "L", scancode: Int32(MKXP_SCANCODE_L)),
    KeyEntry(label: "M", scancode: Int32(MKXP_SCANCODE_M)),
    KeyEntry(label: "N", scancode: Int32(MKXP_SCANCODE_N)),
    KeyEntry(label: "O", scancode: Int32(MKXP_SCANCODE_O)),
    KeyEntry(label: "P", scancode: Int32(MKXP_SCANCODE_P)),
    KeyEntry(label: "Q", scancode: Int32(MKXP_SCANCODE_Q)),
    KeyEntry(label: "R", scancode: Int32(MKXP_SCANCODE_R)),
    KeyEntry(label: "S", scancode: Int32(MKXP_SCANCODE_S)),
    KeyEntry(label: "T", scancode: Int32(MKXP_SCANCODE_T)),
    KeyEntry(label: "U", scancode: Int32(MKXP_SCANCODE_U)),
    KeyEntry(label: "V", scancode: Int32(MKXP_SCANCODE_V)),
    KeyEntry(label: "W", scancode: Int32(MKXP_SCANCODE_W)),
    KeyEntry(label: "Y", scancode: Int32(MKXP_SCANCODE_Y)),
    // Numbers
    KeyEntry(label: "0", scancode: Int32(MKXP_SCANCODE_0)),
    KeyEntry(label: "1", scancode: Int32(MKXP_SCANCODE_1)),
    KeyEntry(label: "2", scancode: Int32(MKXP_SCANCODE_2)),
    KeyEntry(label: "3", scancode: Int32(MKXP_SCANCODE_3)),
    KeyEntry(label: "4", scancode: Int32(MKXP_SCANCODE_4)),
    KeyEntry(label: "5", scancode: Int32(MKXP_SCANCODE_5)),
    KeyEntry(label: "6", scancode: Int32(MKXP_SCANCODE_6)),
    KeyEntry(label: "7", scancode: Int32(MKXP_SCANCODE_7)),
    KeyEntry(label: "8", scancode: Int32(MKXP_SCANCODE_8)),
    KeyEntry(label: "9", scancode: Int32(MKXP_SCANCODE_9)),
    // Function keys
    KeyEntry(label: "F1",  scancode: Int32(MKXP_SCANCODE_F1)),
    KeyEntry(label: "F2",  scancode: Int32(MKXP_SCANCODE_F2)),
    KeyEntry(label: "F3",  scancode: Int32(MKXP_SCANCODE_F3)),
    KeyEntry(label: "F4",  scancode: Int32(MKXP_SCANCODE_F4)),
    KeyEntry(label: "F5",  scancode: Int32(MKXP_SCANCODE_F5)),
    KeyEntry(label: "F6",  scancode: Int32(MKXP_SCANCODE_F6)),
    KeyEntry(label: "F7",  scancode: Int32(MKXP_SCANCODE_F7)),
    KeyEntry(label: "F8",  scancode: Int32(MKXP_SCANCODE_F8)),
    KeyEntry(label: "F9",  scancode: Int32(MKXP_SCANCODE_F9)),
    KeyEntry(label: "F10", scancode: Int32(MKXP_SCANCODE_F10)),
    KeyEntry(label: "F11", scancode: Int32(MKXP_SCANCODE_F11)),
    KeyEntry(label: "F12", scancode: Int32(MKXP_SCANCODE_F12)),
    // Special
    KeyEntry(label: "Alt",       scancode: Int32(MKXP_SCANCODE_LALT)),
    KeyEntry(label: "Backspace", scancode: Int32(MKXP_SCANCODE_BACKSPACE)),
]

func scancodeDisplayName(_ sc: Int32) -> String {
    for entry in keyCatalog {
        if entry.scancode == sc { return entry.label }
    }
    return "Key \(sc)"
}
