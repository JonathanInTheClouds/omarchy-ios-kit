#!/usr/bin/env python3
"""Check VS Code's F5 path without VS Code: drive lldb-dap like VS Code does.

Usage, from an xtool project with the new-ios-app .vscode setup:
    ios-run-dev --serve &          # wait for "== Ready for the debugger"
    dap-smoke-test.py [PROJECT_DIR] [FUNCTION]
    ios-run-dev --stop

FUNCTION defaults to <Name>App.init (from the folder name), which runs at
startup, so the test doesn't need the phone unlocked or a tap. It checks:
attach, a function breakpoint stopping, the call stack, and that the app's
output reaches the Debug Console (it makes the app write a line with write(1)).
Exit 0 when all pass.
"""
import json, os, queue, subprocess, sys, threading, time

project = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
func = sys.argv[2] if len(sys.argv) > 2 else os.path.basename(project) + "App.init"
attach_py = os.path.join(project, "xtool", "ios-debug.py")
if not os.path.exists(attach_py):
    sys.exit(f"{attach_py} missing: run `ios-run-dev --serve` in {project} first")

p = subprocess.Popen(["/usr/lib/swift/usr/bin/lldb-dap"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, cwd=project)
# Never leave lldb-dap behind, also when a check times out (sys.exit): six
# orphans from earlier test runs were found hours later.
import atexit
atexit.register(lambda: p.poll() is None and p.kill())
q, seen, console, seq = queue.Queue(), [], [], [0]


def reader():
    f = p.stdout
    while True:
        headers = {}
        while True:
            line = f.readline()
            if not line:
                return
            line = line.decode().strip()
            if not line:
                break
            k, v = line.split(":", 1)
            headers[k] = v.strip()
        m = json.loads(f.read(int(headers["Content-Length"])))
        if m.get("type") == "event" and m["event"] == "output":
            console.append(m["body"]["output"])
        q.put(m)


threading.Thread(target=reader, daemon=True).start()


def send(cmd, args=None):
    seq[0] += 1
    body = json.dumps({"seq": seq[0], "type": "request", "command": cmd,
                       "arguments": args or {}}).encode()
    p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    p.stdin.flush()
    return seq[0]


def wait(pred, timeout=60):
    # Replies can arrive out of order (attach answers late), so keep the rest.
    for m in seen:
        if pred(m):
            seen.remove(m)
            return m
    end = time.time() + timeout
    while time.time() < end:
        try:
            m = q.get(timeout=1)
        except queue.Empty:
            continue
        if pred(m):
            return m
        seen.append(m)
    sys.exit("FAIL: timed out (if no stop arrives, check DeviceSupport/<build>/Symbols/.all-extracted)")


def resp(s):
    return lambda m: m.get("type") == "response" and m["request_seq"] == s


def ev(e):
    return lambda m: m.get("type") == "event" and m["event"] == e


start = time.time()
wait(resp(send("initialize", {"adapterID": "lldb-dap", "linesStartAt1": True,
                              "columnsStartAt1": True, "pathFormat": "path"})))
attach = send("attach", {"attachCommands": [f"script exec(open('{attach_py}').read())"]})
wait(ev("initialized"))
r = wait(resp(send("setFunctionBreakpoints", {"breakpoints": [{"name": func}]})))
print("breakpoint", func, "verified:", r["body"]["breakpoints"][0].get("verified"))
wait(resp(send("configurationDone")))
r = wait(resp(attach))
print("attach:", r["success"], r.get("message", ""))
st = wait(ev("stopped"))
print(f"stopped: {st['body'].get('reason')} after {time.time() - start:.1f}s")
r = wait(resp(send("stackTrace", {"threadId": st["body"]["threadId"], "levels": 3})))
for f in r["body"]["stackFrames"]:
    print("  frame:", f["name"][:90])
send("evaluate", {"expression": 'expression -l c -- (long)write(1, "dap-smoke-probe\\n", 16)',
                  "context": "repl", "frameId": r["body"]["stackFrames"][0]["id"]})
time.sleep(3)
ok_console = any("dap-smoke-probe" in c for c in console)
print("app output in Debug Console:", ok_console)
wait(resp(send("disconnect", {"terminateDebuggee": False})))
sys.exit(0 if st["body"].get("reason") == "breakpoint" and ok_console else 1)
