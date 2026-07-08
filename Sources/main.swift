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
        scheduler.onFire = { [weak self] in self?.fireReminder() }
        scheduler.start()

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
        statusItem?.button?.toolTip =
            "Squat Coach — 🔥 \(Prefs.currentStreak)-day streak · \(Prefs.setsToday) set(s) today"
    }

    @objc private func statusClicked() { showMenu() }

    private func showMenu() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let menu = NSMenu()
        menu.addItem(withTitle: "Do \(Prefs.targetReps) squats now", action: #selector(startNow), keyEquivalent: "s")

        let streak = NSMenuItem(title: "🔥 \(Prefs.currentStreak)-day streak · \(Prefs.setsToday) today",
                                action: nil, keyEquivalent: "")
        streak.isEnabled = false
        menu.addItem(streak)
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
                + "them on-device with Apple Vision — nothing is recorded or leaves this Mac.\n\n"
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

    // MARK: - Update check (plain GitHub Releases — no Sparkle; mirrors Claude Dash)

    @objc private func checkForUpdates() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/brianyoungilcho/squat-coach/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var latest: String?, url: String?
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                latest = (obj["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                url = obj["html_url"] as? String
            }
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                if let latest {
                    let upToDate = latest.compare(current, options: .numeric) != .orderedDescending
                    alert.messageText = upToDate ? "You're up to date" : "Update available: v\(latest)"
                    alert.informativeText = upToDate
                        ? "Squat Coach v\(current) is the latest release."
                        : "You have v\(current). Download v\(latest) from GitHub, or run git pull && ./install.sh."
                    alert.addButton(withTitle: upToDate ? "OK" : "Open Releases")
                    if !upToDate { alert.addButton(withTitle: "Later") }
                    if alert.runModal() == .alertFirstButtonReturn, !upToDate, let url, let u = URL(string: url) {
                        NSWorkspace.shared.open(u)
                    }
                } else {
                    alert.messageText = "Couldn't check for updates"
                    alert.informativeText = "GitHub wasn't reachable. Try again later."
                    alert.runModal()
                }
                NSApp.setActivationPolicy(.accessory)
            }
        }.resume()
    }

    /// Bring the accessory app forward for a modal, then demote it again.
    private func withRegularActivation(_ body: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        body()
        NSApp.setActivationPolicy(.accessory)
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
