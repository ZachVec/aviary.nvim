"""Deterministic interactive agent: records bytes without submitting messages."""
import json
import os
from pathlib import Path
import sys
import tty

name, output = sys.argv[1:]
Path(output).write_text(json.dumps({"hex": "", "text": ""}), encoding="utf-8")
tty.setraw(sys.stdin.fileno())
print(f"\x1b[2J\x1b[HPOC {name} READY — 中文 / λ / 🌿\r", flush=True)
print("Paste fills input; Enter records submission.\r", flush=True)
print("\x1b[?2004h", end="", flush=True)
received = bytearray()
while True:
    data = os.read(sys.stdin.fileno(), 4096)
    if b"\x03" in data:
        break
    received.extend(data)
    Path(output).write_text(json.dumps({"hex": received.hex(), "text": received.decode("utf-8", "replace")}), encoding="utf-8")
    os.write(sys.stdout.fileno(), data.replace(b"\x1b[200~", b"").replace(b"\x1b[201~", b"").replace(b"\n", b"\r\n"))
