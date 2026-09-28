import AppKit
import LocalAuthentication

/// Lockbox runs only while it has work: encrypting a folder, or keeping an unlocked vault watched.
/// With nothing left to do it quits, so nothing sits in the menu bar while every vault is locked.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let autoLock = AutoLock()
    private var statusItem: NSStatusItem!
    /// Flows in progress (a password dialog, an encryption, a Touch ID prompt). Lockbox won't quit during one.
    private var busy = 0
    private var receivedWork = false

    /// Setup happens here because Finder's open event can arrive before didFinishLaunching.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "lock.open.fill", accessibilityDescription: "Lockbox")
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        autoLock.onChange = { [weak self] in self?.refresh() }
        autoLock.onFinderPermissionDenied = { [weak self] in self?.explainFinderPermission() }
        autoLock.adoptMountedVaults()
        if !autoLock.unlocked.isEmpty { receivedWork = true }
        refresh()

        let lockEverything: (Notification) -> Void = { [weak self] _ in self?.autoLock.lockAllNow() }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockEverything)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockEverything)
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lockEverything)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened directly rather than through a vault or the Finder menu: explain how to use it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard !self.receivedWork else { return }
            self.showMessage(
                "Lockbox works from Finder",
                "To encrypt a folder, right-click it and choose Quick Actions (or Services) → Encrypt with Lockbox.\n\nTo open a vault, double-click it."
            )
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        autoLock.lockAllNow()
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedWork = true
        for url in urls where url.pathExtension == "lockbox" { unlock(url) }
        encrypt(urls.filter { $0.pathExtension != "lockbox" })
    }

    /// Finder's "Encrypt with Lockbox" menu item.
    @objc func encryptFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receivedWork = true
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // Return to Finder right away; the dialogs come from Lockbox.
        DispatchQueue.main.async { self.encrypt(urls) }
    }

    // MARK: Encrypt

    private func encrypt(_ folders: [URL]) {
        guard !folders.isEmpty else { return }
        busy += 1
        encryptNext(folders[...])
    }

    private func encryptNext(_ folders: ArraySlice<URL>) {
        guard let folder = folders.first else {
            busy -= 1
            refresh()
            return
        }
        let rest = folders.dropFirst()
        let name = folder.lastPathComponent

        if let problem = Vault.problem(encrypting: folder) {
            showMessage("Can't encrypt “\(name)”", problem)
            return encryptNext(rest)
        }
        guard let password = askNewPassword(for: name) else { return encryptNext(rest) }

        let progress = ProgressPanel(message: "Encrypting “\(name)”…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Vault.create(from: folder, password: password) }
            DispatchQueue.main.async {
                progress.close()
                switch result {
                case .success(let created):
                    created.vault.showAsLockedFolder()
                    NSWorkspace.shared.activateFileViewerSelecting([created.vault.url])
                    if !created.trashedOriginal {
                        self.showMessage(
                            "“\(name)” is encrypted",
                            "The original folder couldn't be moved to the Trash, so delete it yourself once you've checked the vault opens."
                        )
                    }
                case .failure(let error):
                    self.showMessage("Couldn't encrypt “\(name)”", error.localizedDescription)
                }
                self.encryptNext(rest)
            }
        }
    }

    // MARK: Unlock

    private func unlock(_ url: URL) {
        let vault = Vault(url: url)
        vault.showAsLockedFolder()
        if let mountPoint = autoLock.mountPoint(for: vault) {
            Finder.open(mountPoint, from: vault)
            return
        }
        busy += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let mountPoint = self.mountVault(vault)
            DispatchQueue.main.async {
                if let mountPoint {
                    self.autoLock.track(vault, mountPoint: mountPoint)
                    Finder.open(mountPoint, from: vault)
                }
                self.busy -= 1
                self.refresh()
            }
        }
    }

    /// Runs off the main thread so Touch ID and hdiutil don't block the app; dialogs hop to main.
    private func mountVault(_ vault: Vault) -> String? {
        let header: Header
        do {
            header = try vault.readHeader()
        } catch {
            onMain { self.showMessage("Couldn't open “\(vault.name)”", error.localizedDescription) }
            return nil
        }

        var password: String?
        switch touchIDPassword(header, vaultName: vault.name) {
        case .password(let unsealed): password = unsealed
        case .cancelled: return nil
        case .unavailable: break
        }

        let usingRecoveryPassword = password == nil
        var problem: String?
        while true {
            if password == nil {
                password = onMain { self.askRecoveryPassword(for: vault.name, problem: problem) }
                if password == nil { return nil }
            }
            do {
                let mountPoint = try DiskImage.attach(vault.imageURL, password: password!)
                onMain { DiskImage.setFolderIcon(on: mountPoint) }
                // Set Touch ID up for this Mac, e.g. after the vault moved here from another one.
                if usingRecoveryPassword, let header = try? Enclave.seal(password!) { try? vault.writeHeader(header) }
                return mountPoint
            } catch LockboxError.wrongPassword {
                password = nil
                problem = "That password didn't work. Try again."
            } catch {
                onMain { self.showMessage("Couldn't open “\(vault.name)”", error.localizedDescription) }
                return nil
            }
        }
    }

    private enum TouchIDResult {
        case password(String)
        case cancelled
        case unavailable
    }

    private func touchIDPassword(_ header: Header, vaultName: String) -> TouchIDResult {
        guard Enclave.canOpen(header) else { return .unavailable }

        let context = LAContext()
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock “\(vaultName)”") { success, error in
            if !success { failure = error }
            done.signal()
        }
        done.wait()

        if let failure = failure as? LAError {
            switch failure.code {
            case .userCancel, .appCancel, .systemCancel: return .cancelled
            default: return .unavailable
            }
        }
        if failure != nil { return .unavailable }
        guard let password = try? Enclave.open(header, context: context) else { return .unavailable }
        return .password(password)
    }

    // MARK: Menu bar

    private func refresh() {
        statusItem.isVisible = !autoLock.unlocked.isEmpty
        quitIfIdle()
    }

    private func quitIfIdle() {
        guard receivedWork else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.busy == 0, self.autoLock.unlocked.isEmpty, NSApp.modalWindow == nil {
                NSApp.terminate(nil)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for vault in autoLock.unlocked {
            let item = NSMenuItem(title: "Lock “\(vault.vault.name)”", action: #selector(lockFromMenu(_:)), keyEquivalent: "")
            item.representedObject = vault.mountPoint
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Lock All and Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func lockFromMenu(_ sender: NSMenuItem) {
        guard let mountPoint = sender.representedObject as? String else { return }
        autoLock.lock(mountPoint, force: false) { locked in
            guard !locked else { return }
            let alert = NSAlert()
            alert.messageText = "Something still has files open in this vault"
            alert.informativeText = "Close them first, or force it to lock. Unsaved changes in those files may be lost."
            alert.addButton(withTitle: "Force Lock")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { self.autoLock.lock(mountPoint, force: true) }
        }
    }

    // MARK: Dialogs

    private func askNewPassword(for name: String) -> String? {
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "Encrypt “\(name)”?"
            alert.informativeText = problem ?? "You'll open it with Touch ID. Also set a recovery password: it's the only way in without Touch ID on this Mac, and it can't be reset if you forget it."
            let password = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
            password.placeholderString = "Recovery password"
            let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            confirmation.placeholderString = "Confirm recovery password"
            password.nextKeyView = confirmation
            let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
            fields.addSubview(password)
            fields.addSubview(confirmation)
            alert.accessoryView = fields
            alert.addButton(withTitle: "Encrypt")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = password
            NSApp.activate(ignoringOtherApps: true)

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if password.stringValue.count < 8 {
                problem = "Use at least 8 characters for the recovery password."
            } else if password.stringValue != confirmation.stringValue {
                problem = "The passwords didn't match. Try again."
            } else {
                return password.stringValue
            }
        }
    }

    private func askRecoveryPassword(for name: String, problem: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = "Unlock “\(name)”"
        alert.informativeText = problem ?? "Touch ID isn't available for this vault. Enter its recovery password."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Recovery password"
        alert.accessoryView = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    private func explainFinderPermission() {
        let alert = NSAlert()
        alert.messageText = "Allow Lockbox to see Finder windows"
        alert.informativeText = "To lock a vault when you close its window, Lockbox needs permission to control Finder (System Settings → Privacy & Security → Automation).\n\nUntil then, vaults still lock when your Mac sleeps or locks, or from the lock icon in the menu bar."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
    }

    private func showMessage(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}

final class ProgressPanel {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 340, height: 90), styleMask: [.titled], backing: .buffered, defer: false
    )

    init(message: String) {
        let label = NSTextField(labelWithString: message)
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        bar.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        panel.title = "Lockbox"
        panel.contentView = stack
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel.close() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
