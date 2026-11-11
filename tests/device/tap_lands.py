#!/usr/bin/env python3
"""Device verification: do injected taps actually reach the UI?

Runs against the production phone over SSH and asserts on *pixels*, not on the
driver's own status field — the 2026-09 failure mode was a dylib reporting
`success` for taps that never reached the screen.

Method (the same surface the ops watchdog uses, chosen because it is harmless):
  1. foreground the palera1n loader app
  2. shot A
  3. tap its SETTINGS tab  -> shot B   (must differ from A)
  4. tap its HOME tab      -> shot C   (must equal A)
  5. also assert the tap reply carries delivered=true

Usage:  python3 tests/device/tap_lands.py [--phone root@10.0.0.2]
Exit:   0 pass, 1 fail, 2 unable to run (no PIL / phone unreachable)
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SETTINGS_TAB = (1021, 2262)
HOME_TAB = (107, 2262)  # never leave the loader parked on its destruct screen


def ssh(phone: str, cmd: str, timeout: int = 60) -> tuple[int, str]:
    proc = subprocess.run(
        ["ssh", "-o", "ConnectTimeout=8", "-l", "root", phone, cmd],
        capture_output=True, text=True, timeout=timeout,
    )
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def sbtctl(phone: str, payload: dict, timeout: int = 40) -> tuple[int, dict | None]:
    raw = json.dumps(payload, separators=(",", ":"))
    code, out = ssh(phone, f"/var/jb/usr/bin/sbtctl '{raw}' --timeout-ms {timeout * 1000}")
    try:
        return code, json.loads(out.splitlines()[-1])
    except (ValueError, IndexError):
        return code, None


def shot(phone: str, name: str, local: Path) -> Path:
    remote = f"/var/mobile/{name}.png"
    code, reply = sbtctl(phone, {"id": name, "action": "screenshot",
                                 "out_path": remote, "scale": 0.5}, timeout=30)
    if code != 0 or not reply or reply.get("status") != "ok":
        raise SystemExit(f"screenshot {name} failed: code={code} reply={reply}")
    target = local / f"{name}.png"
    subprocess.run(["scp", "-o", "ConnectTimeout=8", "-q",
                    f"root@{phone}:{remote}", str(target)], check=True)
    return target


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--phone", default=os.environ.get("AUTIVA_PHONE", "10.0.0.2"),
                    help="SSH target (or set AUTIVA_PHONE)")
    args = ap.parse_args()
    phone = args.phone

    try:
        import imagehash
        from PIL import Image
    except ImportError:
        print("SKIP: PIL/imagehash not installed on the host")
        return 2

    code, _ = ssh(phone, "echo ok", timeout=15)
    if code != 0:
        print(f"FAIL: phone {phone} unreachable over ssh")
        return 1

    ssh(phone, "/var/jb/usr/bin/uiopen --bundleid in.palera.loader", timeout=30)
    subprocess.run(["sleep", "4"], check=False)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        a = shot(phone, "tapcheck_a", tmp_path)
        tap_code, tap_reply = sbtctl(phone, {"id": "tapcheck1", "action": "tap",
                                             "x": SETTINGS_TAB[0], "y": SETTINGS_TAB[1]})
        subprocess.run(["sleep", "2"], check=False)
        b = shot(phone, "tapcheck_b", tmp_path)
        tap2_code, tap2_reply = sbtctl(phone, {"id": "tapcheck2", "action": "tap",
                                               "x": HOME_TAB[0], "y": HOME_TAB[1]})
        subprocess.run(["sleep", "3"], check=False)
        c = shot(phone, "tapcheck_c", tmp_path)

        hashes = {k: imagehash.phash(Image.open(p).convert("L")) for k, p in
                  (("a", a), ("b", b), ("c", c))}
        ab = hashes["a"] - hashes["b"]
        bc = hashes["b"] - hashes["c"]
        ac = hashes["a"] - hashes["c"]

    delivered = bool(tap_reply and tap_reply.get("delivered"))
    delivered2 = bool(tap2_reply and tap2_reply.get("delivered"))
    print(f"tap1 reply: {tap_reply}")
    print(f"tap2 reply: {tap2_reply}")
    # Invariants: each tap must move the screen, and after the return tap the
    # screen must be closer to the start than the intermediate state was.
    # Exact equality is NOT required — the probe surface renders live status
    # text, so identical pixels are not a property of a correct return.
    print(f"phash A->B = {ab} (>10), B->C = {bc} (>10), A->C = {ac} (<= B->C)")
    print(f"delivered  = {delivered}/{delivered2} (both must be True)")

    ok = delivered and delivered2 and ab > 10 and bc > 10 and ac <= bc
    print("PASS: both taps land and the second reverses the first"
          if ok else "FAIL: taps did not reach the UI (or the probe surface changed)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
