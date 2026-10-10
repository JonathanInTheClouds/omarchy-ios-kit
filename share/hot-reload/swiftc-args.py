#!/usr/bin/python3
"""Print the exact swiftc command xtool (SwiftBuild) used for the app target.

    swiftc-args.py [APP_DIR [MODULE]]           prints a JSON list: [cwd, arg0, ...]
    swiftc-args.py --fast SHADOW APP_DIR MODULE  the same, trimmed for swaps

--fast drops what a swap doesn't need (indexing, module and header output,
explicit-module scanning: implicit modules with a warm cache are much faster)
and points the output file map at SHADOW, so xtool's own build state is never
touched. Measured on TodoApp: one changed file compiles in about 0.4 s
(xtool dev build: about 3.5 s); the first run fills the cache (about 4 s).

SwiftBuild keeps each task's command line in
.build/out/Intermediates.noindex/XCBuildData/*.xcbuilddata/task-store.msgpack.
This decodes that msgpack file (a minimal decoder: no third-party module) and
finds the Swift driver command for the app's module: stored as
["builtin-SwiftDriver", "--", "/…/swiftc", args…] with `-module-name <App>` and `-c`.
hot-swap.sh reruns that command to recompile only edited files (the driver is
incremental), which skips xtool's planning, the app relink and repackaging.
"""
import glob, json, os, struct, sys


def decode(buf):
    """Decode every msgpack value in buf (a file may hold several)."""
    pos = 0

    def read(n):
        nonlocal pos
        chunk = buf[pos:pos + n]
        pos += n
        return chunk

    def value():
        nonlocal pos
        b = buf[pos]
        pos += 1
        if b <= 0x7F:
            return b
        if 0x80 <= b <= 0x8F:
            return {key(): value() for _ in range(b & 0x0F)}
        if 0x90 <= b <= 0x9F:
            return [value() for _ in range(b & 0x0F)]
        if 0xA0 <= b <= 0xBF:
            return read(b & 0x1F).decode("utf-8", "replace")
        if b >= 0xE0:
            return b - 0x100
        if b == 0xC0:
            return None
        if b in (0xC2, 0xC3):
            return b == 0xC3
        if b in (0xC4, 0xC5, 0xC6):  # bin 8/16/32
            n = struct.unpack(">" + "BHI"[b - 0xC4], read(1 << (b - 0xC4)))[0]
            return read(n)
        if b in (0xC7, 0xC8, 0xC9):  # ext 8/16/32
            n = struct.unpack(">" + "BHI"[b - 0xC7], read(1 << (b - 0xC7)))[0]
            read(1)
            return read(n)
        if b == 0xCA:
            return struct.unpack(">f", read(4))[0]
        if b == 0xCB:
            return struct.unpack(">d", read(8))[0]
        if 0xCC <= b <= 0xCF:  # uint 8..64
            return int.from_bytes(read(1 << (b - 0xCC)), "big")
        if 0xD0 <= b <= 0xD3:  # int 8..64
            return int.from_bytes(read(1 << (b - 0xD0)), "big", signed=True)
        if 0xD4 <= b <= 0xD8:  # fixext 1..16
            read(1)
            return read(1 << (b - 0xD4))
        if b in (0xD9, 0xDA, 0xDB):  # str 8/16/32
            n = struct.unpack(">" + "BHI"[b - 0xD9], read(1 << (b - 0xD9)))[0]
            return read(n).decode("utf-8", "replace")
        if b in (0xDC, 0xDD):  # array 16/32
            n = struct.unpack(">" + "HI"[b - 0xDC], read(2 << (b - 0xDC)))[0]
            return [value() for _ in range(n)]
        if b in (0xDE, 0xDF):  # map 16/32
            n = struct.unpack(">" + "HI"[b - 0xDE], read(2 << (b - 0xDE)))[0]
            return {key(): value() for _ in range(n)}
        raise ValueError(f"unknown msgpack byte 0x{b:02x} at {pos - 1}")

    def key():
        k = value()
        return k if isinstance(k, (str, int, float, bool, type(None))) else repr(k)

    out = []
    while pos < len(buf):
        out.append(value())
    return out


def find_commands(obj, module, found):
    if isinstance(obj, list):
        # Stored as ["builtin-SwiftDriver", "--", "/…/swiftc", args…].
        start = next((i for i, a in enumerate(obj[:4]) if isinstance(a, str) and a.endswith("/swiftc")), None)
        if start is not None and len(obj) > start + 3 and "-c" in obj:
            cmd = obj[start:]
            if all(isinstance(a, str) for a in cmd):
                for i, a in enumerate(cmd[:-1]):
                    if a == "-module-name" and cmd[i + 1] == module:
                        found.append(cmd)
                        return
        for item in obj:
            find_commands(item, module, found)
    elif isinstance(obj, dict):
        for item in obj.values():
            find_commands(item, module, found)


DROP_WITH_VALUE = {"-index-store-path", "-emit-module-path", "-emit-objc-header-path",
                   "-const-gather-protocols-list", "-clang-scanner-module-cache-path",
                   "-sdk-module-cache-path", "-clang-build-session-file",
                   "-dependency-scan-serialize-diagnostics-path"}
DROP = {"-emit-module", "-emit-objc-header", "-emit-const-values", "-explicit-module-build",
        "-validate-clang-modules-once", "-experimental-emit-module-separately", "-save-temps",
        "-serialize-diagnostics", "-emit-dependencies"}


def fast(args, shadow):
    """The swap version of the command: see the module docstring."""
    os.makedirs(shadow, exist_ok=True)
    objdir = os.path.dirname(args[args.index("-output-file-map") + 1])
    out, i, seen_cache = [], 0, False
    while i < len(args):
        x = args[i]
        if x in DROP_WITH_VALUE:
            i += 2
            continue
        if x in DROP:
            i += 1
            continue
        if x == "-module-cache-path":
            if seen_cache:  # keep only the first (ModuleCache.noindex)
                i += 2
                continue
            seen_cache = True
        if x == "-output-file-map":
            m = json.loads(open(args[i + 1]).read().replace(objdir, shadow))
            path = os.path.join(shadow, "OutputFileMap.json")
            json.dump(m, open(path, "w"))
            out += [x, path]
            i += 2
            continue
        out.append(x)
        i += 1
    return out


def main():
    argv = sys.argv[1:]
    shadow = None
    if argv[:1] == ["--fast"]:
        shadow = os.path.abspath(argv[1])
        argv = argv[2:]
    sys.argv = [sys.argv[0]] + argv
    app = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    stores = sorted(glob.glob(os.path.join(
        app, ".build/out/Intermediates.noindex/XCBuildData/*.xcbuilddata/task-store.msgpack")),
        key=os.path.getmtime)
    if not stores:
        sys.exit("no xtool build data yet: run `xtool dev build` first")
    # The app module: the target whose objects hot-swap uses (dir name = target).
    module = sys.argv[2] if len(sys.argv) > 2 else os.path.basename(app)
    found = []
    find_commands(decode(open(stores[-1], "rb").read()), module, found)
    if not found:
        sys.exit(f"no swiftc command for module {module} in {stores[-1]}")
    args = found[0]
    cwd = args[args.index("-working-directory") + 1] if "-working-directory" in args else app
    if shadow:
        args = fast(args, shadow)
    print(json.dumps([cwd] + args))


if __name__ == "__main__":
    main()
