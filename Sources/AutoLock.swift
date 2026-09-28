import AppKit

/// Tracks unlocked vaults and locks each one a few seconds after no Finder window shows it anymore.
final class AutoLock {
    struct Unlocked {
        let vault: Vault
        let mountPoint: String
        var lastSeen: Date
    }

    /// Time to let Finder open the vault's window after unlocking.
    private let graceAfterUnlock: TimeInterval = 8
    /// How long a vault can go without a Finder window before it locks.
    private let closeDelay: TimeInterval = 3

    private(set) var unlocked: [Unlocked] = []
    var onChange: () -> Void = {}
    var onFinderPermissionDenied: () -> Void = {}

    private var timer: Timer?
    private var locking: Set<String> = []
    private var warnedAboutPermission = false

    func track(_ vault: Vault, mountPoint: String) {
        unlocked.append(Unlocked(vault: vault, mountPoint: mountPoint, lastSeen: Date().addingTimeInterval(graceAfterUnlock)))
        startTimer()
        onChange()
    }

    func mountPoint(for vault: Vault) -> String? {
        let path = vault.url.resolvingSymlinksInPath().path
        return unlocked.first { $0.vault.url.resolvingSymlinksInPath().path == path }?.mountPoint
    }

    /// Picks up vaults left mounted by an earlier run, e.g. after a crash.
    func adoptMountedVaults() {
        for (image, mountPoint) in DiskImage.attached() {
            let image = URL(fileURLWithPath: image)
            let package = image.deletingLastPathComponent()
            guard image.lastPathComponent == "vault.sparsebundle", package.pathExtension == "lockbox",
                  mountPoint.hasPrefix("/Volumes/")
            else { continue }
            unlocked.append(Unlocked(vault: Vault(url: package), mountPoint: mountPoint, lastSeen: Date()))
        }
        if !unlocked.isEmpty { startTimer() }
    }

    /// Ejects the vault, tolerating the case where it's already gone.
    func lock(_ mountPoint: String, force: Bool, completion: ((Bool) -> Void)? = nil) {
        guard !locking.contains(mountPoint) else { return }
        locking.insert(mountPoint)
        DispatchQueue.global(qos: .userInitiated).async {
            let locked = DiskImage.detach(mountPoint, force: force) || !isMounted(mountPoint)
            DispatchQueue.main.async {
                self.locking.remove(mountPoint)
                if locked { self.unlocked.removeAll { $0.mountPoint == mountPoint } }
                self.onChange()
                completion?(locked)
            }
        }
    }

    /// Locks everything right now, even with files open. Used on sleep, screen lock and quit.
    func lockAllNow() {
        for vault in unlocked where DiskImage.detach(vault.mountPoint, force: true) || !isMounted(vault.mountPoint) {
            unlocked.removeAll { $0.mountPoint == vault.mountPoint }
        }
        onChange()
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let before = unlocked.count
        unlocked.removeAll { !locking.contains($0.mountPoint) && !isMounted($0.mountPoint) }
        if unlocked.count != before { onChange() }
        guard !unlocked.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }

        guard let windows = finderWindowPaths() else { return }
        let now = Date()
        for index in unlocked.indices {
            let mountPoint = unlocked[index].mountPoint
            if windows.contains(where: { $0 == mountPoint || $0.hasPrefix(mountPoint + "/") }) {
                unlocked[index].lastSeen = now
            } else if now.timeIntervalSince(unlocked[index].lastSeen) > closeDelay {
                // If something still has files open the eject fails; wait out another delay and retry.
                unlocked[index].lastSeen = now
                lock(mountPoint, force: false)
            }
        }
    }

    /// Paths of every open Finder window, or nil if Finder can't be asked.
    private func finderWindowPaths() -> [String]? {
        switch Finder.windowPaths() {
        case .success(let paths):
            return paths
        case .failure(let failure):
            if failure == .notPermitted, !warnedAboutPermission {
                warnedAboutPermission = true
                onFinderPermissionDenied()
            }
            return nil
        }
    }
}

/// Talks to Finder over Apple Events: which windows are open, and opening a vault in place.
enum Finder {
    enum Failure: Error {
        case notPermitted
        case other
    }

    private static let windowPathsScript = NSAppleScript(source: """
        with timeout of 3 seconds
            tell application "Finder"
                set paths to ""
                repeat with w in Finder windows
                    try
                        set paths to paths & POSIX path of (target of w as alias) & linefeed
                    end try
                end repeat
                return paths
            end tell
        end timeout
        """)!

    private static let frontWindowScript = NSAppleScript(source: """
        with timeout of 3 seconds
            tell application "Finder" to return POSIX path of (target of Finder window 1 as alias)
        end timeout
        """)!

    static func windowPaths() -> Result<[String], Failure> {
        run(windowPathsScript).map { $0.split(separator: "\n").map(String.init) }
    }

    /// Opens an unlocked vault the way double-clicking a folder does: in the Finder window it was
    /// double-clicked in, or in a new window when it was opened from the Desktop or elsewhere.
    static func open(_ mountPoint: String, from vault: Vault) {
        let parent = vault.url.deletingLastPathComponent().resolvingSymlinksInPath().path
        if case .success(let front) = run(frontWindowScript),
           URL(fileURLWithPath: front).resolvingSymlinksInPath().path == parent {
            let escaped = mountPoint.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let navigate = NSAppleScript(source: """
                set destination to POSIX file "\(escaped)" as alias
                tell application "Finder"
                    activate
                    set target of Finder window 1 to destination
                end tell
                """)!
            if case .success = run(navigate) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
    }

    private static func run(_ script: NSAppleScript) -> Result<String, Failure> {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return .failure(error[NSAppleScript.errorNumber] as? Int == -1743 ? .notPermitted : .other)
        }
        return .success(result.stringValue ?? "")
    }
}
