#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LOCK_PATH = ROOT / "Package.resolved"
EXPECTED_DIRECT = {
    "swiftagent": "2.0.1",
    "anyfoundationmodels": "0.5.5",
    "grdb.swift": "7.10.0",
    "zipfoundation": "0.9.20",
    "swiftsoup": "2.13.9",
    "swift-markdown": "0.8.0",
}
PEER_LOCATION = "https://github.com/1amageek/swift-peer-connectivity.git"
PEER_VERSION = "0.2.5"
PEER_REVISION = "447dfb9f6587a5f38ade79e1e5d3096c02c2717c"


def main() -> int:
    payload = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    pins = payload.get("pins", [])
    by_identity = {pin["identity"]: pin for pin in pins}
    errors: list[str] = []

    for identity, version in EXPECTED_DIRECT.items():
        pin = by_identity.get(identity)
        actual = pin and pin.get("state", {}).get("version")
        if actual != version:
            errors.append(f"{identity}: expected {version}, found {actual}")

    peers = [pin for pin in pins if pin.get("location") == PEER_LOCATION]
    if len(peers) != 1:
        errors.append(f"peer shim: expected one lock pin, found {len(peers)}")
    else:
        state = peers[0].get("state", {})
        if state.get("version") != PEER_VERSION:
            errors.append(
                f"peer shim: expected version {PEER_VERSION}, found {state.get('version')}"
            )
        if state.get("revision") != PEER_REVISION:
            errors.append(
                "peer shim: generated mirror revision does not match committed lock"
            )

    if any(pin.get("identity") == "swift-libp2p" for pin in pins):
        errors.append("unused Swift 6.4 swift-libp2p graph must not be resolved")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print(f"dependency lock validation passed ({len(pins)} pins)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
