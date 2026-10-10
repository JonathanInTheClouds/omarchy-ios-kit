# omarchy-ios-kit

**Build, run, debug and live-edit iPhone apps on Linux (Omarchy). No Mac
needed.**

This kit turns a Linux machine with [omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev)
(which installs Swift, Apple's iOS SDK and [xtool](https://github.com/xtool-org/xtool))
into a full day-to-day iPhone development setup:

| You get | How |
|---|---|
| One key to build, install and open the app on your iPhone, with its `print()` output in the terminal | `ios-run` (VS Code: F6 / Ctrl+Shift+B / SUPER+R) |
| Debugging with breakpoints: terminal lldb or **VS Code's debugger** (gutter breakpoints, variables, stepping, Debug Console) | `ios-run-dev` (VS Code: F5 / SUPER+SHIFT+R) |
| **Hot reload**: save a `.swift` file and the running app on the phone updates in **about 0.7 s**, keeping its state | `ios-run --live` (the run keys do this automatically) |
| New apps set up for all of the above in one command, ready for git and coding agents | `new-ios-app MyApp` |
| Toolchain upkeep (Swift/Xcode version match, patches) | `ios-toolchain-upgrade` |

What you don't get on Linux: the iOS Simulator, SwiftUI Previews (hot reload
on the real phone replaces them), Interface Builder and Instruments. The phone
connects over a **USB cable**.

Every step was tested on a real iPhone, and every trap found along the way
is written down here and in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md), so
you don't have to find them again.

---

## Contents

1. [Tested with](#1-tested-with)
2. [What you need](#2-what-you-need)
3. [Install the toolchain (omarchy-apple-dev)](#3-install-the-toolchain-omarchy-apple-dev)
4. [Install the kit](#4-install-the-kit)
5. [Your first app](#5-your-first-app)
6. [Debugging](#6-debugging)
7. [Hot reload](#7-hot-reload)
8. [Daily use cheat sheet](#8-daily-use-cheat-sheet)
9. [Coding agents (AGENTS.md)](#9-coding-agents-agentsmd)
10. [Keeping it working](#10-keeping-it-working)
11. [Troubleshooting](#11-troubleshooting)
12. [Intel Macs and other machines](#12-intel-macs-and-other-machines)
13. [Uninstall](#13-uninstall)
14. [Credits and license](#14-credits-and-license)

---

## 1. Tested with

| Piece | Version |
|---|---|
| OS | Omarchy 4.0.4 (Arch Linux), x86_64 |
| Swift | AUR `swift-bin` 6.4.0-2 |
| iOS SDK | from Xcode 27 (iPhoneOS 27.0) |
| omarchy-apple-dev | commit 521464e (xtool fork commit f0a1f90) |
| pymobiledevice3 | 11.26.0 |
| usbmuxd / libimobiledevice | 1.1.1 / 1.4.0 |
| VS Code | 1.141, with the Swift extension (swiftlang.swift-vscode) and LLDB DAP (llvm-vs-code-extensions.lldb-dap) |
| iPhone | iOS 26.6.1 and 26.6.2, over USB |
| Apple account | paid Apple Developer Program, signed in to xtool with an App Store Connect API key |

Other versions may well work; these are the ones every step here ran on.

---

## 2. What you need

- **A Linux machine running Omarchy** (other Arch-based setups are close; the
  Omarchy-specific parts are optional keys and the Lua Hyprland config).
- **An iPhone and a USB data cable** (not a charge-only cable). Wireless
  install doesn't work from Linux on current iOS.
- **An Apple Developer account.** The paid program ($99/year) is what this was
  tested with: installs stay valid for about a year and you can use App Store
  Connect API keys and TestFlight. xtool also accepts a free Apple ID (7-day
  installs, fewer features); that path isn't tested here.
- **The Xcode `.xip`** matching your Swift version, downloaded from Apple with
  any (free) Apple ID: see [3.4](#34-download-xcode-the-sdk-comes-from-it).
  Only the SDK is taken out of it; Xcode never runs.
- **Disk space:** about 10 GB for the toolchain and SDK, plus about 6 GB per
  iOS version you debug on (debug symbols, made automatically on the first
  debug run).
- **VS Code** (optional but recommended) with the extensions *Swift*
  (`swiftlang.swift-vscode`) and *LLDB DAP* (`llvm-vs-code-extensions.lldb-dap`).

---

## 3. Install the toolchain (omarchy-apple-dev)

omarchy-apple-dev does the heavy lifting (Swift, SDK, xtool, pymobiledevice3).
Read its README too; these are the steps and the lessons learned on top of it.

### 3.1 Swift and Xcode must match

The Swift compiler on Linux must be the same version Apple used for the SDK:
**Swift 6.4 ↔ Xcode 27**, Swift 6.3 ↔ Xcode 26. A mismatch breaks every build
("this SDK is not supported by the compiler"). Check omarchy-apple-dev's
README for its current version table.

### 3.2 Clone it

```sh
git clone https://github.com/joshuaswarren/omarchy-apple-dev ~/Tools/omarchy-apple-dev
```

Any folder works (the kit asks where). Keep it out of
`~/.local/share/omarchy-apple-dev`: a future Omarchy menu entry for iOS
(pending upstream at the time of writing) would reuse and *delete* that
folder when removing iOS support.

### 3.3 Hold swift-bin before installing (recommended)

The AUR `swift-bin` package must not update on its own: a routine system
update to a new Swift version would no longer match your SDK. Hold it first:

```sh
sudo sed -i '/^HoldPkg/a IgnorePkg   = swift-bin' /etc/pacman.conf
```

(The kit's `install.sh` offers this too. `ios-toolchain-upgrade` does the
upgrade properly when you choose to; see 10.1.)

### 3.4 Download Xcode (the SDK comes from it)

Apple ships the iOS SDK only inside Xcode, so you need one download of
Apple's `Xcode_<version>.xip`. Nothing is installed or run from it: the
installer just takes the SDK out. You don't need a Mac.

1. **Open** <https://developer.apple.com/download/all/?q=Xcode> in a browser
   and **sign in with any Apple ID**. A free one is enough for this
   download; accept the developer agreement if Apple asks.
2. **Pick the Xcode that matches your Swift** (3.1). Swift 6.4 needs
   **Xcode 27**: take the release entry named "Xcode 27" (not a beta or
   release candidate unless your Swift needs it). Ignore "Command Line Tools",
   "Additional Tools" and simulator runtimes.
3. **Click the `.xip` file** in that entry. Xcode 27's is about 2 GB; older
   versions are bigger. Save it, for example as `~/Downloads/Xcode_27.xip`.
   **Don't unpack it**; the installer reads the `.xip` directly.
4. **Check the size.** Apple's downloads need your browser's sign-in, so
   `wget`/`curl` on the link without it saves a small HTML page instead of the
   real file. If the file is only a few KB, download it from the browser.

Not sure which version? Run omarchy-apple-dev's installer once without
`XCODE_XIP`: it stops at the SDK step and prints the exact Xcode name and
link. If you already have a Mac with a matching Xcode, omarchy-apple-dev can
also stream just the SDK pieces from it ("Route B" in its
`install-toolchain.sh`).

Keep the `.xip` afterwards (anywhere, even an external drive): reinstalling
or repairing the SDK later doesn't need it (the SDK is cached), but a fresh
machine or a broken cache does.

### 3.5 Run the installer

With the `.xip` downloaded (3.4):

```sh
cd ~/Tools/omarchy-apple-dev
PATH="/usr/bin:$PATH" XCODE_XIP=~/Downloads/Xcode_27.xip ./install-toolchain.sh --mode full
```

- `PATH="/usr/bin:$PATH"` makes the installer build its Python environment
  (`~/pymobile3-venv`) on the **system Python**. If you use mise/asdf/pyenv,
  their "latest" Python can move to a new version later and break that
  environment.
- If the installer warns that three `.xcspec` files are "not writable", that's
  expected: they belong to the swift-bin package (root). The kit's installer
  (or `ios-toolchain-upgrade --patch`) applies those three patches with sudo.
  Without them, apps with `.strings` files fail to build.

### 3.6 Sign in to Apple

```sh
xtool auth
```

Choose an App Store Connect **API key** (paid accounts: create one under
App Store Connect → Users and Access → Integrations, download the `.p8`, note
the Key ID and Issuer ID) or your Apple ID. Keep the `.p8` somewhere private,
e.g. `~/.appstoreconnect/private_keys/` with `chmod 600`.

xtool stores its token in `~/.config/xtool/data/` and may create it readable
by others; tighten it:

```sh
chmod 700 ~/.config/xtool ~/.config/xtool/data
chmod 600 ~/.config/xtool/data/*
```

### 3.7 Connect the phone

1. Plug the iPhone in, unlock it, tap **Trust** and enter the passcode.
2. Check it's seen: `~/pymobile3-venv/bin/pymobiledevice3 usbmux list`.
3. **Developer Mode** must be on to run your own apps (iOS 16+): Settings →
   Privacy & Security → Developer Mode (it may only appear after the first
   app install; the phone restarts to turn it on).

---

## 4. Install the kit

```sh
git clone <this repository> ~/Tools/omarchy-ios-kit
cd ~/Tools/omarchy-ios-kit
./install.sh
```

The installer:

1. **Checks** the prerequisites from section 3 (and `inotify-tools`, needed
   for hot reload: `sudo pacman -S inotify-tools`).
2. **Asks your settings** and saves them in `~/.config/ios-run/config`:
   - your **bundle ID prefix** (a reverse domain you control, e.g.
     `com.yourname`; apps become `com.yourname.MyApp`);
   - your apps folder (default `~/Projects/ios`);
   - where omarchy-apple-dev is cloned;
   - where you keep Xcode downloads.
3. **Installs** `ios-run`, `ios-run-dev`, `new-ios-app` and
   `ios-toolchain-upgrade` to `~/.local/bin`, and the hot reload package,
   templates, tools and these docs to `~/.local/share/ios-run/`.
4. **Offers, one by one** (each is optional and explained):
   - holding swift-bin (3.3);
   - making `usbmuxd` restart by itself after crashes (it can abort around
     debug sessions);
   - the `.xcspec` patches (3.5);
   - VS Code shortcuts (F6 run, Ctrl+Alt+D debug), merged into your
     keybindings with a backup;
   - Omarchy keys SUPER+R / SUPER+SHIFT+R (appended as a marked block to
     `~/.config/hypr/bindings.lua`, skipped if you already use those keys);
   - a short pointer for your coding agents (Claude Code, Codex) to these
     docs.
5. Tells you about the **hot reload signing identity** (7.1).

Run `./install.sh` again any time to update; your settings are kept.
`--yes` accepts all optional steps, `--no-system` skips the sudo ones.

---

## 5. Your first app

```sh
new-ios-app MyApp
code ~/Projects/ios/MyApp
```

`new-ios-app` runs `xtool new`, sets the bundle ID, adds the VS Code setup
(`.vscode/`), sets up hot reload, writes `AGENTS.md` for coding agents,
extends `.gitignore` (signing files, caches) and makes the first git commit.
Options: `--prefix com.other`, `--dir ~/elsewhere`, `--no-live` (no hot
reload).

**Run it:** press **F6** (or Ctrl+Shift+B, or SUPER+R with the Omarchy keys),
or in a terminal in the app folder:

```sh
ios-run --live      # or plain: ios-run
```

What happens:

1. If the app is already open on the phone, it's closed first (iOS won't
   replace a running app, and the install would wait).
2. xtool builds, signs and installs it.
3. It's opened on the phone, and its `print()` output streams into the
   terminal as `[app] …` lines (Ctrl+C stops watching; the app keeps running).

Compile errors show in VS Code's **Problems** tab, clickable.

**The first time after a phone restart**, `ios-run` can't close or open the
app yet: that needs the *developer disk image* mounted on the phone. Run
`ios-run-dev` once (section 6); it mounts it, and it stays mounted until the
phone restarts. `ios-run` tells you when this is the case.

---

## 6. Debugging

**In VS Code: press F5** (or Ctrl+Alt+D; SUPER+SHIFT+R). Click in the gutter
to set breakpoints; you get the Variables and Call Stack panes, stepping, and
`print()` output in the Debug Console. Shift+F5 stops; the app keeps running.

**In a terminal:**

```sh
ios-run-dev                          # run under lldb; the app starts right away
ios-run-dev -b ContentView.swift:12  # stop at that line (repeat -b; a function name works too)
ios-run-dev --pause                  # stop at launch, set breakpoints by hand, then `c`
ios-run-dev --attach                 # attach to the app that's already running
```

In lldb: **Ctrl+C** pauses the app, **Ctrl+D** leaves lldb (the app keeps
running), then **Enter** at the prompt builds and runs again with the same
options.

**The first debug run on each iOS version** copies the phone's system
library cache (about 6 GB) and extracts the debug symbols from it, a few
minutes once. After that the raw copy is no longer needed: it can be deleted
from `~/.cache/omarchy-apple-dev/DeviceSupport/<version>/dsc` (it's copied
again automatically if it's ever needed).

SwiftUI only runs a view's `body` while the app is on screen: keep the phone
**unlocked with the app open** when you expect a breakpoint in UI code.

---

## 7. Hot reload

Save a `.swift` file and the change appears in the running app in about
0.7 s, without reinstalling, and the app keeps its state (lists, text, taps).
The run keys use it automatically in apps set up for it (all apps made by
`new-ios-app`).

### 7.1 One-time: the signing identity

Each swap is a small library that iOS only loads if it's signed by your
development certificate, the one xtool already signs your apps with. After
you've signed in (3.6) and installed one app, run **yourself**:

```sh
~/.local/share/ios-run/hot-reload/extract-dev-identity.py
```

It copies xtool's certificate and private key to
`~/.config/omarchy-apple-dev/development/` (owner-only) and prints only the
certificate's name and expiry. Nothing new is created in your Apple account.
Run it again when the certificate is renewed.

### 7.2 Two lines per view

Every SwiftUI view that should update live needs:

```swift
import HotReload

struct ContentView: View {
    @ObserveHotReload private var hotReload   // re-run body after each swap

    var body: some View {
        VStack { /* ... */ }
        .padding()
        .hotReloadable()                      // always the last modifier
    }
}
```

`new-ios-app`'s starter view already has them. They compile to nothing in
release and TestFlight builds.

### 7.3 What swaps, and what reruns

| You change | Result |
|---|---|
| Code inside functions, computed properties, view bodies | **Swaps** (state kept) |
| Methods of classes (also overrides) and protocol methods | **Swaps** |
| `async` and generic code | **Swaps** |
| A typo | The compiler error is shown; the app keeps running the old code |
| A new or deleted file, `Package.swift`, `xtool.yml` | **Reruns** the app automatically |
| A file that declares an `@Observable` model | **Reruns** automatically (a swap would silently stop observation) |
| What *kind* of view a function returns (adding a modifier or container in a helper, or a body without `.hotReloadable()`) | The app **refuses** the swap and it **reruns** automatically |
| New stored properties or new types, a changed struct layout | Press run again yourself |

**One type per file.** A swap carries its own copy of every type declared in
the edited file. Put each view and each model in its own file, or `is`/`as?`
checks on old values can fail and subviews in that file may lose their
state.

**Keep the phone unlocked with the app open.** iOS pauses apps in the
background; a swap then waits, and the terminal says so after 5 seconds. It
loads the moment the app is in front again.

How it works, its limits and every check: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

### 7.4 Adding hot reload to an existing app

```sh
cd ~/Projects/ios/OldApp
/usr/bin/python3 ~/.local/share/ios-run/hot-reload/enable-in-package.py
```

That adds the HotReload package and the debug-only link flag
(`-Xlinker -interposable`) to `Package.swift`. Then add the two lines (7.2) to
each view, and copy `.vscode/` and `AGENTS.md` from a new app (or from
`~/.local/share/ios-run/vscode/` and `templates/`).

---

## 8. Daily use cheat sheet

| Action | Terminal (in the app folder) | VS Code |
|---|---|---|
| New app | `new-ios-app Name` | – |
| Run (+ live edits) | `ios-run --live` (`ios-run --auto-live` = live if set up) | F6, Ctrl+Shift+B, SUPER+R* |
| Debug | `ios-run-dev [-b File.swift:N]` | F5, Ctrl+Alt+D, SUPER+SHIFT+R* |
| Stop at the cursor's line | – | Terminal → Run Task → "Debug on iPhone, stop at this line" |
| Rerun in lldb | Ctrl+C, Ctrl+D, Enter | Shift+F5, then F5 |
| See `print()` | `[app]` lines in the terminal | the run task's terminal; Debug Console when debugging |
| Toolchain status / upgrade | `ios-toolchain-upgrade [--upgrade]` | – |
| All options | `ios-run --help`, `new-ios-app --help` | – |

\* SUPER keys need the optional Omarchy keys (install step 4). F6 and
SUPER+R only act in iOS projects (their `.vscode/settings.json` has
`"iosRun.project": true`); elsewhere F6 moves focus and SUPER+R opens recent
files as usual.

---

## 9. Coding agents (AGENTS.md)

Every app gets an `AGENTS.md`, the shared instruction file most coding agents
read (Codex, Cursor, GitHub Copilot, Gemini CLI, ...), with the rules for
this setup: how to run and debug, the two hot reload lines every view needs,
one type per file, and what not to touch. A one-line `CLAUDE.md` (`@AGENTS.md`)
makes Claude Code read the same file. So whichever agent you use, it follows
the same rules and doesn't "clean up" the hot reload lines.

The installer can also add a short machine-wide pointer for Claude Code
(`~/.claude/CLAUDE.md`) and Codex (`~/.codex/AGENTS.md`) to these docs.

---

## 10. Keeping it working

### 10.1 Swift updates (`warning: swift-bin: ignoring package upgrade`)

```sh
ios-toolchain-upgrade            # status: versions, Xcode match, patches, SDK
ios-toolchain-upgrade --upgrade  # minor update (same Swift x.y): upgrade + re-register SDK + patches
```

A **major** update (e.g. Swift 6.4 → 6.5) needs the matching Xcode first:
`git pull` omarchy-apple-dev (check its version table), download that Xcode
`.xip`, then `XCODE_XIP=/path/to/Xcode_NN.xip ios-toolchain-upgrade --upgrade`.

Every swift-bin reinstall resets the three `.xcspec` patches:
`ios-toolchain-upgrade --patch` puts them back (the upgrade does it for you).

Careful with re-running omarchy-apple-dev's *full* installer: it runs
`yay -S swift-bin`, which can bypass the hold. `install-toolchain.sh --repair`
is safe.

### 10.2 Other events

| Event | What to do |
|---|---|
| The phone restarted | Run `ios-run-dev` once (remounts the developer disk image) |
| The phone got an iOS update | Nothing: the first debug run sets up its symbols (a few minutes) |
| A new phone | Trust it, Developer Mode, then `ios-run-dev` once. With two phones plugged in, the tools may pick either. |
| Updating omarchy-apple-dev (`git pull`) | Run a debug run and a hot reload swap once to check (the kit relies on two lines of its `device-run.sh`; the tools say so if they changed) |
| Updating the kit | `git pull`, then `./install.sh` (settings kept). Press run once in each app so it rebuilds with the updated HotReload package. |
| Hot reload signing certificate renewed | Run `extract-dev-identity.py` again |

---

## 11. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Install sits at `[Installing]` | The app is open and iOS won't replace a running app. `ios-run` closes it first once the developer disk image is mounted (run `ios-run-dev` once after a phone restart); otherwise swipe home. |
| `Failed to connect to usbmuxd socket` right after debugging | usbmuxd crashed. The kit's usbmuxd fix restarts it within a second; without it, replug the cable or `sudo systemctl restart usbmuxd`. |
| `xtool launch` fails with `DebugserverClient.Error.unknown` | It uses a debug service iOS 17+ removed; `ios-run` opens apps another way. |
| `print()` output never shows | Use `ios-run`/`ios-run-dev` (they stream it); apps opened by hand don't connect their output anywhere. |
| VS Code: breakpoints never stop (F5) | The debug symbols for that iOS version aren't fully extracted: run `ios-run-dev` once and let it finish. |
| lldb: Ctrl+C doesn't quit | Ctrl+C pauses the app; **Ctrl+D** (or `quit`) leaves lldb. |
| VS Code compile errors don't show in Problems | Use the kit's tasks (`.vscode/tasks.json`); they have a matcher for the coloured output. |
| F6 / SUPER+R opens "Open Recent" or does nothing | The project's `.vscode/settings.json` lacks `"iosRun.project": true` (copy from `~/.local/share/ios-run/vscode/`). |
| `this SDK is not supported by the compiler` | Swift and Xcode SDK don't match (3.1): `ios-toolchain-upgrade`. |
| Builds with `.strings` files fail | The `.xcspec` patches are missing: `ios-toolchain-upgrade --patch`. |
| Hot reload: saved, but the phone didn't change | Is the app open on the unlocked phone? (The terminal warns after 5 s.) Does the view have both hot reload lines? |
| Hot reload: `SWAP REFUSED` / `needs a normal run` | Expected for changes that can't be swapped safely (7.3); live mode reruns the app. |
| Hot reload: `no development identity` | Run `extract-dev-identity.py` (7.1). |
| Each save swaps twice | Two live sessions for one app; the newest now stops the older one (update the kit). |
| The Python environment broke after a mise/asdf update | It was built on a version-managed Python: rerun the installer with `PATH="/usr/bin:$PATH"` (3.5). |

More, with root causes: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md#traps-and-their-causes).

---

## 12. Intel Macs and other machines

Everything here was tested on an **x86_64** Omarchy machine, so an
Intel MacBook running Omarchy uses the same software path. What's
different is hardware, and **untested by us**:

- **USB:** the iPhone must show up in `lsusb` (Apple, Inc. iPhone) and in
  `pymobiledevice3 usbmux list`. On Intel Macs (especially those with a T2
  chip), first check that the USB-C ports work as data ports under
  Omarchy.
- **Everything else** (Swift, SDK, xtool, the kit) is plain software and
  should behave the same.
- **ARM64 Linux:** omarchy-apple-dev reports aarch64 support for the
  toolchain; the kit's tools are architecture-independent, but this
  combination is untested here.

If you try it on another machine, the quickest end-to-end check is:
`new-ios-app Check`, F6 (runs), F5 (stops at a breakpoint), then edit a
`Text` and save (hot reload).

---

## 13. Uninstall

```sh
rm -f ~/.local/bin/{ios-run,ios-run-dev,new-ios-app,ios-toolchain-upgrade}
rm -rf ~/.local/share/ios-run ~/.config/ios-run
```

Then, if you added them: remove the marked `omarchy-ios-kit` blocks from
`~/.config/hypr/bindings.lua`, `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`;
the kit's entries from `~/.config/Code/User/keybindings.json` (a backup from
before is next to it); `/etc/systemd/system/usbmuxd.service.d/restart.conf`;
and `swift-bin` from `IgnorePkg` in `/etc/pacman.conf`. The signing identity
copy is in `~/.config/omarchy-apple-dev/development/`. Apps already set up
for hot reload keep a `.package(path:)` to the HotReload package: remove it
(and the two lines per view) to build them without the kit.

---

## 14. Credits and license

- [omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev)
  by Joshua Warren (MIT): the toolchain installer, `device-run.sh`,
  `ship.sh`, and the findings this builds on.
- [xtool](https://github.com/xtool-org/xtool): SwiftPM-based building and
  signing of iOS apps without Xcode.
- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3): talking to
  the iPhone (install, launch, debug server, file transfer).
- [apple-codesign / rcodesign](https://github.com/indygreg/apple-platform-rs)
  and [ipsw](https://github.com/blacktop/ipsw): signing and debug symbols.
- The hot reload approach (interposable linking, rebinding, `AnyView`
  erasure) follows [InjectionIII](https://github.com/johnno1962/InjectionIII),
  reimplemented for Linux and a real device.

This kit: MIT license, see [LICENSE](LICENSE).
