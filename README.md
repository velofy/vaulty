<p align="center">
  <img src="docs/assets/logo.png" alt="Vaulty" width="360"/>
</p>

<p align="center">
  <strong>Transparent WIP screen lock for macOS.</strong>
</p>

<p align="center">
  Your terminals stay visible and keep running. Nobody can click or type into them without the password. No Escape skip.
</p>

<p align="center">
  <a href="https://anishfyi.github.io/vaulty/">Website</a> ·
  <a href="https://github.com/anishfyi/vaulty/releases/latest">Download</a>
</p>

## Features

- Transparent overlay — desktop stays live underneath
- Password unlock only (no Escape hatch)
- **⌘⇧L** global shortcut to lock
- Control Panel to set password, lock message, and dim opacity
- Menu bar app (◐) — lightweight, local-only settings

## Install

Download **`Vaulty-x.y.z-macos.zip`** from [Releases](https://github.com/anishfyi/vaulty/releases/latest), unzip, drag **Vaulty.app** to Applications (or `~/Applications`), then open it.

Unsigned build — if macOS says it's damaged:

```sh
xattr -cr ~/Applications/Vaulty.app
# or:
xattr -cr /Applications/Vaulty.app
```

Then open normally. Grant **Accessibility** when prompted for full shortcut blocking (Cmd+Tab etc.).

## Use

| Action | How |
|---|---|
| Lock | **⌘⇧L** or menu bar ◐ → Lock Screen |
| Unlock | Type password → Enter |
| Control Panel | Menu bar ◐ → Control Panel… |
| Quit | Menu bar ◐ → Quit Vaulty (disabled while locked) |

Default password on first launch: `anishisagentic` — change it in the Control Panel.

Settings live at:

```
~/Library/Application Support/com.anishfyi.vaulty/settings.json
```

## Build from source

```sh
make run       # build, install to ~/Applications, launch
make package   # zip for distribution → dist/Vaulty-VERSION-macos.zip
```

## Release

Push a `v*` tag. CI builds the macOS zip and attaches it to a GitHub Release.

```sh
git tag v1.0.0
git push origin v1.0.0
```

## License

MIT
