import Cocoa

/// Tracks when the wallpaper cannot be seen (screens asleep, session switched away, screen locked)
/// and whether the battery saver should cap the frame rate. The app pushes the result to every scene.
final class PowerMonitor {
    enum Saver: String { case auto, on, off }

    var onChange: (() -> Void)?
    /// Fires once, before `onChange`, when the wallpaper is about to become invisible (lock, display
    /// sleep, fast user switch) and the scene is still running: the app grabs the frame for the lock screen.
    var onHide: (() -> Void)?
    private(set) var screensAsleep = false
    private(set) var sessionInactive = false
    private(set) var locked = false

    var saver: Saver {
        get { Saver(rawValue: UserDefaults.standard.string(forKey: "batterySaver") ?? "auto") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "batterySaver"); onChange?() }
    }
    /// "Pause Animation" in the menu / ⌃⌥P.
    var userPaused = false { didSet { onChange?() } }
    var forcedPause: Bool { screensAsleep || sessionInactive || locked || userPaused }
    var saverActive: Bool {
        switch saver {
        case .on: return true
        case .off: return false
        case .auto: return ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
    /// 0 means "no global cap"; scenes still apply their own CONFIG.fps.
    var maxFps: Int { saverActive ? 15 : 0 }

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ center: NotificationCenter, _ body: @escaping () -> Void) {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                let wasHidden = self.forcedPause
                body()
                if !wasHidden, self.forcedPause, !self.userPaused { self.onHide?() }
                self.onChange?()
            }
        }
        on(NSWorkspace.screensDidSleepNotification, ws) { [weak self] in self?.screensAsleep = true }
        on(NSWorkspace.screensDidWakeNotification, ws) { [weak self] in self?.screensAsleep = false }
        on(NSWorkspace.sessionDidResignActiveNotification, ws) { [weak self] in self?.sessionInactive = true }
        on(NSWorkspace.sessionDidBecomeActiveNotification, ws) { [weak self] in self?.sessionInactive = false }
        let dn = DistributedNotificationCenter.default()
        on(Notification.Name("com.apple.screenIsLocked"), dn) { [weak self] in self?.locked = true }
        on(Notification.Name("com.apple.screenIsUnlocked"), dn) { [weak self] in self?.locked = false }
        on(.NSProcessInfoPowerStateDidChange, NotificationCenter.default) {}
    }
}
