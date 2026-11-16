import Foundation

var testCount = 0
func check(_ condition: Bool, _ message: String) {
    testCount += 1
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// MARK: - 1. CustomShortcut Model & Combo Display
let cmdCtrlX = CustomShortcut(
    title: "测试剪切",
    modifiers: KeyModifiers.command.rawValue | KeyModifiers.control.rawValue,
    hidUsage: 0x1B, // X
    keyLabel: "X"
)

check(cmdCtrlX.comboDisplay == "⌃⌘X", "comboDisplay should format as ⌃⌘X, got \(cmdCtrlX.comboDisplay)")
check(cmdCtrlX.hidUsage == 0x1B, "hidUsage for X should be 0x1B")

// Check ⌘⇧Z
let redo = CustomShortcut(
    title: "重做",
    modifiers: KeyModifiers.command.rawValue | KeyModifiers.shift.rawValue,
    hidUsage: 0x1D, // Z
    keyLabel: "Z"
)
check(redo.comboDisplay == "⇧⌘Z", "comboDisplay should format as ⇧⌘Z, got \(redo.comboDisplay)")

// Check Space (no modifiers)
let space = CustomShortcut(
    title: "抓手",
    modifiers: 0,
    hidUsage: 0x2C,
    keyLabel: "Space"
)
check(space.comboDisplay == "Space", "comboDisplay for Space should be Space, got \(space.comboDisplay)")

// MARK: - 2. Event Stream Generation (KeyChord.press) for ⌘ + ⌃ + X
let events = cmdCtrlX.makeEvents()
// Expected:
// 1. Control down (0xE0) with modifiers = control
// 2. Command down (0xE3) with modifiers = control | command
// 3. X down (0x1B) with modifiers = control | command
// 4. X up (0x1B) with modifiers = control | command
// 5. Command up (0xE3) with modifiers = control
// 6. Control up (0xE0) with modifiers = 0
check(events.count == 6, "Expected 6 events for ⌃⌘X, got \(events.count)")

if case .key(let hid, let down, let mods) = events[0] {
    check(hid == 0xE0 && down == true && mods == KeyModifiers.control.rawValue, "Event 0 should be Control down")
} else { check(false, "Event 0 not a key") }

if case .key(let hid, let down, let mods) = events[1] {
    let expected = KeyModifiers.control.rawValue | KeyModifiers.command.rawValue
    check(hid == 0xE3 && down == true && mods == expected, "Event 1 should be Command down with ⌃⌘")
} else { check(false, "Event 1 not a key") }

if case .key(let hid, let down, let mods) = events[2] {
    let expected = KeyModifiers.control.rawValue | KeyModifiers.command.rawValue
    check(hid == 0x1B && down == true && mods == expected, "Event 2 should be X down with ⌃⌘")
} else { check(false, "Event 2 not a key") }

if case .key(let hid, let down, let mods) = events[3] {
    let expected = KeyModifiers.control.rawValue | KeyModifiers.command.rawValue
    check(hid == 0x1B && down == false && mods == expected, "Event 3 should be X up with ⌃⌘")
} else { check(false, "Event 3 not a key") }

if case .key(let hid, let down, let mods) = events[4] {
    check(hid == 0xE3 && down == false && mods == KeyModifiers.control.rawValue, "Event 4 should be Command up with ⌃")
} else { check(false, "Event 4 not a key") }

if case .key(let hid, let down, let mods) = events[5] {
    check(hid == 0xE0 && down == false && mods == 0, "Event 5 should be Control up with 0 modifiers")
} else { check(false, "Event 5 not a key") }

// MARK: - 3. JSON Serialization Round-trip
let testList = [cmdCtrlX, redo, space]
let encoder = JSONEncoder()
guard let data = try? encoder.encode(testList) else {
    check(false, "Failed to encode CustomShortcut list")
    exit(1)
}
let decoder = JSONDecoder()
guard let decodedList = try? decoder.decode([CustomShortcut].self, from: data) else {
    check(false, "Failed to decode CustomShortcut list")
    exit(1)
}
check(decodedList.count == 3, "Decoded list count mismatch")
check(decodedList[0].id == cmdCtrlX.id, "Decoded id mismatch")
check(decodedList[0].title == "测试剪切", "Decoded title mismatch")
check(decodedList[0].modifiers == cmdCtrlX.modifiers, "Decoded modifiers mismatch")
check(decodedList[0].hidUsage == 0x1B, "Decoded hidUsage mismatch")

// Check default presets
check(CustomShortcutStore.defaultPresets.count == 9, "Expected 9 default presets, got \(CustomShortcutStore.defaultPresets.count)")
let presetTitles = CustomShortcutStore.defaultPresets.map(\.title)
check(presetTitles.contains("撤销"), "Default presets should contain 撤销")
check(presetTitles.contains("保存"), "Default presets should contain 保存")
check(presetTitles.contains("抓手"), "Default presets should contain 抓手")

// MARK: - 4. VirtualKeyboardModifierState (Latching, Locking, Consumption)
let modState = VirtualKeyboardModifierState()
check(modState.control == .off, "Initial control should be off")
check(modState.activeModifiers.isEmpty, "Initial activeModifiers should be empty")

// Cycle control: off -> latched -> locked -> off
modState.cycle(.control)
check(modState.control == .latched, "Control should be latched")
check(modState.activeModifiers == [.control], "activeModifiers should be .control")

modState.cycle(.control)
check(modState.control == .locked, "Control should be locked")
check(modState.activeModifiers == [.control], "activeModifiers should be .control")

modState.cycle(.control)
check(modState.control == .off, "Control should be off after 3rd cycle")
check(modState.activeModifiers.isEmpty, "activeModifiers should be empty")

// Multi-modifier: Lock Command, Latch Control
modState.set(.command, to: .locked)
modState.set(.control, to: .latched)
check(modState.command == .locked, "Command should be locked")
check(modState.control == .latched, "Control should be latched")
check(modState.activeModifiers == [.command, .control], "activeModifiers should have both command and control")

// Simulating keystroke consumption: latched should clear, locked should stay!
modState.consumeLatched()
check(modState.control == .off, "Control should clear after consumeLatched")
check(modState.command == .locked, "Command should stay locked after consumeLatched")
check(modState.activeModifiers == [.command], "activeModifiers should now be command only")

// clearAll
modState.clearAll()
check(modState.command == .off, "Command should be off after clearAll")
check(modState.activeModifiers.isEmpty, "activeModifiers should be empty after clearAll")

// MARK: - 5. ShortcutKeyOption Verification
let options = ShortcutKeyOption.allOptions
check(options.count >= 40, "Expected at least 40 key options, got \(options.count)")
let optionLabels = Set(options.map(\.label))
check(optionLabels.contains("X"), "Options should contain X")
check(optionLabels.contains("Z"), "Options should contain Z")
check(optionLabels.contains("Space"), "Options should contain Space")
check(optionLabels.contains("Return"), "Options should contain Return")
check(optionLabels.contains("Esc"), "Options should contain Esc")
check(optionLabels.contains("F1"), "Options should contain F1")
check(optionLabels.contains("F12"), "Options should contain F12")

for opt in options {
    check(opt.hidUsage > 0, "Option \(opt.label) must have valid non-zero hidUsage")
}

let uniqueUsages = Set(options.map(\.hidUsage))
check(uniqueUsages.count == options.count, "All shortcut key option hidUsages must be unique")

print("ok: \(testCount) checks passed (shortcuts, modifiers, event stream, serialization)")
