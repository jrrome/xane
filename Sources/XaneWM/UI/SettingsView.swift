#if os(macOS)
import AppKit
import SwiftUI
import XaneCore

/// The settings window: every option, binding and rule of the config file, by page (like Shoji's).
final class SettingsWindow: NSObject, NSWindowDelegate {
    let model: SettingsModel
    private var window: NSWindow?
    private var keyMonitor: Any?

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        let w = window ?? make()
        NSApp.setActivationPolicy(.regular)   // a Dock icon and ⌘-Tab while it is open
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        w.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "XaneWM Settings"
        w.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        w.setContentSize(NSSize(width: 760, height: 560))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("XaneWMSettings")
        window = w
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.model.recording != nil else { return e }
            self.record(e)
            return nil
        }
        return w
    }

    /// The next key pressed while a binding row is recording becomes its shortcut (esc cancels).
    private func record(_ e: NSEvent) {
        guard let id = model.recording, let i = model.bindings.firstIndex(where: { $0.id == id }) else { return }
        model.recording = nil
        let flags = e.modifierFlags
        if e.keyCode == 0x35, flags.intersection([.command, .control, .option, .shift]).isEmpty { return }
        var mods: Modifiers = []
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.cmd) }
        let previous = model.bindings[i].combo
        model.bindings[i].combo = KeyCombo(keyCode: UInt32(e.keyCode), modifiers: mods)
        model.commit(binding: model.bindings[i], previous: previous)
    }

    func windowWillClose(_ notification: Notification) {
        model.recording = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

extension KeyCombo {
    /// ⌃⌥⇧⌘K, as macOS menus show shortcuts.
    var symbols: String {
        var s = ""
        if modifiers.contains(.ctrl) { s += "⌃" }
        if modifiers.contains(.alt) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.cmd) { s += "⌘" }
        let names = ["return": "↩", "tab": "⇥", "space": "Space", "escape": "⎋", "backspace": "⌫", "delete": "⌦",
                     "left": "←", "right": "→", "up": "↑", "down": "↓", "comma": ",", "period": ".", "slash": "/",
                     "backslash": "\\", "semicolon": ";", "quote": "'", "leftbracket": "[", "rightbracket": "]",
                     "minus": "-", "equal": "=", "grave": "`"]
        let key = Keys.name(for: keyCode) ?? "0x" + String(keyCode, radix: 16)
        return s + (names[key] ?? key.uppercased())
    }
}

private enum Page: String, CaseIterable, Identifiable {
    case general = "General", layout = "Layout", mouse = "Mouse", border = "Border"
    case keyboard = "Keyboard", apps = "Apps", file = "Config File"
    var id: Self { self }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .layout: return "rectangle.split.3x1"
        case .mouse: return "cursorarrow"
        case .border: return "square.dashed"
        case .keyboard: return "keyboard"
        case .apps: return "app.badge"
        case .file: return "doc.text"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var page: Page? = .general

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180)
        } detail: {
            Group {
                switch page ?? .general {
                case .general: GeneralPage(model: model)
                case .layout: LayoutPage(model: model)
                case .mouse: MousePage(model: model)
                case .border: BorderPage(model: model)
                case .keyboard: KeyboardPage(model: model)
                case .apps: AppsPage(model: model)
                case .file: FilePage(model: model)
                }
            }
            .navigationTitle((page ?? .general).rawValue)
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

/// A slider with its value next to it.
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = " pt"

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(SettingsModel.format(value) + unit).monospacedDigit().frame(width: 56, alignment: .trailing)
            }
        }
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary) }
}

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Tiling paused", isOn: Binding(get: { model.paused }, set: { _ in model.onCommand?("toggle-pause") }))
            }
            Section("Desktops") {
                Toggle("Pressing the current desktop goes back", isOn: model.flag(\.desktopBackAndForth, "desktop-back-and-forth"))
                ValueSlider(title: "Only after being there for", value: model.number(\.desktopBackAndForthCooldown, "desktop-back-and-forth-cooldown", step: 0.05),
                            range: 0...2, step: 0.05, unit: " s")
                    .disabled(!model.options.desktopBackAndForth)
                Note("Desktops are the macOS ones (Mission Control) and each tiles its own windows. ⌃1…9 jumps straight to a desktop once “Switch to Desktop N” is on in System Settings → Keyboard → Keyboard Shortcuts → Mission Control; until then XaneWM gets there with “Move left/right a space”.")
            }
            Section("New windows") {
                Picker("Open on", selection: model.pick(\.newWindowOutput, "new-window-output")) {
                    Text("The display under the pointer").tag(NewWindowOutput.pointer)
                    Text("The display of the focused window").tag(NewWindowOutput.focused)
                    Text("Wherever the app puts it").tag(NewWindowOutput.app)
                }
                Picker("Place", selection: model.pick(\.attach, "attach")) {
                    Text("After the focused window").tag(AttachMode.afterFocused)
                    Text("First (main)").tag(AttachMode.top)
                    Text("Last").tag(AttachMode.bottom)
                }
            }
            Section {
                Toggle("Put tiled windows back when an app moves them", isOn: model.flag(\.enforceLayout, "enforce-layout"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct LayoutPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Default layout", selection: model.pick(\.defaultLayout, "default-layout")) {
                    ForEach(LayoutKind.allCases, id: \.self) { k in
                        Text("\(StatusBar.glyph(k))  \(k.rawValue.capitalized)").tag(k)
                    }
                }
                ValueSlider(title: "Main area", value: model.number(\.mainRatio, "main-ratio", step: 0.05),
                            range: ratioRange, step: 0.05, unit: "")
                Note("For displays you have not changed with the layout keys yet.")
            }
            Section("Gaps") {
                ValueSlider(title: "Between windows", value: model.number(\.innerGap, "gap-inner"), range: 0...64)
                ValueSlider(title: "Screen edges", value: model.number(\.outerGap, "gap-outer"), range: 0...64)
            }
            Section("Windows that don't fit") {
                Picker("Overflow", selection: model.pick(\.overflow, "overflow")) {
                    Text("Share a tile").tag(OverflowMode.stack)
                    Text("Float").tag(OverflowMode.float)
                }
                LabeledContent("Most tiles per display") {
                    Stepper(value: model.option(\.maxTiled, "max-tiled") { [String($0)] }, in: 0...64) {
                        Text(model.options.maxTiled == 0 ? "No limit" : "\(model.options.maxTiled)").monospacedDigit()
                    }
                }
            }
            Section("Reserved space for other bars") {
                ValueSlider(title: "Top", value: model.edge(\.top), range: 0...200)
                ValueSlider(title: "Bottom", value: model.edge(\.bottom), range: 0...200)
                ValueSlider(title: "Left", value: model.edge(\.left), range: 0...200)
                ValueSlider(title: "Right", value: model.edge(\.right), range: 0...200)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MousePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Focus follows the pointer", isOn: model.flag(\.focusFollowsMouse, "focus-follows-mouse"))
                ValueSlider(title: "Wait before focusing", value: model.number(\.focusFollowsMouseDelay, "focus-follows-mouse-delay", step: 0.05),
                            range: 0...1, step: 0.05, unit: " s")
                    .disabled(!model.options.focusFollowsMouse)
                Note("0 s focuses a window as soon as the pointer enters it.")
            }
            Section {
                Toggle("Pointer follows focus", isOn: model.flag(\.mouseFollowsFocus, "mouse-follows-focus"))
                Note("Focusing a window from the keyboard moves the pointer to its centre.")
            }
            Section {
                Note("Drag a window onto another to swap them, or onto another display to move it there. Drag an edge to change the split.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct BorderPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Border around the focused window", isOn: model.flag(\.border, "border"))
                Group {
                    ValueSlider(title: "Width", value: model.number(\.borderWidth, "border-width"), range: 1...16)
                    ValueSlider(title: "Corner radius", value: model.number(\.borderRadius, "border-radius"), range: 0...30)
                    Toggle("Use the accent colour", isOn: Binding(
                        get: { model.options.borderColor == "accent" },
                        set: { on in model.option(\.borderColor, "border-color") { [$0] }.wrappedValue = on ? "accent" : "#FFFFFF" }))
                    if model.options.borderColor != "accent" {
                        ColorPicker("Colour", selection: model.borderColor)
                    }
                }
                .disabled(!model.options.border)
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyboardPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach($model.bindings) { $row in
                    BindingRowView(model: model, row: $row)
                }
            }
            Divider()
            HStack {
                Button { model.bindings.append(.init(combo: nil, command: "")); model.recording = model.bindings.last?.id } label: {
                    Label("Add Shortcut", systemImage: "plus")
                }
                Spacer()
                Text("Commands are the same as in the config file and xanectl.").font(.callout).foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }
}

private struct BindingRowView: View {
    @ObservedObject var model: SettingsModel
    @Binding var row: SettingsModel.BindingRow
    @State private var command = ""

    var body: some View {
        let error = SettingsModel.check(command: command)
        let taken = row.combo.map { model.conflicts.contains($0) } ?? false
        HStack {
            Button(model.recording == row.id ? "Press keys…" : (row.combo?.symbols ?? "Record")) {
                model.recording = model.recording == row.id ? nil : row.id
            }
            .frame(width: 110)
            .help("Click, then press the new shortcut (esc cancels)")
            if taken {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    .help("macOS uses this shortcut first (System Settings → Keyboard → Keyboard Shortcuts)")
            }
            TextField("command", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { save() }
            if let error, !command.isEmpty {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(error)
            }
            Button { model.remove(binding: row) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
        .onAppear { command = row.command }
        .onChange(of: row.command) { command = $0 }
    }

    private func save() {
        guard command != row.command else { return }
        row.command = command
        model.commit(binding: row, previous: row.combo)
    }
}

private struct AppsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach($model.rules) { $row in
                    RuleRowView(model: model, row: $row)
                }
                .onMove { from, to in model.rules.move(fromOffsets: from, toOffset: to); model.commitRules() }
            }
            Divider()
            HStack {
                Button { model.addRule() } label: { Label("Add Rule", systemImage: "plus") }
                Menu("Add Rule for App") {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") { model.addRule(for: app) }
                    }
                }
                .fixedSize()
                Spacer()
                Text("Later rules win. Drag to reorder.").font(.callout).foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

private struct RuleRowView: View {
    @ObservedObject var model: SettingsModel
    @Binding var row: SettingsModel.RuleRow

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Picker("", selection: $row.action) {
                Text("Float").tag(SettingsModel.RuleRow.Action.float)
                Text("Tile").tag(SettingsModel.RuleRow.Action.tile)
                Text("Ignore").tag(SettingsModel.RuleRow.Action.ignore)
                Text("Display").tag(SettingsModel.RuleRow.Action.output)
            }
            .labelsHidden()
            .frame(width: 96)
            .onChange(of: row.action) { _ in model.commitRules() }
            if row.action == .output {
                Stepper(value: $row.number, in: 1...9) { Text("\(row.number)").monospacedDigit() }
                    .onChange(of: row.number) { _ in model.commitRules() }
                    .fixedSize()
            }
            Text("when").foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                ForEach(row.matchers.indices, id: \.self) { i in
                    HStack {
                        Picker("", selection: $row.matchers[i].kind) {
                            Text("App ID").tag(SettingsModel.RuleRow.Match.appID)
                            Text("App name").tag(SettingsModel.RuleRow.Match.appName)
                            Text("Title (regex)").tag(SettingsModel.RuleRow.Match.title)
                            Text("Subrole").tag(SettingsModel.RuleRow.Match.subrole)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        .onChange(of: row.matchers[i].kind) { _ in model.commitRules() }
                        TextField("value", text: $row.matchers[i].value)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.commitRules() }
                        if row.matchers.count > 1 {
                            Button { row.matchers.remove(at: i); model.commitRules() } label: { Image(systemName: "minus") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Button { row.matchers.append((.title, "")) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Add a condition (all must match)")
            Button { model.rules.removeAll { $0.id == row.id }; model.commitRules() } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
            if row.toRule() == nil {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("Incomplete: not saved yet")
            }
        }
    }
}

private struct FilePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Config file", value: (model.configPath as NSString).abbreviatingWithTildeInPath)
                HStack {
                    Button("Open in Editor") { model.onOpenConfig?() }
                    Button("Reload") { model.onCommand?("reload") }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.configPath)]) }
                }
                Note("Every change made here is written to this file, keeping your comments. Edits made in the file show up here after a reload.")
            }
            Section("Problems") {
                if model.problems.isEmpty {
                    Label("None", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    ForEach(model.problems, id: \.self) { p in
                        Label(p, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
#endif
