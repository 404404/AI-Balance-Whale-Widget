import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    var onSaved: (() -> Void)?
    private let codexPathField = NSTextField(string: "")
    private let codexHomeField = NSTextField(string: "")
    private let scaleField = NSSlider(value: 1, minValue: 0.65, maxValue: 1.6, target: nil, action: nil)
    private let soundCheckbox = NSButton(checkboxWithTitle: "启用按压音效", target: nil, action: nil)
    private let topCheckbox = NSButton(checkboxWithTitle: "置顶（只覆盖普通窗口）", target: nil, action: nil)
    private let spacesCheckbox = NSButton(checkboxWithTitle: "跨桌面显示，并辅助全屏应用", target: nil, action: nil)
    private let passthroughCheckbox = NSButton(checkboxWithTitle: "空白时鼠标穿透（从菜单栏恢复）", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时启动（默认关闭）", target: nil, action: nil)
    private let codexStatusLabel = NSTextField(labelWithString: "")

    init() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 430))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "AI Balance Whale 设置"
        window.contentView = view
        super.init(window: window)
        buildView(view)
        loadValues()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildView(_ view: NSView) {
        func label(_ text: String, _ frame: NSRect, size: CGFloat = 13) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.frame = frame; field.font = .systemFont(ofSize: size); field.textColor = .labelColor
            view.addSubview(field); return field
        }
        func button(_ title: String, _ frame: NSRect, _ action: Selector) -> NSButton {
            let item = NSButton(title: title, target: self, action: action)
            item.frame = frame; item.bezelStyle = .rounded; view.addSubview(item); return item
        }

        label("Codex 额度来自本机 codex app-server，只读取账号与 rate limits，不会读取或记录 token。", NSRect(x: 24, y: 382, width: 512, height: 28), size: 12)
        label("codex 可执行文件", NSRect(x: 24, y: 333, width: 150, height: 22))
        codexPathField.frame = NSRect(x: 170, y: 330, width: 300, height: 26); view.addSubview(codexPathField)
        button("选择…", NSRect(x: 478, y: 330, width: 58, height: 26), #selector(chooseCodex))
        label("CODEX_HOME（可留空，默认 ~/.codex）", NSRect(x: 24, y: 291, width: 250, height: 22))
        codexHomeField.frame = NSRect(x: 274, y: 288, width: 262, height: 26); view.addSubview(codexHomeField)
        codexStatusLabel.frame = NSRect(x: 24, y: 260, width: 512, height: 18)
        codexStatusLabel.font = .systemFont(ofSize: 11)
        codexStatusLabel.textColor = .secondaryLabelColor
        view.addSubview(codexStatusLabel)
        label("显示与系统", NSRect(x: 24, y: 236, width: 200, height: 22), size: 14).font = .boldSystemFont(ofSize: 14)
        let checks = [soundCheckbox, topCheckbox, spacesCheckbox, passthroughCheckbox, loginCheckbox]
        for (index, checkbox) in checks.enumerated() {
            checkbox.target = self; checkbox.action = #selector(checkChanged(_:)); checkbox.frame = NSRect(x: 28, y: 192 - CGFloat(index) * 30, width: 400, height: 24); view.addSubview(checkbox)
        }
        label("鲸鱼大小", NSRect(x: 24, y: 50, width: 90, height: 22))
        scaleField.frame = NSRect(x: 114, y: 51, width: 250, height: 22); scaleField.target = self; scaleField.action = #selector(scaleChanged(_:)); view.addSubview(scaleField)
        button("保存", NSRect(x: 388, y: 22, width: 70, height: 30), #selector(save))
        button("刷新额度", NSRect(x: 466, y: 22, width: 70, height: 30), #selector(refresh))
        button("帮助", NSRect(x: 24, y: 22, width: 70, height: 30), #selector(openHelp))
        button("问题反馈", NSRect(x: 102, y: 22, width: 86, height: 30), #selector(openFeedback))
        label("首版只支持 Codex ChatGPT 登录订阅额度；API Key、无登录、离线与不兼容版本会明确提示。", NSRect(x: 24, y: 4, width: 340, height: 22), size: 10).textColor = .secondaryLabelColor
    }

    private func loadValues() {
        let preferences = AppPreferences.shared
        codexPathField.stringValue = preferences.codexPath
        codexHomeField.stringValue = preferences.codexHome
        updateCodexStatus()
        scaleField.doubleValue = preferences.scale
        soundCheckbox.state = preferences.soundEnabled ? .on : .off
        topCheckbox.state = preferences.alwaysOnTop ? .on : .off
        spacesCheckbox.state = preferences.allSpaces ? .on : .off
        passthroughCheckbox.state = preferences.mousePassthrough ? .on : .off
        loginCheckbox.state = preferences.launchAtLogin ? .on : .off
    }

    @objc private func chooseCodex() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.unixExecutable]
        if panel.runModal() == .OK, let url = panel.url { codexPathField.stringValue = url.path; updateCodexStatus() }
    }

    private func updateCodexStatus() {
        let configured = codexPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let executable = CodexLocator.executable(configuredPath: configured) else {
            codexStatusLabel.stringValue = configured.isEmpty ? "自动探测：未找到可执行的 codex" : "手动路径不可执行：\(configured)"
            return
        }
        codexStatusLabel.stringValue = "当前 CLI：\(executable.path) · 版本探测中…"
        CodexLocator.version(at: executable) { [weak self] version in
            guard let self else { return }
            self.codexStatusLabel.stringValue = "当前 CLI：\(executable.path) · \(version ?? "版本未知或无法运行")"
        }
    }

    @objc private func checkChanged(_ sender: NSButton) {
        if sender === loginCheckbox { updateLoginItem(enabled: sender.state == .on) }
    }

    @objc private func scaleChanged(_ sender: NSSlider) { AppPreferences.shared.scale = sender.doubleValue; onSaved?() }

    @objc private func save() {
        let preferences = AppPreferences.shared
        preferences.codexPath = codexPathField.stringValue
        preferences.codexHome = codexHomeField.stringValue
        preferences.scale = scaleField.doubleValue
        preferences.soundEnabled = soundCheckbox.state == .on
        preferences.alwaysOnTop = topCheckbox.state == .on
        preferences.allSpaces = spacesCheckbox.state == .on
        preferences.mousePassthrough = passthroughCheckbox.state == .on
        preferences.launchAtLogin = loginCheckbox.state == .on
        updateLoginItem(enabled: preferences.launchAtLogin)
        onSaved?()
    }

    @objc private func refresh() { onSaved?() }

    @objc private func openHelp() { open("https://github.com/404404/AI-Balance-Whale-Widget#ai-balance-whale-macos") }
    @objc private func openFeedback() { open("https://github.com/404404/AI-Balance-Whale-Widget/issues") }
    private func open(_ string: String) { if let url = URL(string: string) { NSWorkspace.shared.open(url) } }

    private func updateLoginItem(enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Keep the preference visible; macOS may deny registration for an
            // unsigned development build. The app remains launchable manually.
        }
    }
}
