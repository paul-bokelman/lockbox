# Lockbox

A folder that needs your fingerprint.

Right-click a folder to encrypt it. Double-click it and use Touch ID to open it. Leave it and it locks itself.

## Install

1. Download **Lockbox.zip** from the [latest release](https://github.com/paul-bokelman/lockbox/releases/latest).
2. Unzip it, drag **Lockbox** into Applications, and open it once.
3. If macOS blocks it, go to **System Settings → Privacy & Security → Open Anyway**.

It needs macOS 14 or later. Or build it yourself with `./build.sh install`.

## Use

- **Encrypt:** right-click a folder → Quick Actions (or Services) → **Encrypt with Lockbox**, then set a recovery password.
- **Open:** double-click it and use Touch ID.
- **Lock:** leave the folder or close its window. It also locks when your Mac sleeps or the screen locks.

The first time, allow Lockbox to control Finder. That's how it knows you've left.

## Under the hood

A vault is an AES-256 encrypted disk image, and its password is your recovery password. A copy of that password is sealed in your Mac's Secure Enclave, which only releases it after Touch ID. All the crypto is Apple's.

**No Lockbox?** Right-click the vault → Show Package Contents → open `vault.sparsebundle` → enter the recovery password.

## Fine print

- Forget the recovery password and lose your Mac, and your files are gone. Nobody can get them back.
- It locks the moment no Finder window shows it, even if an app still has one of its files open.
- Sleep and screen lock force it shut, so save first.
