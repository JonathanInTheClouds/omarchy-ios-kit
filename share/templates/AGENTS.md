# iOS app built on Linux with xtool

Instructions for coding agents (and people) working on this app.

This is an xtool (SwiftPM) iOS app, developed on Linux (Omarchy) and run on a
real iPhone over USB. There's no Xcode and no simulator. Before changing the
build, run or debug setup, read the docs installed with the kit:
- `~/.local/share/ios-run/docs/README.md`: setup, daily use, troubleshooting;
- `~/.local/share/ios-run/docs/HOW-IT-WORKS.md`: how the tools work, hot
  reload in detail, and every known trap.

## Running
- `ios-run --auto-live` (VS Code: F6 or Ctrl+Shift+B; SUPER+R with the
  optional Omarchy keys): build, install, launch, show `print()` output;
  live swaps if the app is set up for them.
- `ios-run-dev` (VS Code: F5 or Ctrl+Alt+D; SUPER+SHIFT+R): debug run
  (lldb in the terminal, or VS Code's debugger).
- `ios-run --help` lists every option. Keep the phone unlocked with the app
  open; SwiftUI only runs `body` while the app is on screen.
- Bundle ID and other app settings are in `xtool.yml`. On the phone, xtool
  adds a team prefix to the installed ID (`XTL-xxxxxxxx.<bundle ID>`).

<!-- hot-reload -->
## Hot reload: every SwiftUI view needs two lines
This app uses the `HotReload` package (`Package.swift`: a path dependency on
`~/.local/share/ios-run/hot-reload/HotReload` and the debug-only
`-Xlinker -interposable` link flag). Saved `.swift` files are swapped into the
running app in under a second, and `@State` is kept.

**Every SwiftUI `View` struct you create or edit must have both of these**,
or it won't update live:
```swift
import HotReload

struct SomeView: View {
    @ObserveHotReload private var hotReload   // re-run body after each swap

    var body: some View {
        VStack { ... }
        .hotReloadable()                      // always the LAST modifier of body
    }
}
```
- `.hotReloadable()` keeps body's type `AnyView` so edits can change the view
  tree. `@ObserveHotReload` makes SwiftUI re-run the new body after a swap.
- Don't remove them as clutter: they compile to nothing in release and
  TestFlight builds.
- Edits inside existing functions, computed properties and view bodies swap
  live.
- New or deleted files, new types, new or removed stored properties,
  changed struct layouts, and `Package.swift` changes need a normal run.
  `ios-run --live` reruns by itself for files and Package.swift; for the
  rest, run again (F6 / SUPER+R).
- Methods of classes (final or not, including subclass overrides) and
  protocol methods swap too.
- **One type per file: put each view and each model in its own file.** A swap
  carries its own copy of every type *declared in the edited file*: `is`/`as?`
  checks on values made before the swap fail, and a SwiftUI subview declared
  in the edited file may lose its `@State` on each swap. Types from other files
  are unaffected.
- `static`/global state declared in the edited file is kept across swaps,
  but a *changed initial value* only applies after a normal run.
- Files that declare an `@Observable` type always get a normal run instead
  of a swap (a swap would silently stop observation, so the UI wouldn't
  update). `ios-run --live` does this by itself.
- If an edit changes *what kind of view* a `some View` function returns (a
  helper or modifier adding or removing a modifier or container, or a body
  without `.hotReloadable()`), the app refuses the swap and `ios-run --live`
  runs it again by itself. Changing only values (text, colours, numbers)
  swaps normally. Generic helpers (`func card<C: View>(...) -> some View`)
  are checked too.
- Don't edit `Package.swift`'s HotReload or `-interposable` lines unless
  asked. To set up another app: `~/.local/share/ios-run/hot-reload/enable-in-package.py`.
<!-- /hot-reload -->

## Conventions
- Never commit signing material: `*.p8`, `*.p12`, `*.cer`,
  `*.mobileprovision` (already in `.gitignore`).
