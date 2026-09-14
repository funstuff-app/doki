# <img src="packaging/icon/Doki.iconset/icon_128x128.png" alt="doki icon" width="52" /> doki

**Feel your Dock.** When an app bounces for attention, doki taps your trackpad
in time with it, so the bounce lands in your finger instead of your peripheral
vision.

## Install

Download **[Doki.dmg](https://github.com/funstuff-app/doki/releases/latest)**,
drag Doki to Applications, then run this once:

```sh
xattr -dr com.apple.quarantine /Applications/Doki.app
```

macOS blocks apps that aren't signed with a paid Apple Developer certificate.
That command clears the download flag. Then open Doki from Applications.

Or with Homebrew:

```sh
brew tap funstuff-app/doki
brew install --cask funstuff-app/doki/doki
xattr -dr com.apple.quarantine /Applications/Doki.app
```

Doki lives in the menu bar with no Dock icon, and starts working immediately.

## Using it

Nothing to configure. Any app that bounces gets tapped, however many bounce at
once, and the taps stop when the bouncing does.

- **Hover a bouncing icon** to dismiss it, exactly like normal. The taps stop
  with it.
- **test tap** in the menu makes a demo icon bounce so you can feel it right
  away without waiting for something to want your attention.
- Grant **Accessibility** once when asked. It is used for one thing: noticing
  which Dock icon your cursor is over, so hover-to-dismiss works.

## Requirements

- macOS 13 or later
- A Force Touch trackpad: the built-in one, or a paired Magic Trackpad. On a
  wireless Magic Trackpad you get one tap per bounce; the built-in trackpad
  gets the full three-tap pattern of the bounce.

## Why it feels right

The tap timing comes from the Dock itself. Every time the icon hits the bottom
of its bounce, you get a tap, and it fades as the bounce settles. It stays in
time with what you're watching.

[`BUILDING.md`](BUILDING.md) has the build instructions.

## License

MIT. Copyright (c) 2026 meatspace2k4.
