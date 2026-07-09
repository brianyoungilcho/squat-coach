import AppKit
import SwiftUI
import AVFoundation
import UserNotifications
import ServiceManagement

let repoURL = "https://github.com/brianyoungilcho/squat-coach"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let scheduler = Scheduler()
    private let workout = WorkoutController()
    private var usr1Source: DispatchSourceSignal?
    private var usr2Source: DispatchSourceSignal?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        Prefs.registerDefaults()
        setupMainMenu()
        setupStatusItem()
        registerLoginItemOnce()
        // Ask for camera up front (once), while no floating window can cover the
        // system permission dialog. By the first hourly reminder it's already set.
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        workout.onFinished = { [weak self] _ in self?.refreshStatusTooltip() }
        scheduler.onFire = { [weak self] in
            PackShare.postDigestIfNeeded()
            self?.fireReminder()
        }
        scheduler.start()
        PackShare.postDigestIfNeeded()   // catch up if we launched after 06:00
        refreshStatusTooltip()   // now that nextFire is known

        // `kill -USR1 <pid>` triggers a reminder immediately — handy for a
        // "remind me now" script and for driving the app during testing.
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fireReminder() } }
        src.resume()
        usr1Source = src

        // `kill -USR2 <pid>` opens Settings — a scripting/testing hook.
        signal(SIGUSR2, SIG_IGN)
        let src2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        src2.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.presentSettings() } }
        src2.resume()
        usr2Source = src2
    }

    // MARK: - Status item

    private func setupStatusItem() {
        // macOS 26 notched-menu-bar fix (mirrors Claude Dash): a status item with
        // no persisted position is dropped into the hidden left-of-notch overflow
        // and never drawn. Seed a right-of-notch slot BEFORE assigning the
        // autosave name; the user's first drag overwrites this and we never fight it.
        let posKey = "NSStatusItem Preferred Position SquatCoachStatusItem"
        if UserDefaults.standard.object(forKey: posKey) == nil {
            UserDefaults.standard.set(450.0, forKey: posKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "SquatCoachStatusItem"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "figure.strengthtraining.functional",
                                   accessibilityDescription: "Squat Coach")
            button.image?.isTemplate = true
            button.title = ""
            button.target = self
            button.action = #selector(statusClicked)
        }
        refreshStatusTooltip()
    }

    private func refreshStatusTooltip() {
        // Absolute clock time in the tooltip so it never goes stale between hovers.
        let next = scheduler.nextFire.map { "next set \(clockString($0))" } ?? "no reminder set"
        statusItem?.button?.toolTip =
            "Squat Coach — \(next) · 🔥 \(Prefs.currentStreak)-day streak · \(Prefs.setsToday) today"
    }

    // MARK: - Schedule readout

    /// Live "when's the next set / how long since the last" line (fresh each menu open).
    private func scheduleLine() -> String {
        let next = scheduler.nextFire.map { "Next set \(untilString($0))" } ?? "Next set —"
        let last = Prefs.lastSetAt.map { "last \(agoString($0))" } ?? "no set yet"
        return "⏱ \(next) · \(last)"
    }

    private func untilString(_ date: Date) -> String {
        let s = date.timeIntervalSinceNow
        if s <= 30 { return "now" }
        let m = Int((s / 60).rounded())
        if m < 1 { return "in <1 min" }
        if m < 60 { return "in \(m) min" }
        return "in \(m / 60)h \(m % 60)m"
    }

    private func agoString(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 60 { return "just now" }
        let m = Int(s / 60)
        if m < 60 { return "\(m) min ago" }
        return "\(m / 60)h \(m % 60)m ago"
    }

    private func clockString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    @objc private func statusClicked() { showMenu() }

    private func showMenu() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let menu = NSMenu()
        menu.addItem(withTitle: "Do \(Prefs.targetReps) squats now", action: #selector(startNow), keyEquivalent: "s")

        let sched = NSMenuItem(title: scheduleLine(), action: nil, keyEquivalent: "")
        sched.isEnabled = false
        menu.addItem(sched)

        let streak = NSMenuItem(title: "🔥 \(Prefs.currentStreak)-day streak · \(Prefs.setsToday) today",
                                action: nil, keyEquivalent: "")
        streak.isEnabled = false
        menu.addItem(streak)

        if Prefs.packShareEnabled {
            let pack = NSMenuItem(title: "🤝 Pack · sharing as \(Prefs.packResolvedName)",
                                  action: nil, keyEquivalent: "")
            pack.isEnabled = false
            menu.addItem(pack)
        }
        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())

        menu.addItem(withTitle: "About Squat Coach (v\(version))", action: #selector(about), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Squat Coach", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // detach so the next click re-opens fresh
    }

    // MARK: - Actions

    @objc private func startNow() { fireReminder() }
    @objc private func openSettings() { presentSettings() }

    @objc private func about() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        withRegularActivation {
            let a = NSAlert()
            a.messageText = "Squat Coach"
            a.informativeText = "Version \(version)\n\n"
                + "Every \(Prefs.intervalMinutes) minutes, do \(Prefs.targetReps) squats. Your camera counts "
                + "them on-device with Apple Vision — video is never recorded and never leaves this Mac. "
                + "Pack sharing (optional, off by default) posts only your name, set counts, and streak "
                + "to your pack's Slack channel.\n\n"
                + "🔥 \(Prefs.currentStreak)-day streak · \(Prefs.setsToday) set(s) today."
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "View on GitHub")
            if a.runModal() == .alertSecondButtonReturn, let u = URL(string: repoURL) {
                NSWorkspace.shared.open(u)
            }
        }
    }

    // MARK: - Settings window (SwiftUI, Claude Dash style)

    private func presentSettings() {
        if let w = settingsWindow {
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil); w.orderFrontRegardless()
            return
        }
        let view = SettingsView(
            onIntervalChange: { [weak self] in self?.scheduler.reschedule() },
            onCheckUpdates: { [weak self] in self?.checkForUpdates() })
        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.title = "Squat Coach Settings"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        settingsWindow = win
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingsWindow = nil
                NSApp.setActivationPolicy(.accessory)
                self?.refreshStatusTooltip()
            }
        }
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil); win.orderFrontRegardless()
    }

    // MARK: - Update check + one-click install (GitHub Releases — no Sparkle)

    /// One update flow at a time — the check is reachable from both the menu
    /// and Settings, and two concurrent installs would race the bundle swap.
    private var updateInFlight = false

    @objc private func checkForUpdates() {
        guard !updateInFlight else { return }
        updateInFlight = true
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/brianyoungilcho/squat-coach/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let release = data.flatMap(UpdaterLogic.parseRelease)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.presentUpdateAlert(release) } }
        }.resume()
    }

    private func presentUpdateAlert(_ release: UpdaterLogic.Release?) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        var install = false
        withRegularActivation {
            let alert = NSAlert()
            guard let release else {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "GitHub wasn't reachable. Try again later."
                alert.runModal()
                return
            }
            guard UpdaterLogic.isNewer(latest: release.version, current: current) else {
                alert.messageText = "You're up to date"
                alert.informativeText = "Squat Coach v\(current) is the latest release."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            alert.messageText = "Update available: v\(release.version)"
            alert.informativeText = "You have v\(current). Squat Coach can download v\(release.version), "
                + "install it, and relaunch itself."
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "View on GitHub")
            alert.addButton(withTitle: "Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn: install = true
            case .alertSecondButtonReturn:
                if let u = URL(string: release.pageURL) { NSWorkspace.shared.open(u) }
            default: break
            }
        }
        if install, let release { startInstall(release) } else { updateInFlight = false }
    }

    private func startInstall(_ release: UpdaterLogic.Release) {
        guard let zip = URL(string: release.zipURL), UpdaterLogic.isTrustedDownloadURL(zip) else {
            updateInFlight = false
            return
        }
        statusItem?.button?.toolTip = "Squat Coach — downloading v\(release.version)…"
        Updater.install(zipURL: zip, expectedVersion: release.version,
                        appPath: Bundle.main.bundlePath) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let error else {
                    Updater.relaunch(appPath: Bundle.main.bundlePath)
                    return
                }
                self.updateInFlight = false
                self.refreshStatusTooltip()
                self.withRegularActivation {
                    let a = NSAlert()
                    a.messageText = "Update failed"
                    a.informativeText = error.localizedDescription
                        + " You can update manually from the releases page."
                    a.addButton(withTitle: "OK")                 // default = safe dismiss
                    a.addButton(withTitle: "Open Releases")
                    if a.runModal() == .alertSecondButtonReturn, let u = URL(string: release.pageURL) {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
        }
    }

    /// Bring the accessory app forward for a modal, then demote it again —
    /// unless the Settings window is still open, which owns .regular until it
    /// closes (its willClose handler does the demotion).
    private func withRegularActivation(_ body: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        body()
        if settingsWindow == nil { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: - Reminder

    private func fireReminder() {
        postBanner()
        workout.present()
    }

    private func postBanner() {
        let content = UNMutableNotificationContent()
        content.title = "Squat time 🏋️"
        content.body = "Do \(Prefs.targetReps) squats — your camera will count them."
        content.sound = Prefs.soundEnabled ? .default : nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Login item

    private func registerLoginItemOnce() {
        let flag = "didAutoRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        do {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            UserDefaults.standard.set(true, forKey: flag)
        } catch { /* non-fatal: app still runs, just won't auto-start */ }
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Squat Coach", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Show the banner even while Squat Coach is the frontmost app. Marked
    // nonisolated: it touches no actor state, just answers the callback.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Bootstrap (NSApplication.delegate is weak, so retain the delegate here)

private var retainedDelegate: AppDelegate?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
