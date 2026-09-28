# Lockbox

A folder that needs your fingerprint. That's the whole app.

Right-click a folder, choose **Encrypt with Lockbox**, and it becomes a locked folder. Double-click it, touch the sensor, and it opens like any other folder. Leave it and it locks itself behind you.

No accounts, subscriptions or settings screen.

## Install

You'll need a Mac with Touch ID (or Apple Watch unlock, or just your login password) and Xcode or the Command Line Tools.

```sh
git clone https://github.com/paul-bokelman/lockbox.git
cd lockbox
./build.sh install
```

That builds `Lockbox.app`, puts it in `~/Applications`, and tells Finder about it.

## Use

- **Encrypt:** right-click a folder → Quick Actions (or Services) → **Encrypt with Lockbox**. Pick a recovery password. The folder becomes a locked folder and the original goes to the Trash.
- **Open:** double-click it, use Touch ID. It opens in place, Back button and all.
- **Lock:** go back out of it or close the window. It also locks when your Mac sleeps or the screen locks, or from the lock icon in the menu bar.

The first time, macOS asks whether Lockbox can control Finder. Say yes. That's how it knows you've left the folder, not how it reads your diary.

Lockbox only runs while a vault is open. The rest of the time it isn't running at all.

## How it works

A vault is a `Name.lockbox` package, and Finder hides the extension. Inside:

- `vault.sparsebundle`: an AES-256 encrypted APFS disk image made by macOS's own `hdiutil`. Its password is your recovery password.
- `lockbox.json`: that same password, sealed to a key in your Mac's Secure Enclave. The key never leaves the chip and won't work without Touch ID or your login password.

Lockbox is just the glue: Apple wrote the crypto, and there's no homemade encryption here.

## Lose the app, keep your files

No Lockbox, or a different Mac? Right-click the vault → **Show Package Contents** → double-click `vault.sparsebundle` → enter the recovery password. That's stock macOS.

When Lockbox opens a vault with the recovery password, it sets up Touch ID for that Mac.

## Fine print

- **The recovery password is the only way back in.** If you forget it and lose your Mac, the files are gone for good.
- **Keep a Finder window on it while you work.** It locks the moment no window shows it, even if another app still has one of its files open. A minimized window counts.
- **Sleep and screen lock force it shut.** Save first.
- **It protects files at rest.** While a vault is open, anything running as you can read it, same as any folder. Pair it with FileVault.
- **It hasn't had a security audit.** If you need that, use [Cryptomator](https://cryptomator.org).
