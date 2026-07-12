import AppKit
import SwiftUI
import AVFoundation
import UserNotifications
import ServiceManagement

let repoURL = "https://github.com/brianyoungilcho/squat-coach"

private enum ReminderNotification {
    static let category = "SQUAT_REMINDER"
    static let start = "START_WORKOUT"
    static let snooze = "SNOOZE_WORKOUT"
    static let skip = "SKIP_WORKOUT"
}

private enum PackNotification {
    static let category = "PACK_ACTIVITY"
    static let cheer = "CHEER_PACK_EVENT"
    static let open = "OPEN_PACK"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let scheduler = Scheduler()
    private let workout = WorkoutController()
    private let packWindowController = PackWindowController()
    private var usr1Source: DispatchSourceSignal?
    private var usr2Source: DispatchSourceSignal?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        Prefs.registerDefaults()
        setupMainMenu()
        setupStatusItem()
        UNUserNotificationCenter.current().delegate = self
        registerNotificationActions()
        workout.onFinished = { [weak self] _ in
            self?.refreshStatusTooltip()
        }
        workout.onVisibilityChange = { [weak self] in self?.updateActivationPolicy() }
        scheduler.onFire = { [weak self] in
            self?.fireReminder()
        }
        scheduler.start()
        PackStore.shared.bootstrap()
        packWindowController.onVisibilityChange = { [weak self] in
            self?.updateActivationPolicy()
        }
        refreshStatusTooltip()   // now that nextFire is known
        if !Prefs.onboardingCompleted {
            presentOnboarding()
        }

        // `kill -USR1 <pid>` triggers a reminder immediately — handy for a
        // "remind me now" script and for driving the app during testing.
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.workout.present() } }
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

        if let snapshot = PackStore.shared.snapshot {
            PackStore.shared.refresh()
            menu.addItem(.separator())
            let header = NSMenuItem(
                title: "Your Pack · \(snapshot.pack.name)",
                action: #selector(openPack),
                keyEquivalent: "p"
            )
            header.target = self
            header.image = NSImage(
                systemSymbolName: "person.3",
                accessibilityDescription: "Open Pack"
            )
            menu.addItem(header)

            let eventsToday = snapshot.activities.filter {
                Calendar.current.isDateInToday($0.event.occurredAt)
            }
            let activeMembers = Set(eventsToday.map(\.event.userId)).count
            let summary = NSMenuItem(
                title: "\(activeMembers) active today · \(eventsToday.count) finished sets",
                action: nil,
                keyEquivalent: ""
            )
            summary.isEnabled = false
            menu.addItem(summary)
        } else {
            menu.addItem(.separator())
            let pack = NSMenuItem(
                title: "Set up a Pack…",
                action: #selector(openPack),
                keyEquivalent: "p"
            )
            pack.target = self
            pack.image = NSImage(
                systemSymbolName: "person.3",
                accessibilityDescription: "Set up a Pack"
            )
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

    @objc private func startNow() { workout.present() }
    @objc private func openSettings() { presentSettings() }
    @objc private func openPack() { packWindowController.present() }

    @objc private func about() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        withRegularActivation {
            let a = NSAlert()
            a.messageText = "Squat Coach"
            a.informativeText = "Version \(version)\n\n"
                + "Every \(Prefs.intervalMinutes) minutes, Squat Coach offers a movement reminder. "
                + "Your camera counts reps on-device with Apple Vision; video is never recorded or uploaded. "
                + "Optional Packs share only your chosen name, finished-set totals, and streak with verified members.\n\n"
                + "\(Prefs.currentStreak)-day streak · \(Prefs.setsToday) set(s) today."
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
            onCheckUpdates: { [weak self] in self?.checkForUpdates() },
            onOpenPack: { [weak self] in self?.packWindowController.present() })
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
                self?.refreshStatusTooltip()
                self?.updateActivationPolicy()
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
        withRegularActivation {
            let alert = NSAlert()
            guard let release else {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "GitHub wasn't reachable. Try again later."
                alert.runModal()
                updateInFlight = false
                return
            }
            guard UpdaterLogic.isNewer(latest: release.version, current: current) else {
                alert.messageText = "You're up to date"
                alert.informativeText = "Squat Coach v\(current) is the latest release."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                updateInFlight = false
                return
            }
            alert.messageText = "Update available: v\(release.version)"
            alert.informativeText = "You have v\(current). Open the signed release page to review and install the update."
            alert.addButton(withTitle: "View on GitHub")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                if let u = URL(string: release.pageURL) { NSWorkspace.shared.open(u) }
            }
            updateInFlight = false
        }
    }

    /// Bring the accessory app forward for a modal, then demote it again —
    /// unless the Settings window is still open, which owns .regular until it
    /// closes (its willClose handler does the demotion).
    private func withRegularActivation(_ body: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        body()
        updateActivationPolicy()
    }

    // MARK: - Reminder

    private func fireReminder() {
        guard Prefs.remindersEnabled else { return }
        postBanner()
    }

    private func postBanner(after delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = "Time for a movement break"
        content.body = "Ready for \(Prefs.targetReps) squats?"
        content.sound = Prefs.soundEnabled ? .default : nil
        content.categoryIdentifier = ReminderNotification.category
        let trigger = delay.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false)
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: trigger
            )
        )
    }

    private func registerNotificationActions() {
        let start = UNNotificationAction(
            identifier: ReminderNotification.start,
            title: "Start",
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: ReminderNotification.snooze,
            title: "Snooze 15 min"
        )
        let skip = UNNotificationAction(
            identifier: ReminderNotification.skip,
            title: "Skip"
        )
        let category = UNNotificationCategory(
            identifier: ReminderNotification.category,
            actions: [start, snooze, skip],
            intentIdentifiers: []
        )
        let cheer = UNNotificationAction(
            identifier: PackNotification.cheer,
            title: "Cheer"
        )
        let openPack = UNNotificationAction(
            identifier: PackNotification.open,
            title: "Open Pack",
            options: [.foreground]
        )
        let packCategory = UNNotificationCategory(
            identifier: PackNotification.category,
            actions: [cheer, openPack],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([
            category,
            packCategory,
        ])
    }

    // MARK: - Onboarding and activation

    private func presentOnboarding() {
        guard onboardingWindow == nil else { return }
        let view = OnboardingView { [weak self] enableNotifications in
            guard let self else { return }
            if enableNotifications {
                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound]
                ) { _, _ in }
            }
            self.scheduler.reschedule()
            self.onboardingWindow?.close()
        }
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: view)
        )
        window.title = "Welcome to Squat Coach"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onboardingWindow = nil
                self?.updateActivationPolicy()
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func updateActivationPolicy() {
        let hasVisibleWindow =
            settingsWindow?.isVisible == true ||
            onboardingWindow?.isVisible == true ||
            packWindowController.isVisible ||
            workout.isVisible
        NSApp.setActivationPolicy(hasVisibleWindow ? .regular : .accessory)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let inviteURL = urls.first,
              let token = PackStore.shared.handle(url: inviteURL)
        else { return }
        packWindowController.present(invite: token)
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        let eventId = (response.notification.request.content.userInfo["event_id"] as? NSNumber)?
            .int64Value
        completionHandler()
        Task { @MainActor [weak self] in
            switch actionIdentifier {
            case ReminderNotification.start:
                self?.workout.present()
            case UNNotificationDefaultActionIdentifier:
                if categoryIdentifier == PackNotification.category {
                    self?.packWindowController.present()
                } else {
                    self?.workout.present()
                }
            case ReminderNotification.snooze:
                self?.postBanner(after: 15 * 60)
            case ReminderNotification.skip, UNNotificationDismissActionIdentifier:
                break
            case PackNotification.cheer:
                guard let eventId,
                      let activity = PackStore.shared.snapshot?.activities.first(
                          where: { $0.id == eventId }
                      )
                else { return }
                await PackStore.shared.toggleReaction(kind: .cheer, activity: activity)
            case PackNotification.open:
                self?.packWindowController.present()
            default:
                break
            }
        }
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
