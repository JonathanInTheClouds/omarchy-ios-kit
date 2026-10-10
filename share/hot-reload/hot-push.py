#!/usr/bin/env python3
"""Keep one connection to an app's container open and push files over it.

    hot-push.py BUNDLE_ID PORT_FILE     (run with ~/pymobile3-venv/bin/python)

A new house_arrest (AFC) connection for every swap costs about 1.25 s; this
connects once and serves requests on 127.0.0.1 (a random port, written to
PORT_FILE). ios-run --live starts it; hot-swap.sh talks to it through bash's
/dev/tcp, one request per connection:

    request:  "<local path>\\t<remote path>\\n"
    reply:    "ok <ms>\\n"  or  "error <message>\\n"

If the connection to the phone fails (app reinstalled, cable unplugged), it
reconnects once and retries. Only localhost can connect.
"""
import asyncio
import os
import sys
import time

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService

bundle_id, port_file = sys.argv[1], sys.argv[2]
service = None


async def connect():
    global service
    if service is not None:
        try:
            await service.close()
        except Exception:
            pass
    lockdown = await create_using_usbmux()
    service = await HouseArrestService.create(lockdown=lockdown, bundle_id=bundle_id)


async def push(local, remote):
    data = open(local, "rb").read()
    for attempt in (1, 2):
        try:
            if service is None:
                await connect()
            await service.set_file_contents(remote, data)
            return
        except Exception:
            if attempt == 2:
                raise
            await connect()


async def handle(reader, writer):
    try:
        line = (await reader.readline()).decode().rstrip("\n")
        local, remote = line.split("\t", 1)
        start = time.monotonic()
        await push(local, remote)
        writer.write(f"ok {int((time.monotonic() - start) * 1000)}\n".encode())
    except Exception as e:
        writer.write(f"error {type(e).__name__}: {e}\n".replace("\n", " ").strip().encode() + b"\n")
    await writer.drain()
    writer.close()


async def main():
    await connect()
    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    tmp = port_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(port))
    os.replace(tmp, port_file)
    async with server:
        await server.serve_forever()


asyncio.run(main())
