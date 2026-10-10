import AppKit
import Foundation

struct UsageWindow {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var remainingPercent: Double {
        100 - usedPercent
    }
}

struct UsageSnapshot {
    let primary: UsageWindow
    let secondary: UsageWindow
    let fetchedAt: Date
}

enum UsageError: LocalizedError {
    case codexNotFound
    case timedOut
    case processFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "找不到 Codex 命令行组件"
        case .timedOut:
            return "读取用量超时"
        case .processFailed(let message):
            return message.isEmpty ? "Codex 剩余用量读取失败" : message
        case .malformedResponse:
            return "Codex 返回了无法识别的用量数据"
        }
    }
}

final class UsageService {
    private let queue = DispatchQueue(label: "mini-usage.fetch", qos: .utility)

    func fetch(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        queue.async {
            let result = Result { try self.fetchSynchronously() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func codexURL() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let bundled = Bundle.main.path(forResource: "codex", ofType: nil) {
            candidates.append(bundled)
        }

        var applicationURLs: [URL] = []
        for bundleIdentifier in ["com.openai.codex", "com.openai.chatgpt", "com.openai.chat"] {
            if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                applicationURLs.append(applicationURL)
            }
        }

        let applicationFolders = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        for folder in applicationFolders {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            applicationURLs.append(contentsOf: contents.filter {
                let name = $0.deletingPathExtension().lastPathComponent.lowercased()
                return $0.pathExtension == "app" && (name.contains("chatgpt") || name.contains("codex"))
            })
        }

        let relativeCodexPaths = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex-cli/bin/codex",
            "Contents/Resources/codex-cli/codex",
            "Contents/Resources/codex",
            "Contents/MacOS/codex"
        ]
        for applicationURL in applicationURLs {
            for relativePath in relativeCodexPaths {
                candidates.append(applicationURL.appendingPathComponent(relativePath).path)
            }
        }

        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/codex").path
        ])

        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw UsageError.codexNotFound
    }

    private func fetchSynchronously() throws -> UsageSnapshot {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var lineBuffer = Data()
        var response: [String: Any]?

        process.executableURL = try codexURL()
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            lineBuffer.append(chunk)
            while let newline = lineBuffer.firstIndex(of: 0x0A) {
                let line = lineBuffer.prefix(upTo: newline)
                lineBuffer.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   (object["id"] as? Int) == 1 {
                    response = object
                    semaphore.signal()
                    break
                }
            }
            lock.unlock()
        }

        try process.run()
        let requests = [
            ["method": "initialize", "id": 0, "params": ["clientInfo": ["name": "mini_usage_overlay", "title": "Mini Usage Overlay", "version": "0.1.0"]]],
            ["method": "initialized", "params": [:]],
            ["method": "account/rateLimits/read", "id": 1]
        ] as [[String: Any]]

        for request in requests {
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(0x0A)
            input.fileHandleForWriting.write(data)
        }

        let waitResult = semaphore.wait(timeout: .now() + 15)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        guard waitResult == .success else { throw UsageError.timedOut }
        guard let response else { throw UsageError.malformedResponse }
        if let error = response["error"] as? [String: Any] {
            throw UsageError.processFailed(error["message"] as? String ?? "Codex 剩余用量读取失败")
        }
        guard let result = response["result"] as? [String: Any] else {
            throw UsageError.malformedResponse
        }

        let bucket: [String: Any]?
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any] {
            bucket = (buckets["codex"] as? [String: Any]) ?? buckets.values.compactMap { $0 as? [String: Any] }.first
        } else {
            bucket = result["rateLimits"] as? [String: Any]
        }

        guard let bucket,
              let primary = parseWindow(bucket["primary"]),
              let secondary = parseWindow(bucket["secondary"]) else {
            throw UsageError.malformedResponse
        }
        return UsageSnapshot(primary: primary, secondary: secondary, fetchedAt: Date())
    }

    private func parseWindow(_ value: Any?) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let used = (object["usedPercent"] as? NSNumber)?.doubleValue,
              let minutes = (object["windowDurationMins"] as? NSNumber)?.intValue else { return nil }
        let resetSeconds = (object["resetsAt"] as? NSNumber)?.doubleValue
        return UsageWindow(
            usedPercent: max(0, min(100, used)),
            windowMinutes: minutes,
            resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:))
        )
    }
}

final class UsageBarView: NSView {
    private let fillLayer = CALayer()
    private var value: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.masksToBounds = true
        fillLayer.cornerRadius = 4
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) { nil }

    func setValue(_ newValue: Double, animated: Bool) {
        value = max(0, min(100, newValue))
        let color: NSColor
        switch value {
        case ...15: color = .systemRed
        case ...35: color = .systemOrange
        default: color = .systemGreen
        }
        fillLayer.backgroundColor = color.cgColor
        if animated {
            let animation = CABasicAnimation(keyPath: "bounds.size.width")
            animation.duration = 0.35
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fillLayer.add(animation, forKey: "width")
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * value / 100, height: bounds.height)
        CATransaction.commit()
    }
}

final class UsageRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "—")
    private let resetLabel = NSTextField(labelWithString: "正在读取…")
    private let bar = UsageBarView()

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .right
        resetLabel.font = .systemFont(ofSize: 10, weight: .regular)
        resetLabel.textColor = .secondaryLabelColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, percentLabel, resetLabel, bar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            percentLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            resetLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            resetLabel.trailingAnchor.constraint(lessThanOrEqualTo: percentLabel.leadingAnchor, constant: -8),
            resetLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            bar.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(window: UsageWindow) {
        percentLabel.stringValue = "\(Int(window.remainingPercent.rounded()))%"
        if let date = window.resetsAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm 重置" : "M月d日 HH:mm 重置"
            resetLabel.stringValue = formatter.string(from: date)
        } else {
            resetLabel.stringValue = "重置时间未知"
        }
        bar.setValue(window.remainingPercent, animated: true)
    }
}

final class OverlayContentView: NSVisualEffectView {
    private let fiveHourRow = UsageRowView(title: "5 小时")
    private let weeklyRow = UsageRowView(title: "每周")
    private let statusLabel = NSTextField(labelWithString: "正在连接 Codex…")
    private let refreshButton = NSButton()
    var onRefresh: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Codex 剩余用量")
        title.font = .systemFont(ofSize: 13, weight: .bold)
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        refreshButton.title = "↻"
        refreshButton.isBordered = false
        refreshButton.font = .systemFont(ofSize: 16, weight: .medium)
        refreshButton.toolTip = "立即刷新"
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        [title, statusLabel, refreshButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 23),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -4),
            statusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        let stack = NSStackView(views: [header, fiveHourRow, weeklyRow])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func refreshPressed() { onRefresh?() }

    func setLoading() {
        statusLabel.stringValue = "正在刷新…"
        refreshButton.isEnabled = false
    }

    func show(snapshot: UsageSnapshot) {
        fiveHourRow.update(window: snapshot.primary)
        weeklyRow.update(window: snapshot.secondary)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        statusLabel.stringValue = "更新于 \(formatter.string(from: snapshot.fetchedAt))"
        refreshButton.isEnabled = true
    }

    func show(error: Error) {
        statusLabel.stringValue = error.localizedDescription
        refreshButton.isEnabled = true
    }
}

final class OverlayController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let content = OverlayContentView(frame: NSRect(x: 0, y: 0, width: 300, height: 145))
    private let service = UsageService()
    private var timer: Timer?
    private var isFetching = false

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 145),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        content.onRefresh = { [weak self] in self?.refresh() }
        restoreOrSetInitialPosition()
    }

    func start() {
        panel.orderFrontRegardless()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func toggleVisibility() {
        panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    func refresh() {
        guard !isFetching else { return }
        isFetching = true
        content.setLoading()
        service.fetch { [weak self] result in
            guard let self else { return }
            self.isFetching = false
            switch result {
            case .success(let snapshot): self.content.show(snapshot: snapshot)
            case .failure(let error): self.content.show(error: error)
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        let frame = panel.frame
        UserDefaults.standard.set([frame.origin.x, frame.origin.y], forKey: "overlayOrigin")
    }

    private func restoreOrSetInitialPosition() {
        if let origin = UserDefaults.standard.array(forKey: "overlayOrigin") as? [Double], origin.count == 2 {
            panel.setFrameOrigin(NSPoint(x: origin[0], y: origin[1]))
            return
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.maxY - panel.frame.height - 24))
    }
}

final class MenuBarMeter {
    private weak var button: NSStatusBarButton?
    private let icon: NSImage?
    private var displayedText: String?

    init(button: NSStatusBarButton) {
        self.button = button
        if let url = Bundle.main.url(forResource: "MenuBarKnot", withExtension: "png") {
            icon = NSImage(contentsOf: url)
        } else {
            icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Codex")
        }
        button.imagePosition = .imageOnly
        update(primary: nil, secondary: nil)
    }

    func update(primary: Double?, secondary: Double?) {
        let primaryText = primary.map { "\(Int($0.rounded()))%" } ?? "…"
        let secondaryText = secondary.map { "\(Int($0.rounded()))%" } ?? "…"
        render(primary: primaryText, secondary: secondaryText)
    }

    func showError() {
        render(primary: "--%", secondary: "--%")
    }

    private func render(primary: String, secondary: String) {
        let text = "\(primary)|\(secondary)"
        guard text != displayedText, let button else { return }
        let size = NSSize(width: 64, height: 22)
        let image = NSImage(size: size)
        // Rasterize once per value change; the native button handles appearance
        // and selection without snapshotting a custom hierarchy of subviews.
        image.lockFocus()
        icon?.draw(in: NSRect(x: 0, y: 3, width: 16, height: 16))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        ("5h: \(primary)" as NSString).draw(at: NSPoint(x: 19, y: 10), withAttributes: attributes)
        ("1w: \(secondary)" as NSString).draw(at: NSPoint(x: 19, y: 0), withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = true
        button.image = image
        button.setAccessibilityLabel("Codex 剩余用量，5 小时：\(primary)，每周：\(secondary)")
        displayedText = text
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let service = UsageService()
    private var statusItem: NSStatusItem!
    private var meterView: MenuBarMeter!
    private var timer: Timer?
    private var isFetching = false
    private var fiveHourMenuItem: NSMenuItem!
    private var weeklyMenuItem: NSMenuItem!
    private var aboutPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 72)
        guard let button = statusItem.button else { return }
        button.title = ""
        meterView = MenuBarMeter(button: button)
        button.toolTip = "Codex 剩余用量"

        let menu = NSMenu()
        fiveHourMenuItem = NSMenuItem(title: "5 小时剩余：正在读取…", action: nil, keyEquivalent: "")
        weeklyMenuItem = NSMenuItem(title: "每周剩余：正在读取…", action: nil, keyEquivalent: "")
        menu.addItem(fiveHourMenuItem)
        menu.addItem(weeklyMenuItem)
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        let aboutItem = NSMenuItem(title: "关于 Mini 用量条", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func showAbout() {
        // Wait for menu tracking to finish before bringing the panel forward.
        DispatchQueue.main.async { [weak self] in
            self?.presentAboutPanel()
        }
    }

    private func presentAboutPanel() {
        if aboutPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 190),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "关于 Mini 用量条"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

            let title = NSTextField(labelWithString: "Mini 用量条")
            title.font = .boldSystemFont(ofSize: 20)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
            let versionLabel = NSTextField(labelWithString: "版本 \(version)")
            versionLabel.textColor = .secondaryLabelColor
            let developer = NSTextField(labelWithString: "开发者：Carl Zhang")
            let github = NSButton(title: "github.com/carlzhang123", target: self, action: #selector(openDeveloperGitHub))
            github.bezelStyle = .rounded

            let stack = NSStackView(views: [title, versionLabel, developer, github])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            if let contentView = panel.contentView {
                contentView.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                    stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                    stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
                    stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20)
                ])
            }
            aboutPanel = panel
        }

        guard let aboutPanel else { return }
        if !aboutPanel.isVisible {
            aboutPanel.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutPanel.makeKeyAndOrderFront(nil)
        aboutPanel.orderFrontRegardless()
    }

    @objc private func openDeveloperGitHub() {
        guard let url = URL(string: "https://github.com/carlzhang123") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func refresh() {
        guard !isFetching else { return }
        isFetching = true
        service.fetch { [weak self] result in
            guard let self else { return }
            self.isFetching = false
            switch result {
            case .success(let snapshot):
                self.meterView.update(primary: snapshot.primary.remainingPercent, secondary: snapshot.secondary.remainingPercent)
                self.fiveHourMenuItem.title = self.menuDescription(prefix: "5 小时剩余", window: snapshot.primary)
                self.weeklyMenuItem.title = self.menuDescription(prefix: "每周剩余", window: snapshot.secondary)
                self.statusItem.button?.toolTip = "Codex 剩余用量 · 更新于 \(self.shortTime(snapshot.fetchedAt))"
            case .failure(let error):
                self.meterView.showError()
                self.fiveHourMenuItem.title = "读取失败：\(error.localizedDescription)"
                self.weeklyMenuItem.title = "请确认 ChatGPT 已登录"
                self.statusItem.button?.toolTip = error.localizedDescription
            }
        }
    }

    private func menuDescription(prefix: String, window: UsageWindow) -> String {
        let percent = Int(window.remainingPercent.rounded())
        guard let reset = window.resetsAt else { return "\(prefix)：\(percent)%" }
        return "\(prefix)：\(percent)% · \(shortTime(reset)) 重置"
    }

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
