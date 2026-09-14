# Building Doki

## Build and run

```sh
swift build
.build/debug/Doki watch        # tap for any app that bounces
.build/debug/Doki demo         # self-contained two-bouncer demo
.build/debug/Doki tap-test     # cycle Taptic patterns
.build/debug/Doki debug        # list multitouch devices + sweep actuation IDs
```

## Package the app

```sh
packaging/sign-setup.sh          # once: create a stable self-signed identity
packaging/make-app.sh            # → dist/Doki.app + dist/Doki.dmg
```

Open the DMG, drag Doki to Applications and launch it. It appears in the menu
bar with no Dock icon. Grant Accessibility once, for hover-to-dismiss.

## Notes

Uses private Apple frameworks (MultitouchSupport, LaunchServices) via `dlopen`.
Unsupported API: behavior may break in any macOS update.
