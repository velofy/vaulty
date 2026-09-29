<p align="center">
  <img src="docs/assets/logo.png" alt="Vaulty" width="360"/>
</p>

# Vaulty

A transparent work-in-progress screen lock for macOS. Password to unlock. Your terminals stay visible and keep running behind it.

[![Release](https://img.shields.io/github/v/release/velofy/vaulty)](https://github.com/velofy/vaulty/releases/latest)
[![License: MIT](https://img.shields.io/github/license/velofy/vaulty)](LICENSE)

**Docs: https://velofy.co/vaulty/**

> Vaulty is an overlay window, not a macOS system lock. It stores its password in plain text and is meant to stop casual interference, not a determined attacker. Read the [limitations](https://velofy.co/vaulty/limitations/).

## Install

Download `Vaulty-x.y.z-macos.zip` from [Releases](https://github.com/velofy/vaulty/releases/latest), unzip, drag **Vaulty.app** to Applications (or `~/Applications`), then open it. Requires macOS 13 or later.

The build is not notarized (that needs a paid Apple Developer account), so on first launch macOS says "Apple could not verify Vaulty is free of malware". Click **Done** (never "Move to Bin"), then open **System Settings > Privacy & Security** and click **Open Anyway**, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine ~/Applications/Vaulty.app
```

Grant **Accessibility** when prompted, so Vaulty can block Cmd+Tab and other shortcuts while locked. Details: [Installation](https://velofy.co/vaulty/installation/).

Build from source:

```sh
git clone https://github.com/velofy/vaulty.git
cd vaulty
make run       # build, install to ~/Applications, launch
make package   # zip for distribution: dist/Vaulty-VERSION-macos.zip
```

## Use

| Action | How |
|---|---|
| Lock | **Cmd+Shift+L** or menu bar ◐, Lock Screen |
| Unlock | Type the password, press Enter |
| Control Panel | Menu bar ◐, Control Panel... |
| Quit | Menu bar ◐, Quit Vaulty (disabled while locked) |

The default password on first launch is `anishisagentic`. It is public, so change it in the Control Panel first.

Settings are stored at `~/Library/Application Support/com.anishfyi.vaulty/settings.json`.

## Features

- Transparent overlay on every display; the desktop stays live underneath
- Password unlock only, no Escape route
- Global shortcut Cmd+Shift+L
- Control Panel for password, lock message and dim opacity
- Menu bar app, local-only settings

## Documentation

- [Overview](https://velofy.co/vaulty/)
- [Installation](https://velofy.co/vaulty/installation/)
- [First run and permissions](https://velofy.co/vaulty/first-run/)
- [Using Vaulty](https://velofy.co/vaulty/using-vaulty/)
- [How the lock works](https://velofy.co/vaulty/how-it-works/)
- [Limitations and security notes](https://velofy.co/vaulty/limitations/)
- [Troubleshooting](https://velofy.co/vaulty/troubleshooting/)
- [Changelog](https://velofy.co/vaulty/changelog/)

## Contributing

Issues and pull requests are welcome. The app is a single file, `Sources/main.swift`, built by the `Makefile` with `swiftc`.

## Release

Push a `v*` tag. CI builds the macOS zip and attaches it to a GitHub Release.

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

## License

MIT. See [LICENSE](LICENSE).
