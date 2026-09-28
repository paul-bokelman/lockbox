import AppKit
import CryptoKit
import LocalAuthentication
import Security

enum LockboxError: LocalizedError {
    case command(String)
    case wrongPassword
    case notAllowed(String)
    case copyMismatch(String)
    case missingKeyFile

    var errorDescription: String? {
        switch self {
        case .command(let message): return message
        case .wrongPassword: return "Wrong password."
        case .notAllowed(let reason): return reason
        case .copyMismatch(let path): return "The copy of “\(path)” didn't match the original, so nothing was changed."
        case .missingKeyFile: return "This vault is missing its lockbox.json key file."
        }
    }
}

/// The password that opens a vault's disk image, sealed so only this Mac's Secure Enclave can open it,
/// and only after Touch ID (or the login password).
struct Header: Codable {
    var version = 1
    var enclaveKey: Data
    var ephemeralPublicKey: Data
    var sealedPassword: Data
}

/// A `.lockbox` package: an encrypted APFS sparsebundle plus the header that unlocks it with Touch ID.
/// The sparsebundle's own password is the recovery password, so the vault opens in stock macOS too.
struct Vault {
    let url: URL

    var name: String { url.deletingPathExtension().lastPathComponent }
    var imageURL: URL { url.appendingPathComponent("vault.sparsebundle") }
    var headerURL: URL { url.appendingPathComponent("lockbox.json") }

    func readHeader() throws -> Header {
        guard let data = try? Data(contentsOf: headerURL) else { throw LockboxError.missingKeyFile }
        return try JSONDecoder().decode(Header.self, from: data)
    }

    /// Makes Finder show the vault as a locked folder with just its name. The icon is stamped on the
    /// vault itself rather than relying on the file type's icon, which macOS caches aggressively and
    /// which other Macs without Lockbox don't have.
    func showAsLockedFolder() {
        var url = url
        var values = URLResourceValues()
        values.hasHiddenExtension = true
        try? url.setResourceValues(values)

        guard !FileManager.default.fileExists(atPath: url.appendingPathComponent("Icon\r").path),
              let iconURL = Bundle.main.url(forResource: "LockedFolder", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL)
        else { return }
        NSWorkspace.shared.setIcon(icon, forFile: url.path)
    }

    func writeHeader(_ header: Header) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(header).write(to: headerURL, options: .atomic)
    }

    /// Why `folder` can't be encrypted, or nil if it can.
    static func problem(encrypting folder: URL) -> String? {
        let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isVolumeKey])
        let path = folder.standardizedFileURL.path
        if values?.isDirectory != true { return "Only folders can be encrypted." }
        if values?.isVolume == true || path == "/" || path == NSHomeDirectory() {
            return "Lockbox encrypts folders, not whole drives or your home folder."
        }
        if folder.pathExtension == "lockbox" { return "“\(folder.lastPathComponent)” is already a vault." }
        let destination = vaultURL(for: folder)
        if FileManager.default.fileExists(atPath: destination.path) {
            return "There's already a vault named “\(folder.lastPathComponent)” next to this folder."
        }
        if !FileManager.default.isWritableFile(atPath: folder.deletingLastPathComponent().path) {
            return "Lockbox can't write to the folder that contains “\(folder.lastPathComponent)”."
        }
        return nil
    }

    static func vaultURL(for folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".lockbox")
    }

    /// Copies `folder` into a new vault next to it, checks the copy, then moves the original to the Trash.
    /// Returns the vault and whether the original made it to the Trash.
    static func create(from folder: URL, password: String) throws -> (vault: Vault, trashedOriginal: Bool) {
        let fileManager = FileManager.default
        let name = folder.lastPathComponent
        let partial = folder.deletingLastPathComponent().appendingPathComponent(".\(name).lockbox.partial")
        let vault = Vault(url: partial)
        var mountPoint: String?

        do {
            try? fileManager.removeItem(at: partial)
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: false)
            try DiskImage.create(at: vault.imageURL, volumeName: name, password: password)
            let mounted = try DiskImage.attach(vault.imageURL, password: password)
            mountPoint = mounted
            fileManager.createFile(atPath: mounted + "/.metadata_never_index", contents: nil)
            DiskImage.setFolderIcon(on: mounted)
            try runChecked("/usr/bin/ditto", [folder.path, mounted])
            try verifyCopy(from: folder.path, to: mounted)
            try DiskImage.detachPatiently(mounted)
            mountPoint = nil
            try vault.writeHeader(Enclave.seal(password))
            try fileManager.moveItem(at: partial, to: vaultURL(for: folder))
        } catch {
            if let mountPoint { _ = DiskImage.detach(mountPoint, force: true) }
            try? fileManager.removeItem(at: partial)
            throw error
        }

        let trashed = (try? fileManager.trashItem(at: folder, resultingItemURL: nil)) != nil
        return (Vault(url: vaultURL(for: folder)), trashed)
    }

    private static func verifyCopy(from source: String, to destination: String) throws {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(atPath: source) else { throw LockboxError.copyMismatch(source) }
        while let relative = walker.nextObject() as? String {
            let original = try fileManager.attributesOfItem(atPath: source + "/" + relative)
            guard let copy = try? fileManager.attributesOfItem(atPath: destination + "/" + relative),
                  original[.type] as? FileAttributeType == copy[.type] as? FileAttributeType,
                  original[.type] as? FileAttributeType != .typeRegular
                    || (original[.size] as? UInt64) == (copy[.size] as? UInt64)
            else { throw LockboxError.copyMismatch(relative) }
        }
    }
}

enum Enclave {
    private static let info = Data("lockbox v1".utf8)

    /// Seals `password` to a fresh Secure Enclave key that needs Touch ID or the login password to use.
    static func seal(_ password: String) throws -> Header {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error
        ) else { throw error!.takeRetainedValue() as Error }

        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
        let sealed = try AES.GCM.seal(Data(password.utf8), using: symmetricKey(secret))
        return Header(
            enclaveKey: enclaveKey.dataRepresentation,
            ephemeralPublicKey: ephemeral.publicKey.x963Representation,
            sealedPassword: sealed.combined!
        )
    }

    /// Whether this Mac's Secure Enclave can use the header's key. False for vaults sealed on another Mac.
    static func canOpen(_ header: Header) -> Bool {
        SecureEnclave.isAvailable
            && (try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: header.enclaveKey)) != nil
    }

    /// Opens the sealed password using an LAContext that has already passed Touch ID.
    static func open(_ header: Header, context: LAContext) throws -> String {
        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            dataRepresentation: header.enclaveKey, authenticationContext: context
        )
        let secret = try enclaveKey.sharedSecretFromKeyAgreement(
            with: P256.KeyAgreement.PublicKey(x963Representation: header.ephemeralPublicKey)
        )
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: header.sealedPassword), using: symmetricKey(secret))
        guard let password = String(data: data, encoding: .utf8) else { throw LockboxError.missingKeyFile }
        return password
    }

    private static func symmetricKey(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
    }
}

enum DiskImage {
    /// 1 TB is just the ceiling; a sparsebundle only takes the space its files use.
    static func create(at url: URL, volumeName: String, password: String) throws {
        try hdiutil(
            ["create", "-size", "1t", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-encryption", "AES-256",
             "-stdinpass", "-volname", volumeName, url.path],
            input: password
        )
    }

    /// Mounts the image and returns its mount point. It's hidden from the Desktop and sidebar so the
    /// vault feels like a folder rather than a drive.
    static func attach(_ url: URL, password: String) throws -> String {
        let output = try hdiutil(["attach", "-stdinpass", "-plist", "-noautoopen", "-nobrowse", url.path], input: password)
        let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw LockboxError.command("The vault's disk image attached but didn't mount.")
        }
        return mountPoint
    }

    /// Shows the open vault as a folder with an open lock instead of a generic drive.
    static func setFolderIcon(on mountPoint: String) {
        guard !FileManager.default.fileExists(atPath: mountPoint + "/.VolumeIcon.icns"),
              let url = Bundle.main.url(forResource: "UnlockedFolder", withExtension: "icns"),
              let icon = NSImage(contentsOf: url)
        else { return }
        NSWorkspace.shared.setIcon(icon, forFile: mountPoint)
    }

    static func detach(_ mountPoint: String, force: Bool) -> Bool {
        (try? hdiutil(["detach", mountPoint] + (force ? ["-force"] : []))) != nil
    }

    /// Spotlight or fseventsd can hold a fresh volume busy for a moment, so retry before forcing.
    static func detachPatiently(_ mountPoint: String) throws {
        for _ in 0..<5 {
            if detach(mountPoint, force: false) { return }
            Thread.sleep(forTimeInterval: 1)
        }
        if !detach(mountPoint, force: true) { throw LockboxError.command("Couldn't eject “\(mountPoint)”.") }
    }

    /// Every attached disk image that has a mounted volume.
    static func attached() -> [(image: String, mountPoint: String)] {
        guard let output = try? hdiutil(["info", "-plist"]),
              let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return [] }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]],
                  let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
            else { return nil }
            return (path, mountPoint)
        }
    }

    @discardableResult
    private static func hdiutil(_ arguments: [String], input: String? = nil) throws -> Data {
        let result = try run("/usr/bin/hdiutil", arguments, input: input)
        guard result.status == 0 else {
            if result.error.contains("Authentication error") { throw LockboxError.wrongPassword }
            throw LockboxError.command(result.error.isEmpty ? "hdiutil \(arguments[0]) failed." : result.error)
        }
        return result.output
    }
}

func isMounted(_ mountPoint: String) -> Bool {
    var info = statfs()
    guard statfs(mountPoint, &info) == 0 else { return false }
    let mountedOn = withUnsafeBytes(of: &info.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    return mountedOn == mountPoint
}

struct CommandResult {
    let status: Int32
    let output: Data
    let error: String
}

/// Runs a tool, passing secrets on stdin so they never show up in `ps`.
func run(_ path: String, _ arguments: [String], input: String? = nil) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    try process.run()

    if let input {
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
    }
    var errorData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()

    let error = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return CommandResult(status: process.terminationStatus, output: output, error: error)
}

func runChecked(_ path: String, _ arguments: [String]) throws {
    let result = try run(path, arguments)
    guard result.status == 0 else {
        throw LockboxError.command(result.error.isEmpty ? "\(path) failed." : result.error)
    }
}
