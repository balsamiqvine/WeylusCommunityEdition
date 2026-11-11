#!/usr/bin/env python3
"""Wired mode for Weylus Pencil: relay Weylus over the USB cable.

iOS only allows the computer to open connections to an app over USB (via usbmuxd), so the
Weylus Pencil app listens on a port in USB mode, and this bridge connects into it and relays
everything to the local Weylus server. It waits for the iPad and the app, and reconnects
whenever either goes away. No dependencies beyond Python 3 and a running usbmuxd.

Usage: weylus-usb-bridge.py [--weylus-port 1701] [--device-port 1701]
"""

import argparse
import plistlib
import socket
import struct
import threading
import time

USBMUXD_SOCKET = "/var/run/usbmuxd"


def usbmux_request(sock, payload, tag=1):
    """Send a plist message (protocol version 1, message type 8) and return the reply."""
    body = plistlib.dumps(payload)
    sock.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, tag) + body)
    header = recv_exact(sock, 16)
    length, _version, _type, _tag = struct.unpack("<IIII", header)
    return plistlib.loads(recv_exact(sock, length - 16))


def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("usbmuxd closed the connection")
        data += chunk
    return data


def base_message(kind):
    return {"MessageType": kind, "ClientVersionString": "weylus-usb-bridge", "ProgName": "weylus-usb-bridge"}


def usb_devices():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(USBMUXD_SOCKET)
        reply = usbmux_request(s, base_message("ListDevices"))
    return [
        d["DeviceID"]
        for d in reply.get("DeviceList", [])
        if d.get("Properties", {}).get("ConnectionType") == "USB"
    ]


def connect_device(device_id, port):
    """Open a TCP connection to `port` on the device through the USB cable."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(USBMUXD_SOCKET)
    msg = base_message("Connect")
    msg["DeviceID"] = device_id
    msg["PortNumber"] = socket.htons(port)  # usbmuxd wants network byte order
    reply = usbmux_request(s, msg)
    if reply.get("MessageType") != "Result" or reply.get("Number") != 0:
        s.close()
        return None  # app not running / not in USB mode
    return s  # from now on the socket is a raw tunnel to the app


def pump(src, dst, done):
    try:
        while True:
            data = src.recv(1 << 18)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        done.set()


def relay(device_sock, weylus_port):
    weylus = socket.create_connection(("127.0.0.1", weylus_port))
    weylus.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    done = threading.Event()
    threading.Thread(target=pump, args=(device_sock, weylus, done), daemon=True).start()
    threading.Thread(target=pump, args=(weylus, device_sock, done), daemon=True).start()
    done.wait()
    for s in (device_sock, weylus):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        s.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--weylus-port", type=int, default=1701, help="local Weylus port")
    ap.add_argument("--device-port", type=int, default=1701, help="port the app listens on in USB mode")
    args = ap.parse_args()

    status = None

    def say(msg):
        nonlocal status
        if msg != status:
            print(msg, flush=True)
            status = msg

    while True:
        try:
            devices = usb_devices()
        except OSError as e:
            say(f"usbmuxd not reachable ({e}); is it installed and running?")
            time.sleep(2)
            continue
        if not devices:
            say("Waiting for an iPad on USB...")
            time.sleep(1)
            continue
        sock = None
        for dev in devices:
            sock = connect_device(dev, args.device_port)
            if sock:
                break
        if not sock:
            say("iPad connected. Waiting for Weylus Pencil in USB mode...")
            time.sleep(1)
            continue
        try:
            say("Connected over USB, relaying to Weylus.")
            relay(sock, args.weylus_port)
            say("Disconnected.")
        except OSError as e:
            say(f"Can't reach Weylus on port {args.weylus_port} ({e}); is it running?")
            sock.close()
            time.sleep(2)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
