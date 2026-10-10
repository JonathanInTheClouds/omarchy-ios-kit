#!/usr/bin/env bash
# Swap edited Swift files into the running app (hot reload; see
# ~/.local/share/ios-run/docs/HOW-IT-WORKS.md).
#   hot-swap.sh FILE.swift [FILE.swift ...]     from the app's folder
# ios-run --live calls this on every save. The app must be running a debug
# build that uses the HotReload package and links with -interposable.
# 1. Compile: with HOT_SWAP_FAST_ARGS (set by ios-run --live) xtool's own
#    swiftc command reruns, trimmed, into .build/hot-reload/objects (only
#    edited files compile, about 0.4 s); otherwise `xtool dev build` (about
#    3.5 s) and the object from xtool's Intermediates.
# 2. Link their .o files into one hot-N.dylib; references to the rest of the
#    app stay undefined and resolve at load time (dynamic_lookup). It's linked
#    -interposable too, so its references to its own statics and types go
#    through slots that dyld binds to the app's originals (the client then
#    points the slots for swapped functions at the new code). Autolinking is
#    off (-ignore_auto_link): parsing SwiftUI's and Foundation's .tbd files
#    took about 310 ms per link; the running app provides those symbols.
# 3. Sign it with the development identity and push it into the app's
#    Documents, where HotReloader loads it and repoints the app's calls. With
#    HOT_SWAP_PUSH_PORT_FILE the push goes over hot-push.py's open connection.
# Exit status: 0 pushed, 1 build or link failed (errors printed), 2 setup
# problem, 3 the change can't be swapped and needs a normal run.
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: hot-swap.sh FILE.swift..." >&2; exit 2; }
[ -f xtool.yml ] || { echo "run from the app's folder" >&2; exit 2; }
B=$HOME/.config/swiftpm/swift-sdks/darwin.artifactbundle
SDK=$(ls -d "$B"/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS[0-9]*.sdk | sort -V | tail -n1)
RD=$B/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift
# Compiler runtime helpers (e.g. ___isPlatformVersionAtLeast, used by
# `if #available` and by SwiftUI code) are linked privately into the app, so a
# swap can't borrow them from it at load time: link its own copy.
CLANG_RT=$(ls "$B"/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/*/lib/darwin/libclang_rt.ios.a 2>/dev/null | sort -V | tail -n1)
DEV=$HOME/.config/omarchy-apple-dev/development
PMD3=$HOME/pymobile3-venv/bin/pymobiledevice3
[ -f "$DEV/key.pem" ] && [ -f "$DEV/cert.der" ] || {
  echo "no development identity in $DEV (run ~/.local/share/ios-run/hot-reload/extract-dev-identity.py)" >&2; exit 2; }
export PATH="$(dirname "$(readlink -f "$(command -v swift)")"):$PATH"
now() { date +%s%N; }
ms() { echo $(( ($2 - $1) / 1000000 )); }

bid_suffix=$(awk '/^bundleID:/ {print $2}' xtool.yml)
# ios-run --live passes the installed id (it already looked it up).
bid=${HOT_SWAP_BID:-$("$PMD3" apps list 2>/dev/null | /usr/bin/python3 -c '
import json, sys
b = sys.argv[1]
print(next((k for k in json.load(sys.stdin) if k == b or k.endswith("." + b)), ""))' "$bid_suffix")}
[ -n "$bid" ] || { echo "app $bid_suffix isn't installed" >&2; exit 2; }

# Types whose behaviour depends on type identity break when their own file is
# swapped (the swap has its own copy of the type, see HOW-IT-WORKS.md):
# @Observable tracks properties by key path, so observation would silently stop.
for f in "$@"; do
  if grep -qE '^[[:space:]]*@Observable\b' "$f"; then
    echo "this change needs a normal run: $(basename "$f") declares an @Observable type (swapping it would stop observation)" >&2
    exit 3
  fi
done

t0=$(now)
log=$(mktemp)
out=$(mktemp -d)
trap 'rm -rf "$out" "$log"' EXIT
# Fast path (ios-run --live sets HOT_SWAP_FAST_ARGS): rerun xtool's own swiftc
# command, trimmed (swiftc-args.py --fast), into a shadow object folder. It's
# incremental, so only edited files compile: about 0.4 s instead of 3.5 s.
fast=""
# Used once ios-run's warm-up compile has finished (<args>.ready).
if [ -n "${HOT_SWAP_FAST_ARGS:-}" ] && [ -f "$HOT_SWAP_FAST_ARGS" ] && [ -f "$HOT_SWAP_FAST_ARGS.ready" ]; then
  fast=$HOT_SWAP_FAST_ARGS
  if ! /usr/bin/python3 -c 'import json, subprocess, sys
a = json.load(open(sys.argv[1]))
sys.exit(subprocess.run(a[1:], cwd=a[0], stdout=subprocess.DEVNULL, stderr=sys.stderr).returncode)' "$fast" 2>"$log"; then
    sed 's/\x1b\[[0-9;]*m//g; s/\r//g' "$log" | grep -E "^/.*: (error|warning): " | sort -u | head -20 >&2
    echo "build failed: nothing swapped" >&2
    exit 1
  fi
elif ! "$HOME/.local/bin/xtool" dev build >"$log" 2>&1; then
  # The compiler's own lines (file:line: error: ...), without colour codes.
  sed 's/\x1b\[[0-9;]*m//g; s/\r//g' "$log" | grep -E "^/.*: (error|warning): " | sort -u | head -20 >&2
  echo "build failed: nothing swapped" >&2
  exit 1
fi
t1=$(now)

objs=()
if [ -n "$fast" ]; then
  # The shadow output file map gives each source's object.
  mapfile -t objs < <(/usr/bin/python3 -c 'import json, os, sys
a = json.load(open(sys.argv[1]))
m = json.load(open(a[a.index("-output-file-map") + 1]))
for f in sys.argv[2:]:
    entry = m.get(os.path.realpath(f)) or m.get(os.path.abspath(f)) or {}
    print(entry.get("object", ""))' "$fast" "$@")
  for i in "${!objs[@]}"; do
    [ -f "${objs[$i]}" ] || { echo "no object file for ${@:$((i + 1)):1} (is it part of the app target?)" >&2; exit 1; }
  done
fi
for f in "$@"; do
  [ -z "$fast" ] || break
  base=$(basename "$f" .swift)
  # The target that compiled it: its *-t.build has <base>.o and lists the
  # source in its SwiftFileList.
  obj=""
  for list in .build/out/Intermediates.noindex/*.build/Debug-iphoneos/*-t.build/Objects-normal/arm64/*.SwiftFileList; do
    if grep -qxF "$(readlink -f "$f")" "$list" 2>/dev/null; then
      obj="$(dirname "$list")/$base.o"
      break
    fi
  done
  [ -f "$obj" ] || { echo "no object file for $f (is it part of the app target?)" >&2; exit 1; }
  objs+=("$obj")
done

# Unique and increasing across runs and reinstalls (the app loads in number
# order and skips names it has seen).
n=$(date +%s%3N)
if ! swiftc -resource-dir "$RD" -sdk "$SDK" -target arm64-apple-ios17.0 \
    -use-ld=lld -ld-path="$B/toolset/bin/ld64.lld" -emit-library \
    -Xlinker -undefined -Xlinker dynamic_lookup -Xlinker -flat_namespace -Xlinker -interposable \
    -Xlinker -ignore_auto_link \
    -Xlinker -install_name -Xlinker "@rpath/hot-$n.dylib" \
    "${objs[@]}" ${CLANG_RT:+"$CLANG_RT"} -o "$out/hot-$n.dylib" 2>"$log"; then
  grep -v "does not support linking for platform iOS" "$log" >&2
  echo "link failed: nothing swapped" >&2
  exit 1
fi
# Every symbol the swap leaves to the app must be one the app exports:
# a private one (static helpers, private externs) can't be found at load
# time, and dlopen would fail on the phone. Say so here instead.
app_dir=$(ls -d xtool/*.app 2>/dev/null | head -n1)
app_exe="$app_dir/$(basename "$app_dir" .app)"
NM=$(dirname "$(readlink -f "$(command -v swift)")")/llvm-nm
if [ -f "$app_exe" ] && [ -x "$NM" ]; then
  "$NM" -u "$out/hot-$n.dylib" | sed 's/^ *U //' | sort -u >"$out/undef"
  # The app's private symbols: cached until the app binary changes.
  cache=".build/hot-reload/private.$(stat -c %Y "$app_exe")"
  if [ ! -f "$cache" ]; then
    mkdir -p .build/hot-reload
    rm -f .build/hot-reload/private.*
    "$NM" -m "$app_exe" | grep -E "non-external|private external" | awk '{print $NF}' | sort -u >"$cache"
  fi
  cp "$cache" "$out/private"
  missing=$(comm -12 "$out/undef" "$out/private")
  if [ -n "$missing" ]; then
    echo "this change needs a normal run: it uses symbols the app keeps private:" >&2
    printf '%s\n' "$missing" | head -5 | sed 's/^/  /' >&2
    exit 3
  fi
fi
"$HOME/.local/bin/rcodesign" sign --pem-file "$DEV/key.pem" --certificate-der-file "$DEV/cert.der" \
  --timestamp-url none --binary-identifier "$bid_suffix.hot-$n" "$out/hot-$n.dylib" >/dev/null 2>&1
t2=$(now)
# ios-run --live keeps a connection to the phone open (hot-push.py) and passes
# its port file: about 10 ms instead of 1.5 s for a fresh connection.
pushed=""
if [ -n "${HOT_SWAP_PUSH_PORT_FILE:-}" ] && [ -s "$HOT_SWAP_PUSH_PORT_FILE" ]; then
  if exec 3<>"/dev/tcp/127.0.0.1/$(cat "$HOT_SWAP_PUSH_PORT_FILE")" 2>/dev/null; then
    printf '%s\t%s\n' "$out/hot-$n.dylib" "/Documents/hot-$n.dylib" >&3
    read -r -t 20 reply <&3 || reply=""
    exec 3<&-
    [[ "$reply" == ok* ]] && pushed=1
  fi
fi
[ -n "$pushed" ] || "$PMD3" apps push "$bid" "$out/hot-$n.dylib" "/Documents/hot-$n.dylib" >/dev/null
t3=$(now)
echo "pushed $(for f in "$@"; do basename "$f"; done | paste -sd' ') as hot-$n.dylib (build $(ms $t0 $t1) ms, link+sign $(ms $t1 $t2) ms, push $(ms $t2 $t3) ms)"
