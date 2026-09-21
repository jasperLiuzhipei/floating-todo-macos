import Cocoa
import Darwin

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
final class ClickableTaskTitle: NSTextField {
    var onClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
struct TaskLayout {
    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 520
    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static func width(for tasks: [Todo]) -> CGFloat {
        let longest = tasks.map { ($0.title as NSString).size(withAttributes: [.font: titleFont]).width }.max() ?? 0
        return ceil(min(maxWidth, max(minWidth, longest + 70)))
    }
    static func height(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let rect = (text as NSString).boundingRect(with: NSSize(width: width, height: 100000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph])
        return ceil(max(font.ascender - font.descender, rect.height)) + 3
    }
}
// Keep the layout in logical points; scale its bounds so text, spacing and
// controls grow together without reflow. AppKit converts pointer coordinates.
final class ScaledEffectView: NSVisualEffectView {
    static let titlebarInset: CGFloat = 32
    let canvas = NSView()
    private let zoomHost = NSView()
    var designSize: NSSize = .zero
    init(frame: NSRect, designSize: NSSize) {
        self.designSize = designSize
        super.init(frame: frame)
        autoresizesSubviews = false
        canvas.autoresizesSubviews = false
        zoomHost.autoresizesSubviews = false
        addSubview(zoomHost)
        zoomHost.addSubview(canvas)
        updateCanvas()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateCanvas() {
        let logical = NSRect(origin: .zero, size: designSize)
        // Native close controls keep their physical size. Reserve a fixed,
        // unscaled title-bar strip so small zoom levels cannot collide with it.
        let contentFrame = NSRect(x: 0, y: 0, width: bounds.width,
                                  height: max(1, bounds.height - Self.titlebarInset))
        if zoomHost.frame != contentFrame { zoomHost.frame = contentFrame }
        if zoomHost.bounds != logical { zoomHost.bounds = logical }
        if canvas.frame != logical { canvas.frame = logical }
        if canvas.bounds != logical { canvas.bounds = logical }
    }
    override func layout() {
        super.layout()
        updateCanvas()
    }
}
final class ScaleGrip: NSButton {
    var beginDrag: (() -> Void)?
    var dragBy: ((NSPoint) -> Void)?
    var endDrag: (() -> Void)?
    private var origin = NSPoint.zero
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearance()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAppearance()
    }
    private func configureAppearance() {
        title = ""
        bezelStyle = .rounded
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "等比缩放")
        image?.isTemplate = true
        // Let NSButton resolve the symbol and bezel colors from its effective
        // appearance, just like the adjacent review and add buttons.
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 30) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        highlight(true)
        origin = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        NSCursor.closedHand.push()
        beginDrag?()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        dragBy?(NSPoint(x: point.x - origin.x, y: point.y - origin.y))
    }
    override func mouseUp(with event: NSEvent) {
        highlight(false)
        NSCursor.pop()
        endDrag?()
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: TaskStore = {
        if let index = CommandLine.arguments.firstIndex(of: "--data-dir"), CommandLine.arguments.count > index + 1 {
            return TaskStore(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        return TaskStore(directory: TaskStore.defaultDirectory)
    }()
    var settings = Settings()
    var today: String { DayClock.today(timeZone: settings.timeZone) }
    var folder: URL { store.directory }
    var state: State!
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    var progressLabel: NSTextField!
    var timer: Timer?
    var refreshTimer: Timer?
    var lastStateData: Data?
    var addButton: NSButton?
    var queueProcess: Process?
    var persistenceError: String?
    var compact = UserDefaults.standard.bool(forKey: "CompactMode")
    var taskScrollView: NSScrollView?
    var scale: CGFloat = 1
    var scaledEffect: ScaledEffectView?
    var gripResize = GripResizeSession()
    var edgeResize: EdgeResizeSession?
    var changingScale = false
    var designSize = NSSize(width: 320, height: 400)
    var maximumScale: CGFloat {
        let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        return max(0.75, min(1.5, (screen.width - 16) / designSize.width, (screen.height - 16 - ScaledEffectView.titlebarInset) / designSize.height))
    }
    var stateURL: URL { store.file }
    var completed: Int { state.tasks.filter { $0.done }.count }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Finder sends a reopen event to the existing process after its panel closes.
        // Accessory apps must explicitly restore their window for that event.
        if panel != nil { showPanel() }
        return false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            settings = try store.settings()
            state = try store.load(today: today)
            lastStateData = try Data(contentsOf: stateURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法读取今日待办"
            alert.informativeText = "请检查 \(stateURL.path)\n\(error.localizedDescription)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        state.opacity = min(1, max(0.55, state.opacity))
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 384, height: 544), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.delegate = self
        panel.title = "Floating Todo · 今日待办"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.alphaValue = state.opacity
        panel.setFrameAutosaveName("DailyTodoPanel")
        if !panel.setFrameUsingName("DailyTodoPanel"), let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 410, y: frame.maxY - 570))
        }
        let savedScale = UserDefaults.standard.double(forKey: "InterfaceScale")
        scale = savedScale > 0 ? savedScale : 1
        configureScaleLimits()
        applyScale(scale, persist: false)
        buildUI()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "显示今日待办", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        let review = menu.addItem(withTitle: "查看进度与复盘", action: #selector(reviewNow), keyEquivalent: "")
        review.target = self
        let add = menu.addItem(withTitle: "直接添加任务…", action: #selector(addLocalTask), keyEquivalent: "n")
        add.target = self
        let preferences = menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        let data = menu.addItem(withTitle: "打开数据与历史记录", action: #selector(openDataDirectory), keyEquivalent: "")
        data.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出悬浮待办", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
        updateMenu()
        showPanel()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.checkReminder() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshState() }
        checkReminder()
    }
    func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }
    func buildUI() {
        let retainedScale = scale
        let wasChangingScale = changingScale
        changingScale = true
        defer { changingScale = wasChangingScale }
        let scrollPosition = taskScrollView?.contentView.bounds.origin ?? .zero
        designSize.width = TaskLayout.width(for: state.tasks)
        let effect = ScaledEffectView(frame: panel.contentView?.bounds ?? .zero, designSize: designSize)
        scaledEffect = effect
        let canvas = effect.canvas
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        panel.contentView = effect

        func verticalStack(spacing: CGFloat) -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = spacing
            stack.translatesAutoresizingMaskIntoConstraints = false
            return stack
        }
        let header = verticalStack(spacing: 9)
        canvas.addSubview(header)
        let heading = NSStackView()
        heading.spacing = 10
        let title = label("今日待办", size: compact ? 20 : 24, weight: .bold)
        heading.addArrangedSubview(title)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.addArrangedSubview(spacer)
        let mode = NSButton(title: compact ? "展开" : "精简", target: self, action: #selector(toggleCompact))
        mode.bezelStyle = .rounded
        mode.toolTip = compact ? "展开任务说明和设置" : "折叠任务说明和设置"
        mode.setAccessibilityLabel(compact ? "展开任务说明和设置" : "精简：折叠任务说明和设置")
        heading.addArrangedSubview(mode)
        let add = NSButton(title: "+ 添加", target: self, action: #selector(addTask))
        add.bezelStyle = .rounded
        add.toolTip = settings.codexThreadID.isEmpty ? "直接添加今日任务" : "在 Codex 中询问并添加任务"
        add.setAccessibilityLabel("添加今日待办")
        add.isEnabled = queueProcess == nil
        addButton = add
        heading.addArrangedSubview(add)
        header.addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        progressLabel = label("\(state.date)  ·  已完成 \(completed)/\(state.tasks.count)", size: 12, secondary: true)
        header.addArrangedSubview(progressLabel)
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(max(1, state.tasks.count))
        bar.doubleValue = Double(completed)
        bar.style = .bar
        header.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        let footer = verticalStack(spacing: 7)
        canvas.addSubview(footer)
        let actions = NSStackView()
        actions.spacing = 10
        let review = NSButton(title: "进度 / 复盘", target: self, action: #selector(reviewNow))
        review.bezelStyle = .rounded
        actions.addArrangedSubview(review)
        actions.addArrangedSubview(label(settings.reminderLabel, size: 11, secondary: true))
        if !compact {
            let settings = NSStackView()
            settings.spacing = 10
            settings.addArrangedSubview(label("透明度", size: 11, secondary: true))
            let slider = NSSlider(value: state.opacity, minValue: 0.55, maxValue: 1, target: self, action: #selector(changeOpacity(_:)))
            slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
            slider.setAccessibilityLabel("悬浮窗不透明度")
            settings.addArrangedSubview(slider)
            footer.addArrangedSubview(settings)
            let hint = label("右下角拖动等比缩放 · 空白处移动\n勾选自动保存 · 关闭后双击 App 重开", size: 10, secondary: true)
            footer.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        }
        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.addArrangedSubview(actionSpacer)
        let grip = ScaleGrip()
        grip.toolTip = "按住拖动，固定比例缩放整个界面"
        grip.setAccessibilityElement(true)
        grip.setAccessibilityRole(.button)
        grip.setAccessibilityLabel("拖动等比缩放界面")
        grip.widthAnchor.constraint(equalToConstant: 44).isActive = true
        grip.heightAnchor.constraint(equalToConstant: 30).isActive = true
        grip.beginDrag = { [weak self] in self?.gripResize = GripResizeSession() }
        grip.dragBy = { [weak self] delta in
            guard let self = self else { return }
            let next = self.gripResize.scale(for: delta, current: self.scale,
                                            design: self.designSize, maximumScale: self.maximumScale)
            self.applyScale(next, persist: false)
        }
        grip.endDrag = { [weak self] in self?.rememberSize() }
        actions.addArrangedSubview(grip)
        footer.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        if let error = persistenceError {
            let warning = label(error, size: 11)
            warning.textColor = .systemRed
            footer.addArrangedSubview(warning)
            warning.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        canvas.addSubview(scroll)
        taskScrollView = scroll
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let tasks = verticalStack(spacing: compact ? 10 : 15)
        document.addSubview(tasks)
        for task in state.tasks {
            let row = verticalStack(spacing: 4)
            let line = NSStackView()
            line.orientation = .horizontal
            line.alignment = .top
            line.spacing = 6
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(task.id)
            button.state = task.done ? .on : .off
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            button.setAccessibilityLabel(task.title)
            button.toolTip = task.detail
            line.addArrangedSubview(button)
            let title = ClickableTaskTitle(wrappingLabelWithString: task.title)
            title.font = TaskLayout.titleFont
            title.maximumNumberOfLines = 0
            title.lineBreakMode = .byWordWrapping
            title.preferredMaxLayoutWidth = designSize.width - 67
            title.toolTip = task.detail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if task.done {
                title.attributedStringValue = NSAttributedString(string: task.title, attributes: [.font: TaskLayout.titleFont, .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor])
            }
            title.onClick = { [weak self] in self?.toggleTask(id: task.id) }
            title.heightAnchor.constraint(equalToConstant: TaskLayout.height(task.title, width: designSize.width - 67, font: TaskLayout.titleFont)).isActive = true
            line.addArrangedSubview(title)
            row.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            if !compact && !task.detail.isEmpty {
                let detail = label(task.detail, size: 11, secondary: true)
                detail.maximumNumberOfLines = 0
                detail.preferredMaxLayoutWidth = designSize.width - 41
                detail.heightAnchor.constraint(equalToConstant: TaskLayout.height(task.detail, width: designSize.width - 41, font: .systemFont(ofSize: 11))).isActive = true
                row.addArrangedSubview(detail)
                detail.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            }
            tasks.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: tasks.widthAnchor).isActive = true
        }
        if state.tasks.isEmpty {
            tasks.addArrangedSubview(label("今日暂无待办，点击右上角添加。", size: 12, secondary: true))
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            tasks.topAnchor.constraint(equalTo: document.topAnchor, constant: 3),
            tasks.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            tasks.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -5),
            tasks.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -6)
        ])
        effect.layoutSubtreeIfNeeded()
        let naturalHeight = 10 + header.fittingSize.height + 12 + tasks.fittingSize.height + 9 + 10 + footer.fittingSize.height + 14
        let screenHeight = panel.screen?.visibleFrame.height ?? 900
        designSize.height = ceil(min(naturalHeight, (screenHeight * 0.86 - ScaledEffectView.titlebarInset) / max(scale, 0.75)))
        effect.designSize = designSize
        configureScaleLimits()
        applyScale(retainedScale, persist: false)
        effect.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: scrollPosition, size: scroll.contentView.bounds.size)).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func configureScaleLimits() {
        let wasChangingScale = changingScale
        changingScale = true
        defer { changingScale = wasChangingScale }
        // Clear any old aspect constraint with valid one-point increments.
        panel.contentResizeIncrements = NSSize(width: 1, height: 1)
        panel.contentMinSize = NSSize(width: designSize.width * 0.75, height: designSize.height * 0.75 + ScaledEffectView.titlebarInset)
        panel.contentMaxSize = NSSize(width: designSize.width * maximumScale, height: designSize.height * maximumScale + ScaledEffectView.titlebarInset)
    }
    func applyScale(_ requested: CGFloat, persist: Bool = true) {
        scale = min(maximumScale, max(0.75, requested))
        let wasChangingScale = changingScale
        changingScale = true
        defer { changingScale = wasChangingScale }
        let oldTop = panel.frame.maxY
        let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        panel.setContentSize(NSSize(width: designSize.width * scale, height: designSize.height * scale + ScaledEffectView.titlebarInset))
        panel.setFrameOrigin(NSPoint(x: min(max(panel.frame.minX, screen.minX), screen.maxX - panel.frame.width),
                                     y: max(screen.minY, min(oldTop, screen.maxY) - panel.frame.height)))
        scaledEffect?.updateCanvas()
        if persist { rememberSize() }
    }
    func rememberSize() {
        UserDefaults.standard.set(Double(scale), forKey: "InterfaceScale")
        panel.saveFrame(usingName: "DailyTodoPanel")
    }
    func windowWillStartLiveResize(_ notification: Notification) {
        edgeResize = EdgeResizeSession(initialSize: panel.contentRect(forFrameRect: panel.frame).size)
    }
    func windowWillResize(_ sender: NSWindow, to proposed: NSSize) -> NSSize {
        guard !changingScale, sender.inLiveResize else { return proposed }
        if edgeResize == nil {
            edgeResize = EdgeResizeSession(initialSize: sender.contentRect(forFrameRect: sender.frame).size)
        }
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: proposed)).size
        let result = edgeResize!.size(for: content, design: designSize,
                                      inset: ScaledEffectView.titlebarInset, maximumScale: maximumScale)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: result)).size
    }
    func windowDidResize(_ notification: Notification) {
        guard !changingScale, panel != nil else { return }
        // Content-view replacement and layout also emit resize notifications.
        // Only a native user gesture may update the stored zoom from geometry.
        if panel.inLiveResize {
            scale = min(maximumScale, max(0.75, panel.contentRect(forFrameRect: panel.frame).width / designSize.width))
        }
        scaledEffect?.updateCanvas()
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        edgeResize = nil
        rememberSize()
    }
    @objc func toggleCompact() {
        compact.toggle()
        UserDefaults.standard.set(compact, forKey: "CompactMode")
        // Content determines the new dimensions; retain the user's zoom level.
        scaledEffect = nil
        buildUI()
        rememberSize()
    }
    func refreshState() {
        do {
            let data = try Data(contentsOf: stateURL)
            guard data != lastStateData || state.date < today else { return }
            state = try store.load(today: today)
            lastStateData = try Data(contentsOf: stateURL)
            panel.alphaValue = state.opacity
            persistenceError = nil
            buildUI()
            updateMenu()
        } catch {
            if persistenceError == nil {
                persistenceError = "读取数据失败，原文件已保留。请从菜单栏打开数据目录检查。"
                buildUI()
            }
        }
    }
    @discardableResult func mutateState(_ edit: (inout State) -> Void) -> Bool {
        do {
            state = try store.mutate(today: today, edit)
            lastStateData = try Data(contentsOf: stateURL)
            persistenceError = nil
            return true
        } catch {
            persistenceError = "保存失败：" + error.localizedDescription
            return false
        }
    }
    @objc func toggle(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        toggleTask(id: id)
    }
    func toggleTask(id: String) {
        mutateState { latest in
            guard let index = latest.tasks.firstIndex(where: { $0.id == id }) else { return }
            latest.tasks[index].done.toggle()
            latest.tasks[index].completedAt = latest.tasks[index].done ? ISO8601DateFormatter().string(from: Date()) : nil
        }
        buildUI()
        updateMenu()
    }
    @objc func changeOpacity(_ sender: NSSlider) {
        let value = sender.doubleValue
        if mutateState({ $0.opacity = value }) { panel.alphaValue = value }
    }
    @objc func addTask() {
        if settings.codexThreadID.isEmpty { addLocalTask() } else { addTaskInCodex() }
    }
    func codexExecutable() -> URL? {
        var candidates = [settings.codexCLIPath]
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(app.appendingPathComponent("Contents/Resources/codex").path)
        }
        candidates += ["/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    func addTaskInCodex() {
        guard queueProcess == nil else { return }
        let thread = settings.codexThreadID
        guard let cli = codexExecutable() else {
            inform("未找到 Codex", "你可以直接添加任务，或在菜单栏设置中配置 Codex CLI。")
            addLocalTask()
            return
        }
        guard NSWorkspace.shared.open(URL(string: "codex://threads/" + thread)!) else {
            persistenceError = "无法打开 Codex，请手动打开当前工作记录对话。"
            buildUI()
            return
        }
        let process = Process()
        process.executableURL = cli
        process.currentDirectoryURL = folder
        let helper = Bundle.main.url(forResource: "todo_cli", withExtension: "py")!.path
        let prompt = "我点击了 Floating Todo 的添加按钮。请先询问我要添加什么今日待办；收到具体内容后再操作，不要凭空创建任务。把 id（重试复用）、title、detail、date 写入 UTF-8 JSON 文件，运行 Python 3 脚本 \(helper)，参数为 add --state \(stateURL.path) --input 输入文件路径。使用结构化参数或正确的 shell 引号处理路径。只追加任务并保留原有勾选，清单日期是 \(state.date)。如已配置工作记录插件，可同步记为计划；否则只报告桌面清单的保存结果。"
        process.arguments = ["queue", "--thread", thread, "--message", prompt]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        queueProcess = process
        addButton?.isEnabled = false
        process.terminationHandler = { [weak self] result in
            // Drain the small CLI result without storing task or account output.
            _ = output.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.queueProcess = nil
                self.addButton?.isEnabled = true
                if result.terminationStatus != 0 {
                    self.persistenceError = "已打开 Codex；请求发送失败，请直接输入“添加待办”。"
                    self.buildUI()
                    self.showPanel()
                }
            }
        }
        do {
            try process.run()
            panel.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak process] in
                if process?.isRunning == true { process?.terminate() }
            }
        } catch {
            queueProcess = nil
            persistenceError = "已打开 Codex；请直接输入“添加待办”。"
            buildUI()
        }
    }
    func updateMenu() { statusItem?.button?.title = "☑ \(completed)/\(state.tasks.count)" }
    @objc func showPanel() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func reviewText() -> String {
        let lines = state.tasks.map { "\($0.done ? "✓" : "○") \($0.title)" }.joined(separator: "\n")
        return "\(state.date) · 已完成 \(completed)/\(state.tasks.count)\n\n\(lines)\n\n复盘三件事：\n1. 今天实际完成了什么？\n2. 未完成事项有哪些阻碍？\n3. 下一步做什么、预计何时完成？\n\n可复制清单到工作日志，补充成果、阻碍和下一步。"
    }
    @objc func reviewNow() {
        showPanel()
        let alert = NSAlert()
        alert.messageText = "今日工作进度与复盘"
        alert.informativeText = reviewText()
        alert.addButton(withTitle: "继续更新进度")
        alert.addButton(withTitle: "复制复盘清单")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(reviewText(), forType: .string)
        }
    }
    func checkReminder() {
        refreshState()
        guard settings.reminderEnabled, !state.reminderShown, state.date == today,
              !state.tasks.isEmpty else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: settings.timeZone)!
        let components = calendar.dateComponents([.hour, .minute], from: Date())
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        guard minutes >= settings.reminderHour * 60 + settings.reminderMinute else { return }
        guard mutateState({ $0.reminderShown = true }) else { return }
        reviewNow()
    }
    func inform(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
    @objc func openDataDirectory() { NSWorkspace.shared.open(folder) }
    @objc func addLocalTask() {
        showPanel()
        let alert = NSAlert()
        alert.messageText = "添加今日待办"
        alert.informativeText = "填写任务名称，说明可以留空。"
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 104))
        let title = NSTextField(frame: NSRect(x: 0, y: 72, width: 360, height: 26))
        title.placeholderString = "任务名称"
        title.setAccessibilityLabel("任务名称")
        let detail = NSTextField(frame: NSRect(x: 0, y: 6, width: 360, height: 52))
        detail.placeholderString = "补充说明（可选）"
        detail.setAccessibilityLabel("补充说明")
        form.addSubview(title)
        form.addSubview(detail)
        alert.accessoryView = form
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = title
        while alert.runModal() == .alertFirstButtonReturn {
            let text = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { title.placeholderString = "请填写任务名称"; continue }
            if mutateState({ $0.tasks.append(Todo(id: UUID().uuidString, title: text,
                detail: detail.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), done: false)) }) {
                buildUI()
                updateMenu()
                return
            }
            inform("任务未保存", persistenceError ?? "请检查数据目录权限。")
            return
        }
    }
    @objc func showSettings() {
        let alert = NSAlert()
        alert.messageText = "Floating Todo 设置"
        alert.informativeText = "无需 Codex 即可添加任务。填写对话 ID 后，添加按钮会改为回到该对话询问。"
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 252))
        let enabled = NSButton(checkboxWithTitle: "启用每日复盘提醒", target: nil, action: nil)
        enabled.frame = NSRect(x: 0, y: 222, width: 360, height: 24)
        enabled.state = settings.reminderEnabled ? .on : .off
        form.addSubview(enabled)
        func field(_ caption: String, value: String, y: CGFloat) -> NSTextField {
            let name = NSTextField(labelWithString: caption)
            name.frame = NSRect(x: 0, y: y, width: 110, height: 24)
            let input = NSTextField(frame: NSRect(x: 112, y: y, width: 268, height: 24))
            input.stringValue = value
            input.setAccessibilityLabel(caption)
            form.addSubview(name)
            form.addSubview(input)
            return input
        }
        let time = field("提醒时间", value: String(format: "%02d:%02d", settings.reminderHour, settings.reminderMinute), y: 181)
        let zone = field("时区", value: settings.timeZone, y: 139)
        let thread = field("Codex 对话 ID", value: settings.codexThreadID, y: 97)
        let cli = field("CLI 路径（选填）", value: settings.codexCLIPath, y: 55)
        let note = NSTextField(wrappingLabelWithString: "数据保存在本机 Application Support/FloatingTodo；关闭窗口仍会提醒，退出应用则停止提醒。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 0, y: 0, width: 380, height: 38)
        form.addSubview(note)
        alert.accessoryView = form
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        while alert.runModal() == .alertFirstButtonReturn {
            let components = time.stringValue.split(separator: ":")
            guard components.count == 2, let hour = Int(components[0]), let minute = Int(components[1]) else {
                inform("时间格式不正确", "请使用 HH:mm，例如 17:00。")
                continue
            }
            var next = Settings()
            next.reminderEnabled = enabled.state == .on
            next.reminderHour = hour
            next.reminderMinute = minute
            next.timeZone = zone.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            next.codexThreadID = thread.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            next.codexCLIPath = cli.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try store.saveSettings(next)
                settings = next
                refreshState()
                buildUI()
                return
            } catch { inform("设置未保存", error.localizedDescription) }
        }
    }

}

if CommandLine.arguments.contains("--layout-check") {
    let short = Todo(id: "short", title: "短任务", detail: "", done: false)
    let long = Todo(id: "long", title: String(repeating: "这是需要完整换行展示的长任务", count: 8), detail: "", done: false)
    precondition(TaskLayout.width(for: [short]) == 320)
    precondition(TaskLayout.width(for: [long]) == 520)
    precondition(TaskLayout.height(long.title, width: 453, font: TaskLayout.titleFont) > TaskLayout.height(short.title, width: 253, font: TaskLayout.titleFont) * 2)
    print("布局测量通过：最小宽320、最大宽520、长标题换行。")
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
