# How it works

The internals of omarchy-ios-kit: what each tool does and why, hot reload in
depth, every trap found while building it (with its root cause), and how to
test things. Read [README.md](../README.md) first for setup and daily use.

Paths below are the installed ones: tools in `~/.local/bin`, kit files in
`~/.local/share/ios-run/`, settings in `~/.config/ios-run/config`.

---

## Contents

1. [The pieces](#1-the-pieces)
2. [ios-run: the normal run](#2-ios-run-the-normal-run)
3. [ios-run-dev: debugging in the terminal](#3-ios-run-dev-debugging-in-the-terminal)
4. [VS Code: tasks, F5 debugging, Debug Console](#4-vs-code-tasks-f5-debugging-debug-console)
5. [Debug symbols](#5-debug-symbols)
6. [new-ios-app and the templates](#6-new-ios-app-and-the-templates)
7. [ios-toolchain-upgrade](#7-ios-toolchain-upgrade)
8. [Hot reload](#8-hot-reload)
9. [Traps and their causes](#9-traps-and-their-causes)
10. [Testing recipes](#10-testing-recipes)
11. [Coupling points to re-check after updates](#11-coupling-points-to-re-check-after-updates)

---

## 1. The pieces

| Piece | From | Role |
|---|---|---|
| Swift (`swift-bin`, `/usr/lib/swift`) | AUR | compiler, lldb, lldb-dap |
| iOS SDK | taken from an Xcode `.xip` by omarchy-apple-dev | registered as the `darwin` Swift SDK (`~/.config/swiftpm/swift-sdks/darwin.artifactbundle`), cached in `~/.cache/xtool` |
| xtool (`~/.local/bin/xtool`) | built from source by omarchy-apple-dev | builds (through SwiftBuild), signs, installs |
| pymobiledevice3 (`~/pymobile3-venv`) | omarchy-apple-dev | talks to the phone: install, launch, kill, debugserver, files |
| `device-run.sh` | omarchy-apple-dev | build + install + (optionally) lldb, the base `ios-run` builds on |
| `ios-run` / `ios-run-dev` | this kit | one script, two names; run, debug, VS Code F5, hot reload |
| `new-ios-app`, `ios-toolchain-upgrade` | this kit | new apps; toolchain upkeep |
| HotReload package + `hot-reload/*` | this kit | live code swaps |

Installed apps get xtool's team prefix: `XTL-xxxxxxxx.<bundle ID>`. The
tools look the installed ID up with `pymobiledevice3 apps list`.

---

## 2. ios-run: the normal run

1. **Close the app** if it's open: `pymobiledevice3 developer dvt pkill
   --bundle <id> --userspace`. iOS doesn't replace a running app: the
   install would otherwise wait at `[Installing]` until the app is
   backgrounded. This needs the **personalized developer disk image (DDI)**
   mounted on the phone, which `ios-run-dev` mounts; it's lost when the phone
   restarts (`ios-run` checks with `mounter list` and says so).
2. **Build and install:** omarchy-apple-dev's `device-run.sh` (xtool).
3. **Open it and stream its output:** `dvt launch <id> --env
   NSUnbufferedIO=YES --stream --userspace`.
   - `xtool dev run` only installs, and `xtool launch` fails on iOS 17+
     (`DebugserverClient.Error.unknown`): it uses the debugserver service
     iOS removed.
   - `--stream` relays the app's stdout; `NSUnbufferedIO=YES` (what Xcode
     sets) makes each `print()` arrive at once instead of block-buffered.
   - `app_output` strips colour codes and pymobiledevice3's log prefix
     (`<time> <host> PID:n[pid] INFO `) and adds `[app] `.
   - Ctrl+C stops watching; the app keeps running.

`--live` / `--auto-live` continue into hot reload (section 8.5).

---

## 3. ios-run-dev: debugging in the terminal

`ios-run-dev` is a symlink to `ios-run`; the script checks `basename "$0"` and
switches to debug mode, so the two never drift apart. Its own options are
parsed first because `device-run.sh` rejects unknown arguments.

- **After-attach commands** go through `device-run.sh`'s `LLDB_CMDS`:
  `settings set interpreter.prompt-on-quit false` (Ctrl+D leaves without
  a Y/n), `breakpoint set --file X --line N` / `--name F` per `-b`, and
  `continue` (so the app starts at once) unless `--pause`.
- **A temporary copy of `device-run.sh`** is run, with two lines swapped
  (the repo's file is never edited):
  - `PMD3=…` points at a hook (`ios-run --pmd3-hook`). It passes every
    pymobiledevice3 call through except the debug run's
    `dvt launch … --suspended`. That one gets `--stream` and runs in the
    background, writing the app's output to the terminal (fd 9), and prints
    only `Process launched with pid N` on stdout.
    - `device-run.sh` reads that pid with `$(...)`, so the background
      process must not keep the command-substitution pipe open (`exec >&9`
      inside the process substitution).
    - A background job of a non-interactive bash ignores SIGINT, so
      Ctrl+C in lldb doesn't kill the stream; it's stopped when lldb exits.
  - `exec lldb "${lcmds[@]}"` → `exec "${IOS_RUN_LLDB:-lldb}" …` (used by
    VS Code's `--serve`, section 4).
  - If either swap fails to match after an omarchy-apple-dev update, the
    tool says so and falls back.
- **Rerun loop:** when lldb exits, `Enter = build and run again, q = stop`,
  also after a failed build.
- **Debug symbols** are prepared first (section 5).

---

## 4. VS Code: tasks, F5 debugging, Debug Console

### 4.1 Tasks (`.vscode/tasks.json`)

- **"Run on iPhone"** (the default build task, F6 / Ctrl+Shift+B / SUPER+R)
  runs `ios-run --auto-live`. Also "Run on iPhone (live)", two terminal
  debug tasks (one stops at the cursor's line), and two hidden tasks used
  by F5.
- Commands use full `${userHome}/.local/bin/...` paths: VS Code started from
  a launcher may not have `~/.local/bin` on its PATH.
- `instanceLimit: 1`, `instancePolicy: terminateOldest`: pressing run again
  replaces the previous run.
- **The problem matcher is the kit's own, not `$swiftc`**: in VS Code's
  terminal the build output has `\e[2K\r` before each path and colour codes
  around `error:`, which `$swiftc` misses. Regex:
  `^[^/]*(/[^:\r\u001b]+\.swift):(\d+):(\d+):\s+(?:\u001b\[[0-9;]*m)*(error|warning):\s+(?:\u001b\[[0-9;]*m)*(.*?)(?:\u001b\[[0-9;]*m)*\r?$`
  (JavaScript's `.` doesn't match `\r`, hence the `^[^/]*` prefix; in JSON
  each `\u001b` is written `\\u001b`).
- `.vscode/settings.json`:
  - `"lldb-dap.executable-path": "/usr/lib/swift/usr/bin/lldb-dap"`, the
    Swift toolchain's lldb-dap (it understands Swift);
  - `"iosRun.project": true`, an unregistered setting that the keybindings'
    `config.iosRun.project` when-clause reads (this works for unregistered
    settings).

### 4.2 F5 (`.vscode/launch.json`)

An `lldb-dap` **attach** configuration:
- `attachCommands: ["script exec(open('${workspaceFolder}/xtool/ios-debug.py').read())"]`;
- preLaunchTask "Prepare iPhone debug" = `ios-run-dev --serve` (a background
  task whose matcher ends at `== Ready for the debugger`);
- postDebugTask "Stop iPhone debug" = `ios-run-dev --stop`.

`--serve`:
1. A normal debug run, but `IOS_RUN_LLDB` points at a stand-in
   (`ios-run --lldb-serve`). By the time it runs, `device-run.sh` has
   installed the app, launched it suspended and started its debugserver
   forwarder on a localhost port.
2. The stand-in writes lldb's setup commands (the `-o` arguments) into
   `xtool/ios-debug.py`, which runs each through
   `SBCommandInterpreter.HandleCommand` (`script …` lines are `exec`'d with
   `lldb.target` refreshed). It then prints `== Ready for the debugger` and
   sleeps until `--stop` (TERM). `device-run.sh`'s exit trap stops the
   forwarder; `ios-run` stops the output stream.
3. **Debug Console output:** the output stream is also written to
   `xtool/ios-app-output.log`; `ios-debug.py` starts a thread that follows
   that file and writes each line to `lldb.debugger.GetOutputFile()`, which
   lldb-dap shows in the Debug Console.

---

## 5. Debug symbols

lldb needs the phone's system libraries on disk, per iOS build, in
`~/.cache/omarchy-apple-dev/DeviceSupport/<version> (<build>)/Symbols`.

- `device-run.sh` copies the phone's shared cache (`dsc/`, about 6 GB) and
  extracts **only the Swift runtime** from it. That's enough for terminal
  lldb.
- **VS Code's lldb-dap needs all of them.** It looks up every loaded module
  for its Modules view, and lldb reads any library *not on disk* from the
  phone's memory, 512 bytes per USB round trip: thousands of reads, minutes
  before a breakpoint can show (it looked like breakpoints never hit).
- So `ios-run-dev` runs, once per iOS build, `ipsw dyld extract <dsc> --all
  --slide` into `Symbols/` (4,317 libraries, about 6 GB, about 2 minutes) and
  marks it with `Symbols/.all-extracted`. Afterwards attaching and stopping
  at a breakpoint takes about 4 s.
- The raw `dsc/` is only needed to extract; it can be deleted, and is copied
  again (`developer fetch-symbols download`) if ever needed.

---

## 6. new-ios-app and the templates

1. Validates the name (letters and digits, starting with a letter: it becomes
   a Swift type and the end of the bundle ID) and the prefix (reverse domain).
2. `xtool new <Name> --skip-setup </dev/null`, then sets `bundleID:` in
   `xtool.yml` to `<BUNDLE_PREFIX>.<Name>`.
3. Unless `--no-live`: `enable-in-package.py` (section 8.7) and a ContentView
   with the two hot reload lines.
4. Copies `.vscode/` from `~/.local/share/ios-run/vscode/`, writes
   `AGENTS.md` from `templates/AGENTS.md` (its `<!-- hot-reload -->` block is
   removed with `--no-live`) and a one-line `CLAUDE.md` (`@AGENTS.md`).
5. Appends to `.gitignore`: signing material (`*.p8 *.p12 *.cer
   *.mobileprovision .env*`), `/.swiftpm/`, `/.sourcekit-lsp/`, `*.ipa`,
   `*.xip`, `*.dSYM/`, editor clutter. `.bsp/xtool.json` is committed on
   purpose: it's portable and lets VS Code's Swift support use xtool's build
   server.
6. `git init` and a first commit.

---

## 7. ios-toolchain-upgrade

- No arguments: status (installed vs AUR swift-bin, the Xcode version it
  needs, the `.xcspec` patches, the darwin SDK).
- `--patch`: the three settings under `/usr/lib/swift/usr/share/pm`:
  `STRINGS_FILE_INPUT_ENCODING=utf-8` in `CopyStringsFile.xcspec` and
  `STRINGS_FILE_OUTPUT_ENCODING=binary` in `CoreBuildSystem.xcspec` and
  `NativeBuildSystem.xcspec`. It edits the first `DefaultValue` within 12
  lines after the setting's `Name`, as root through a hidden
  `--apply-as-root` mode. swift-bin owns those files, so every reinstall
  resets them.
- `--upgrade`: minor (same Swift x.y): `yay -S swift-bin`, then
  `install-toolchain.sh --repair`, then the patches. Major: needs `XCODE_XIP`.
  It first runs `swift sdk remove darwin` (a full install skips SDK
  registration while any darwin SDK exists), then the full install with
  `/usr/bin` first on PATH. yay never runs as root.

---

## 8. Hot reload

### 8.1 The idea

```
 Linux                                            iPhone (app running)
 save Foo.swift
   │ inotifywait (ios-run --live)
   ▼
 hot-swap.sh Foo.swift
   1. compile just Foo.swift with the app's own
      compiler command (trimmed, incremental)   ~0.25 s
   2. link Foo.o → hot-<ms>.dylib
      (-undefined dynamic_lookup -flat_namespace
       -interposable -ignore_auto_link)          ~0.02 s
   3. check, then sign (rcodesign)              ~0.08 s
   4. push over a kept-open connection ──USB──▶ Documents/hot-<ms>.dylib   ~0.02 s
                                                   │ HotReloader checks every 0.1 s
                                                   ▼
                                       dlopen; safety checks; repoint every
                                       pointer to the old functions at the
                                       new ones; bump HotReloadObserver
                                                   ▼
                                       SwiftUI re-runs body (new code)
```

Why each piece:

1. **`-Xlinker -interposable` on the app (debug builds only).** Normally an
   app calls its own functions directly. With this flag, calls to every
   exported symbol (Swift `internal` functions included) go through a stub
   and a pointer slot in `__DATA_CONST,__got`, which can be rewritten.
2. **Signed with your team's development certificate.** iOS `dlopen`s a
   library in a development-signed app only if it's signed by the same team;
   unsigned it fails with `missing code signature`.
3. **Same module name and flags as the app,** so the new functions have
   exactly the same mangled names (`$s<len><Module>…`). That's how old and new
   are paired.
4. **`dynamic_lookup` + `flat_namespace`:** the new code still uses the rest
   of the app; dyld resolves those references in the running app when it
   loads the library.
5. **A new file and install name per swap** (`hot-<epoch ms>.dylib`): dyld
   caches images by path. Old swaps stay loaded (code may still be running in
   them).
6. **SwiftUI:**
   - `.hotReloadable()` wraps the body in `AnyView`, so the body's type stays
     the same whatever the edit changes (a `some View` type is fixed when the
     app is built).
   - `@ObserveHotReload` is a `DynamicProperty` holding an `@ObservedObject`;
     bumping it after a swap makes SwiftUI re-run the (new) body.
   - `@State` survives because the view isn't recreated.

### 8.2 The HotReload package (`hot-reload/HotReload`)

Public API: `@ObserveHotReload`, `View.hotReloadable()`,
`HotReloader.start()` (called by the property wrapper; a `static let` makes it
a cheap run-once). Everything else is `#if DEBUG`; packages get `-DDEBUG` in
debug builds.

On start it deletes old `Documents/hot-*.dylib` (a reinstall keeps
Documents, and those swaps belong to an older build), then checks Documents
every 0.1 s and loads new swaps in number order. For each:

1. **`dlopen`.** If it fails (a push may still be writing), it retries a few
   times, then logs `couldn't load it: <dlerror>` and `SWAP FAILED`.
2. **Return-type check:** see 8.4. If it fails, it logs `SWAP REFUSED` and
   changes nothing.
3. **Pairing:** it walks both images' `LC_SYMTAB` (nlist entries in
   `__TEXT,__text`; debug apps aren't stripped). It keeps symbols that belong
   to the app's module: `$s<len><Module>…`, or extensions (`<len><Module>E`),
   with the module taken from `CFBundleExecutable`. That leaves out the
   compiler's shared helpers, which needn't be swapped.
4. **Never swapped:** state and type accessors, suffixes `vau` (addressors),
   `WZ`/`Wz` (lazy initialisers), `Ma`/`Mi`/`Mr` (metadata). Both the app and
   the swap keep using the app's, so statics keep their value and types
   their identity where possible (8.4).
5. **Repointing:** one pass over every section of the app's `__DATA_CONST`,
   `__DATA`, `__AUTH_CONST` and `__AUTH` segments (except zero-fill). Each
   8-byte word that equals a swapped function's *current* address is
   replaced by the new one. That covers call slots, class vtables (so methods
   of non-final classes and overrides swap), protocol witness tables and
   other function pointers. Pages are made writable with `vm_protect(…COPY)`.
   The swap's own call slots, which dyld bound to the app's originals because
   it's linked interposable and flat, are pointed at the new code too, so new
   code calls new code. The app is plain `arm64`: no pointer authentication.
6. **Log and redraw:** it logs `swapped <name>: N function(s), M pointer(s)
   repointed, K return type(s) checked` and bumps `HotReloadObserver`.

### 8.3 What can't be swapped, and why

| Case | Why | Handling |
|---|---|---|
| New or deleted file | The app has no slots for it | live mode reruns |
| New stored property or type, changed layout | Old instances have the old layout | rerun by hand |
| Type **declared in the edited file** | The compiler refers to its own type metadata directly (`adrp …VMf@PAGE`), so the swap carries a copy: `is`/`as?` on old values fail, and subviews may reset state | "one type per file" rule |
| `@Observable` type in the edited file | Observation tracks key paths like `\Model.value`, and the swap's key paths use its copy of `Model`, so observation silently stops | `hot-swap.sh` exits 3 → rerun |
| A `some View` function whose concrete type changed | Old callers would misread the new value (lost modifiers or memory corruption) | 8.4: refused → rerun |
| Something the app keeps private (e.g. `___isPlatformVersionAtLeast`, linked privately from the compiler runtime) | dyld can't find private symbols in the app | the runtime library is linked into each swap; anything else private → exit 3 → rerun |

### 8.4 The return-type check

Each `some …` function has an **opaque type descriptor** (`$s…QOMQ`). For
each one both images define:

- **non-generic** (kind 4, and either not generic or generic with only the
  opaque parameter itself, `NumParams == 1`):
  `swift_getOpaqueTypeMetadata2(0, nil, descriptor, 0)` on both, compared as
  pointers (metadata is uniqued);
- **generic** (`NumParams > 1`): the underlying type's **mangled name** from
  the descriptor is compared instead. Generic parameters are placeholders,
  and symbolic references (bytes 0x01–0x17 + a 4-byte relative offset, 0x02
  being indirect; 0x18–0x1f + an 8-byte address) are replaced by the
  `dladdr` name of their target, so names compare across images.
  Descriptor layout: flags, parent; if generic, the generic header
  (NumParams, NumRequirements, NumKeyArguments, Flags as UInt16 — Flags must
  be 0), NumParams one-byte parameter descriptors padded to 4,
  NumRequirements 12-byte requirements, then relative pointers to the
  underlying types' names.

A difference means `SWAP REFUSED`; live mode sees it and reruns the app.

### 8.5 Live mode (`ios-run --live`, `--auto-live`)

After the normal close-install, live mode:
- launches the app with its output going to the terminal *and*
  `xtool/ios-live-output.log`;
- starts `inotifywait` on `Sources`, `Package.swift` and `xtool.yml`;
- prepares the **fast compile** command (`swiftc-args.py --fast`) and warms
  it up in the background (`<args>.ready` when done);
- starts the **push helper** (`hot-push.py`).

Then it loops:
- Events within 0.15 s count as one save.
- **Known `.swift` file saved:** `hot-swap.sh` (exit 0: show the result line;
  1: show the compiler errors, the app keeps the old code; 3: rerun).
- **New or deleted `.swift` file, or `Package.swift`/`xtool.yml`:** rerun
  (`exec` itself).
- **The app stopped** (closed or crashed): rerun.
- **5 s after a push:** if the app didn't log `swapped hot-<n>`, it warns that
  the app isn't open (iOS suspends apps in the background); if it logged
  `SWAP REFUSED hot-<n>`, it reruns.
- **One live session per app** (`xtool/ios-live.pid`): a new one stops the
  old one, so saves aren't swapped twice.

`--auto-live` is `--live` in apps set up for hot reload and a quiet normal run
elsewhere (what the run keys use). Live mode falls back to a normal run,
saying why, if the package, the link flag, the signing identity or
`inotifywait` is missing.

### 8.6 Speed

| Step | Approach | Time |
|---|---|---|
| Compile | `swiftc-args.py` decodes xtool's build data (`.build/out/Intermediates.noindex/XCBuildData/*.xcbuilddata/task-store.msgpack`, its own minimal msgpack decoder). It finds the app module's compiler command (stored as `["builtin-SwiftDriver", "--", "/…/swiftc", args…]`) and `--fast` trims it: no explicit-module scanning (implicit modules with a warm cache), no indexing, module or header output, and the output map points at `.build/hot-reload/objects` so xtool's own build state is untouched. It's incremental: only the saved file compiles. | about 0.25 s (`xtool dev build`: about 3.5 s) |
| Link | `-Xlinker -ignore_auto_link`: otherwise lld parses SwiftUI's and Foundation's `.tbd` files on every link; the running app provides those symbols | about 0.02 s (was 0.31 s) |
| Private-symbol check | `llvm-nm`; the app's list is cached per app binary | a few ms |
| Sign | `rcodesign sign --timestamp-url none` | about 0.015 s |
| Push | `hot-push.py` keeps one house_arrest/AFC connection open, serving `127.0.0.1` (port in `xtool/ios-live-push.port`); `hot-swap.sh` talks to it through bash's `/dev/tcp` | about 0.02 s (a fresh connection: 1.5 s) |
| Pick-up | the app checks every 0.1 s | ≤ 0.1 s |

Measured end to end, save → new `body` on the phone: **0.65–0.70 s**. Without
the fast path or the push helper, `hot-swap.sh` falls back to
`xtool dev build` and `pymobiledevice3 apps push`.

### 8.7 Files

| File | Job |
|---|---|
| `hot-reload/HotReload/` | the package apps depend on (path dependency) |
| `hot-reload/hot-swap.sh FILE…` | compile → link → check → sign → push one swap (exit 0/1/2/3) |
| `hot-reload/swiftc-args.py [--fast SHADOW] APP MODULE` | the app's compiler command from xtool's build data |
| `hot-reload/hot-push.py BUNDLE_ID PORT_FILE` | the kept-open push connection |
| `hot-reload/enable-in-package.py [Package.swift]` | sets an xtool manifest up for hot reload (idempotent; refuses manifests it doesn't recognise and prints the lines to add) |
| `hot-reload/extract-dev-identity.py` | copies xtool's development certificate and key for signing swaps |

---

## 9. Traps and their causes

| Symptom | Root cause | Fix in the kit |
|---|---|---|
| Install hangs at `[Installing]` | iOS won't replace a running app | close it first (`dvt pkill`; needs the DDI) |
| `Failed to connect to usbmuxd socket` after debugging | usbmuxd 1.1.1 aborts around lldb sessions | systemd `Restart=on-failure` drop-in |
| `xtool launch`: `DebugserverClient.Error.unknown` | legacy debugserver service, removed in iOS 17 | `dvt launch` |
| `print()` goes nowhere | apps launched without `--stream` have no stdout connection; lldb attaches later | `dvt launch --stream`, `NSUnbufferedIO=YES` |
| VS Code errors missing from Problems | colour codes and `\r` in pty output | the kit's own problem matcher |
| VS Code F5: breakpoints "never hit" | lldb-dap's module lookups read unextracted libraries from phone memory (13,000+ reads) | full symbol extraction (section 5) |
| Debug Console silent | lldb-dap only relays output of processes it launches | output log relayed by `ios-debug.py` |
| `swift build --swift-sdk`: `unable to find platform for 'iphoneos'` | SwiftPM's `--swift-sdk` path is broken on Swift 6.4; xtool builds through SwiftBuild | compile with the commands xtool records |
| `this SDK is not supported by the compiler` (hand-built swiftc) | without `-resource-dir` (Xcode's Swift libraries in the SDK bundle) swiftc rebuilds Apple's Swift module and refuses | use xtool's own flags (`swiftc-args.py`) |
| `libSystem.tbd … unknown target arm64e.x1-ios` | a generic lld can't read the iOS 27 `.tbd` files | the SDK's `toolset/bin/ld64.lld` (`-ld-path`) |
| `missing code signature` on `dlopen` | unsigned swap | `rcodesign` with the development identity |
| Swap: `symbol not found … ___isPlatformVersionAtLeast` | the compiler runtime helper (used by `if #available` and SwiftUI) is *private* in the app | link `libclang_rt.ios.a` into each swap; the private-symbol check catches others (exit 3) |
| Statics reset or split after a swap | the swap's own addressor for the static had been swapped in | never swap state/type accessors (`vau WZ Wz Ma Mi Mr`); swaps linked `-interposable` |
| `is T` false on old values after a swap | types declared in the edited file are referenced directly | one type per file (a limit InjectionIII shares) |
| `@Observable` UI stops updating after a swap | key paths refer to the swap's copy of the type | `@Observable` files rerun |
| Changed `some View` helper: modifiers silently lost | old callers read the new value as the old type | the return-type check (8.4) |
| Methods of non-final classes don't change | vtable dispatch doesn't use `__got` | repoint over all data sections |
| A swap "does nothing", app seems frozen | iOS suspended the app (background or lock screen) | the 5 s "hasn't picked up" warning; it loads when the app is in front |
| First swap after a reinstall ignored | old swaps in Documents, reused names | delete old swaps at start; millisecond-timestamp names |
| Each save swapped twice | two live sessions for one app | one session per app (`xtool/ios-live.pid`) |
| About 12 GB per iOS version under DeviceSupport | the raw shared cache (`dsc/`) is kept after the symbols are extracted | delete `dsc/` after extraction (README 6); it's re-copied if ever needed |
| `pymobiledevice3` venv broken after a mise update | built on a version-managed Python | build it on `/usr/bin/python3` |
| xtool's token readable by others | created 644 | `chmod 600` (README 3.5) |
| Orphaned `lldb-dap` processes after scripted tests | a test exited on a timeout without stopping its child | `dap-smoke-test.py` kills it at exit |

---

## 10. Testing recipes

- **Is the app's call going through a stub?**
  `llvm-objdump --macho -d xtool/<App>.app/<App> | grep -F 'symbol stub for: _$s<len><Module>'`.
  Nothing there means `-interposable` didn't reach the app link. Check the
  build data: `strings -n 4 .build/out/Intermediates.noindex/XCBuildData/*.xcbuilddata/task-store.msgpack | grep interposable`.
- **What did a swap contain?** `llvm-nm -m hot-<n>.dylib | grep '(__TEXT,__text)'`.
- **Is a library signed?** `rcodesign print-signature-info X.dylib | grep -E 'team_name|identifier'`.
- **VS Code F5 without VS Code:** run `ios-run-dev --serve` in the app (wait
  for `== Ready for the debugger`), then
  `~/.local/share/ios-run/tools/dap-smoke-test.py <app dir> <Name>App.init`,
  then `ios-run-dev --stop`. It attaches, stops at the breakpoint, reads the
  call stack and checks the Debug Console.
- **Hot reload end to end:** `new-ios-app Check --dir /tmp/x`, then
  `ios-run --live` (phone unlocked); add `let _ = print("body v1")` in the
  body and change it to `v2`. The terminal should show `swapped …` and then
  `body v2`. Remove the test app afterwards:
  `pymobiledevice3 apps uninstall XTL-xxxxxxxx.<prefix>.Check`.
- **Timing a swap:** the `== pushed … (build … ms, link+sign … ms, push … ms)`
  line.
- **lldb-dap protocol log:** `LLDBDAP_LOG=/path` in its environment.
  Memory-read storms show with `log enable -f /path gdb-remote packets` in
  initCommands (count `send packet: $x`).

---

## 11. Coupling points to re-check after updates

| Updated | Check |
|---|---|
| omarchy-apple-dev (`device-run.sh`) | it still sets `PMD3=` on its own line and runs `exec lldb "${lcmds[@]}"` (`ios-run` warns if not); its lldb setup commands still make sense for `ios-debug.py`; run the F5 smoke test |
| xtool / SwiftBuild | `swiftc-args.py` still finds the compiler command (`builtin-SwiftDriver -- …/swiftc`); objects still under `Intermediates.noindex/<Mod>.build/Debug-iphoneos/<Mod>-t.build/Objects-normal/arm64/` |
| Swift (a major version) | the hot reload return-type check's descriptor layout (8.4); run a swap that changes a helper's type and one that doesn't |
| iOS | a debug run (symbols extract) and a swap |
