# macOS Ghostty Application

- Use `swiftlint` for formatting and linting Swift code.
- If code outside of `macos/` directory is modified, use
  `zig build -Demit-macos-app=false` before building the macOS app to update
  the underlying Ghostty library.
- Use `macos/build.nu` to build the macOS app, do not use `zig build`
  (except to build the underlying library as mentioned above).
  - Build: `macos/build.nu [--scheme Ghostty] [--configuration Debug] [--action build]`
  - Output: `macos/build/<configuration>/Ghostty.app` (e.g. `macos/build/Debug/Ghostty.app`)
- Run unit tests directly with `macos/build.nu --action test`

## AppleScript

- The AppleScript scripting definition is in `macos/Ghostty.sdef`.
- Guard AppleScript entry points and object accessors with the
  `macos-applescript` configuration (use `NSApp.isAppleScriptEnabled`
  and `NSApp.validateScript(command:)` where applicable).
- In `macos/Ghostty.sdef`, keep top-level definitions in this order:
  1. Classes
  2. Records
  3. Enums
  4. Commands
- Test AppleScript support:
  (1) Build with `macos/build.nu`
  (2) Launch and activate the app via osascript using the absolute path
      to the built app bundle:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to activate'`
  (3) Wait a few seconds for the app to fully launch and open a terminal.
  (4) Run test scripts with `osascript`, always targeting the app by
      its absolute path (not by name) to avoid calling the wrong
      application.
  (5) When done, quit via:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to quit'`

## Window Chrome

The macOS app draws its own chrome, so several config keys no longer apply here:

- `macos-titlebar-style` and `window-theme` are ignored. There is one window
  style: hidden titlebar, traffic lights over the sidebar, and a SwiftUI tab
  strip in place of the native tab bar.
- `theme` is overridden by `share/ghostty/app-override.conf`, which pins the
  bundled `Cyrene Light` and `Cyrene Dark` themes so the whole window follows
  the system appearance.
- An explicit `background`, `foreground`, or `palette` in the user's config
  still wins over the bundled theme, because Ghostty replays user settings on
  top of a theme.
- `background-opacity`, `background-blur-radius`, and `macos-window-buttons`
  still take effect.

App chrome colors live in `macos/Sources/Features/AppTheme/`. Use `AppPalette`
from the environment rather than `.primary` / `.secondary` / `Color.accentColor`.
