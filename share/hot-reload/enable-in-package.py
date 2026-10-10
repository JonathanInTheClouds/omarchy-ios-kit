#!/usr/bin/python3
"""Set up an xtool app's Package.swift for hot reload (ios-run --live).

    enable-in-package.py [PATH/TO/Package.swift]

Adds the HotReload package dependency and, on the app target, the HotReload
product plus the debug-only `-Xlinker -interposable` flag. Leaves a manifest
that already has them alone, and refuses one it doesn't recognise (it then
prints what to add by hand) rather than guessing.
"""
import os, re, sys

PKG = os.path.expanduser("~/.local/share/ios-run/hot-reload/HotReload")
path = sys.argv[1] if len(sys.argv) > 1 else "Package.swift"
src = open(path).read()

if "HotReload" in src and "-interposable" in src:
    print("already set up for hot reload")
    sys.exit(0)

manual = f"""Add these by hand:
  dependencies: [ .package(path: "{PKG}"), ]
  on the app target:
    dependencies: ["HotReload"],
    linkerSettings: [ .unsafeFlags(["-Xlinker", "-interposable"], .when(configuration: .debug)) ],"""

# The app target: the one named by the single library product.
m = re.search(r'\.library\(\s*name:\s*"([^"]+)"\s*,\s*targets:\s*\["([^"]+)"\]', src)
if not m:
    sys.exit("couldn't find the app's library product in " + path + "\n" + manual)
target = m.group(2)

# Only the plain target that `xtool new` writes: .target(name: "X") or
# .target(name: "X", <other arguments>) without dependencies/linkerSettings.
tm = re.search(r'\.target\(\s*name:\s*"' + re.escape(target) + r'"\s*(,(?P<rest>[^()]*(\([^()]*\)[^()]*)*))?\)', src)
if not tm or (tm.group("rest") and re.search(r"\b(dependencies|linkerSettings)\s*:", tm.group("rest"))):
    sys.exit(f"the {target} target already has dependencies or linker settings\n" + manual)
line_start = src.rfind("\n", 0, tm.start()) + 1
indent = src[line_start: tm.start()] if src[line_start: tm.start()].strip() == "" else "        "
inner = indent + "    "
rest = (tm.group("rest") or "").strip().rstrip(",")
new_target = (
    f'.target(\n'
    f'{inner}name: "{target}",\n'
    + (f"{inner}{rest},\n" if rest else "")
    + f'{inner}dependencies: ["HotReload"],\n'
    f"{inner}linkerSettings: [\n"
    f"{inner}    // Hot reload (ios-run --live): route the app's calls to its own\n"
    f"{inner}    // functions through stubs a swapped-in version can take over.\n"
    f'{inner}    .unsafeFlags(["-Xlinker", "-interposable"], .when(configuration: .debug)),\n'
    f"{inner}]\n"
    f"{indent})"
)
src = src[: tm.start()] + new_target + src[tm.end():]

dep = f'.package(path: "{PKG}"),'
if re.search(r"\n\s*dependencies:\s*\[", src[: src.find(".target(")]):
    # A package-level dependencies list exists already: add to it.
    src = re.sub(r"(\n(\s*)dependencies:\s*\[)", lambda m: m.group(1) + f"\n{m.group(2)}    // Live code swaps from `ios-run --live` (debug builds only).\n{m.group(2)}    {dep}", src, count=1)
else:
    # The package's own `targets: [` ends its line; the library product's
    # `targets: ["X"]` doesn't.
    tg = re.search(r"\n([ \t]*)targets:\s*\[[ \t]*\n", src)
    if not tg:
        sys.exit("couldn't find `targets:` in " + path + "\n" + manual)
    ind = tg.group(1)
    src = src[: tg.start()] + (
        f"\n{ind}dependencies: [\n"
        f"{ind}    // Live code swaps from `ios-run --live` (debug builds only).\n"
        f"{ind}    {dep}\n"
        f"{ind}],"
    ) + src[tg.start():]

open(path, "w").write(src)
print(f"set up {path} for hot reload (target {target})")
