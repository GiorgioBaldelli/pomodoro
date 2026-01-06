import Cocoa
import UserNotifications

struct AppStats {
    let appName: String
    let seconds: Int
    let percentage: Double
}

class WindowTracker {
    private var csvPath: String
    private let fileHandle: FileHandle?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("Pomodoro", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        csvPath = appFolder.appendingPathComponent("pomodoro_focus_log.csv").path

        if !FileManager.default.fileExists(atPath: csvPath) {
            let header = "timestamp,app_name,window_title,session_type\n"
            FileManager.default.createFile(atPath: csvPath, contents: header.data(using: .utf8))
        }

        fileHandle = FileHandle(forWritingAtPath: csvPath)
        fileHandle?.seekToEndOfFile()
    }

    func logActiveWindow(sessionType: String) {
        guard let activeApp = NSWorkspace.shared.frontmostApplication else { return }

        let appName = activeApp.localizedName ?? "Unknown"
        let windowTitle = getActiveWindowTitle() ?? ""
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let csvLine = "\(timestamp),\"\(appName)\",\"\(windowTitle)\",\(sessionType)\n"
        if let data = csvLine.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    func getStats() -> [AppStats] {
        guard let content = try? String(contentsOfFile: csvPath, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: .newlines).dropFirst()
        var appCounts: [String: Int] = [:]
        var totalSeconds = 0

        for line in lines {
            guard !line.isEmpty else { continue }
            let parts = parseCSVLine(line)
            guard parts.count >= 2 else { continue }

            let appName = parts[1]
            appCounts[appName, default: 0] += 1
            totalSeconds += 1
        }

        return appCounts.map { appName, count in
            AppStats(
                appName: appName,
                seconds: count,
                percentage: totalSeconds > 0 ? Double(count) / Double(totalSeconds) * 100 : 0
            )
        }.sorted { $0.seconds > $1.seconds }
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        parts.append(current)
        return parts
    }

    private func getActiveWindowTitle() -> String? {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            if let ownerName = window[kCGWindowOwnerName as String] as? String,
               ownerName == NSWorkspace.shared.frontmostApplication?.localizedName,
               let windowTitle = window[kCGWindowName as String] as? String,
               !windowTitle.isEmpty {
                return windowTitle
            }
        }
        return nil
    }

    deinit {
        try? fileHandle?.close()
    }
}

class PomodoroTimer: NSObject {
    var timer: Timer?
    var secondsRemaining = 25 * 60
    var workDuration = 25 * 60
    var breakDuration = 5 * 60
    var isWorkSession = true
    var windowTracker = WindowTracker()
    var tickSound: NSSound?
    var enableTickSound = false

    var onTick: ((String) -> Void)?
    var onStatusUpdate: ((String, Bool) -> Void)?

    override init() {
        super.init()
        loadSettings()

        // Try multiple paths to find the sound file
        let possiblePaths = [
            FileManager.default.currentDirectoryPath + "/sound_short.wav",
            "/Users/gbaldelli/Documents/Code/pomodoro/sound_short.wav"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                tickSound = NSSound(contentsOfFile: path, byReference: false)
                tickSound?.volume = 0.3
                print("Sound loaded from: \(path)")
                break
            }
        }
    }

    func loadSettings() {
        let defaults = UserDefaults.standard
        workDuration = defaults.integer(forKey: "workDuration") > 0 ? defaults.integer(forKey: "workDuration") * 60 : 25 * 60
        breakDuration = defaults.integer(forKey: "breakDuration") > 0 ? defaults.integer(forKey: "breakDuration") * 60 : 5 * 60
        enableTickSound = defaults.bool(forKey: "enableTickSound")
        secondsRemaining = isWorkSession ? workDuration : breakDuration
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        pause()
        secondsRemaining = isWorkSession ? workDuration : breakDuration
        onTick?(formatTime(secondsRemaining))
    }

    private func tick() {
        secondsRemaining -= 1
        let timeStr = formatTime(secondsRemaining)
        onTick?(timeStr)
        onStatusUpdate?(timeStr, isWorkSession)

        if enableTickSound && isWorkSession {
            print("Playing tick sound. Enabled: \(enableTickSound), Sound exists: \(tickSound != nil)")
            tickSound?.play()
        }

        if isWorkSession {
            windowTracker.logActiveWindow(sessionType: "work")
        }

        if secondsRemaining <= 0 {
            pause()
            sendNotification(wasWorkSession: isWorkSession)
            isWorkSession.toggle()
            secondsRemaining = isWorkSession ? workDuration : breakDuration
            onStatusUpdate?(formatTime(secondsRemaining), isWorkSession)
            NSSound.beep()
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func sendNotification(wasWorkSession: Bool) {
        let content = UNMutableNotificationContent()
        if wasWorkSession {
            content.title = "Focus Time Complete!"
            content.body = "Great work! Time for a break."
        } else {
            content.title = "Break Complete!"
            content.body = "Ready to focus again?"
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var timerLabel: NSTextField!
    var pomodoroTimer = PomodoroTimer()
    var tabView: NSTabView!
    var statsTextView: NSTextView!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
        setupStatusBar()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pomodoro"
        window.center()
        window.delegate = self

        tabView = NSTabView(frame: window.contentView!.bounds)
        tabView.autoresizingMask = [.width, .height]

        let timerTab = NSTabViewItem(identifier: "timer")
        timerTab.label = "Timer"
        timerTab.view = createTimerView()
        tabView.addTabViewItem(timerTab)

        let statsTab = NSTabViewItem(identifier: "stats")
        statsTab.label = "Stats"
        statsTab.view = createStatsView()
        tabView.addTabViewItem(statsTab)

        let settingsTab = NSTabViewItem(identifier: "settings")
        settingsTab.label = "Settings"
        settingsTab.view = createSettingsView()
        tabView.addTabViewItem(settingsTab)

        window.contentView = tabView
        window.makeKeyAndOrderFront(nil)

        pomodoroTimer.onTick = { [weak self] time in
            self?.timerLabel.stringValue = time
        }

        pomodoroTimer.onStatusUpdate = { [weak self] time, isWork in
            self?.updateStatusBar(time: time, isWork: isWork)
            self?.updateSessionLabel(isWork: isWork)
        }
    }

    func updateStatusBar(time: String, isWork: Bool) {
        if let button = statusItem.button {
            let color = isWork ? NSColor.systemRed : NSColor.systemGreen
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color
            ]
            button.attributedTitle = NSAttributedString(string: time, attributes: attributes)
        }
    }

    func updateSessionLabel(isWork: Bool) {
        guard let timerView = tabView.tabViewItem(at: 0).view,
              let sessionLabel = timerView.viewWithTag(100) as? NSTextField else { return }

        sessionLabel.stringValue = isWork ? "Focus Session" : "Break Time"
        sessionLabel.textColor = isWork ? .systemRed : .systemGreen
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "25:00"
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.systemRed
            ]
            button.attributedTitle = NSAttributedString(string: "25:00", attributes: attributes)
        }

        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Show", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide", action: #selector(hideWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideWindow()
        return false
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func hideWindow() {
        window.orderOut(nil)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func createTimerView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let sessionLabel = NSTextField(labelWithString: "Focus Session")
        sessionLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        sessionLabel.frame = NSRect(x: 100, y: 220, width: 200, height: 25)
        sessionLabel.alignment = .center
        sessionLabel.textColor = .systemRed
        sessionLabel.tag = 100
        view.addSubview(sessionLabel)

        timerLabel = NSTextField(labelWithString: "25:00")
        timerLabel.font = NSFont.monospacedSystemFont(ofSize: 48, weight: .regular)
        timerLabel.frame = NSRect(x: 100, y: 150, width: 200, height: 60)
        timerLabel.alignment = .center
        view.addSubview(timerLabel)

        let startButton = NSButton(frame: NSRect(x: 80, y: 80, width: 70, height: 30))
        startButton.title = "Start"
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(startTimer)
        view.addSubview(startButton)

        let pauseButton = NSButton(frame: NSRect(x: 165, y: 80, width: 70, height: 30))
        pauseButton.title = "Pause"
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(pauseTimer)
        view.addSubview(pauseButton)

        let resetButton = NSButton(frame: NSRect(x: 250, y: 80, width: 70, height: 30))
        resetButton.title = "Reset"
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetTimer)
        view.addSubview(resetButton)

        return view
    }

    func createStatsView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 50, width: 360, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        statsTextView = NSTextView(frame: scrollView.bounds)
        statsTextView.isEditable = false
        statsTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        scrollView.documentView = statsTextView

        view.addSubview(scrollView)

        let refreshButton = NSButton(frame: NSRect(x: 150, y: 10, width: 100, height: 30))
        refreshButton.title = "Refresh"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshStats)
        view.addSubview(refreshButton)

        return view
    }

    @objc func refreshStats() {
        let stats = pomodoroTimer.windowTracker.getStats()
        var text = "Focus Time Stats\n"
        text += "================\n\n"

        if stats.isEmpty {
            text += "No data yet. Start a work session to begin tracking!"
        } else {
            for stat in stats {
                let mins = stat.seconds / 60
                let secs = stat.seconds % 60
                let appName = stat.appName.padding(toLength: 20, withPad: " ", startingAt: 0)
                let timeStr = String(format: "%3d:%02d", mins, secs)
                let pct = String(format: "%5.1f%%", stat.percentage)
                text += "\(appName) \(timeStr)  (\(pct))\n"
            }
        }

        statsTextView.string = text
    }

    @objc func startTimer() {
        pomodoroTimer.start()
    }

    @objc func pauseTimer() {
        pomodoroTimer.pause()
    }

    @objc func resetTimer() {
        pomodoroTimer.reset()
    }

    func createSettingsView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let titleLabel = NSTextField(labelWithString: "Timer Settings")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        titleLabel.frame = NSRect(x: 150, y: 230, width: 150, height: 25)
        view.addSubview(titleLabel)

        let workLabel = NSTextField(labelWithString: "Focus Duration (minutes):")
        workLabel.frame = NSRect(x: 50, y: 180, width: 180, height: 20)
        view.addSubview(workLabel)

        let workField = NSTextField(frame: NSRect(x: 240, y: 178, width: 80, height: 22))
        let defaults = UserDefaults.standard
        let workMins = defaults.integer(forKey: "workDuration") > 0 ? defaults.integer(forKey: "workDuration") : 25
        workField.integerValue = workMins
        workField.tag = 1
        view.addSubview(workField)

        let breakLabel = NSTextField(labelWithString: "Break Duration (minutes):")
        breakLabel.frame = NSRect(x: 50, y: 140, width: 180, height: 20)
        view.addSubview(breakLabel)

        let breakField = NSTextField(frame: NSRect(x: 240, y: 138, width: 80, height: 22))
        let breakMins = defaults.integer(forKey: "breakDuration") > 0 ? defaults.integer(forKey: "breakDuration") : 5
        breakField.integerValue = breakMins
        breakField.tag = 2
        view.addSubview(breakField)

        let tickSoundCheckbox = NSButton(checkboxWithTitle: "Enable Tick Sound", target: nil, action: nil)
        tickSoundCheckbox.frame = NSRect(x: 50, y: 100, width: 180, height: 20)
        tickSoundCheckbox.state = defaults.bool(forKey: "enableTickSound") ? .on : .off
        tickSoundCheckbox.tag = 3
        view.addSubview(tickSoundCheckbox)

        let saveButton = NSButton(frame: NSRect(x: 150, y: 50, width: 100, height: 30))
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveSettings)
        view.addSubview(saveButton)

        return view
    }

    @objc func saveSettings() {
        guard let view = tabView.selectedTabViewItem?.view else { return }

        let workField = view.viewWithTag(1) as? NSTextField
        let breakField = view.viewWithTag(2) as? NSTextField
        let tickSoundCheckbox = view.viewWithTag(3) as? NSButton

        if let workMins = workField?.integerValue, workMins > 0,
           let breakMins = breakField?.integerValue, breakMins > 0 {
            let defaults = UserDefaults.standard
            defaults.set(workMins, forKey: "workDuration")
            defaults.set(breakMins, forKey: "breakDuration")
            defaults.set(tickSoundCheckbox?.state == .on, forKey: "enableTickSound")

            pomodoroTimer.loadSettings()
            pomodoroTimer.reset()

            let alert = NSAlert()
            alert.messageText = "Settings Saved"
            alert.informativeText = "Timer durations have been updated."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
