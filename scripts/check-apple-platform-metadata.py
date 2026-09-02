#!/usr/bin/env python3

from __future__ import annotations

import json
import plistlib
import struct
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.3.0"
BUILD = "3"
BUNDLE_ID = "io.github.zzqDeco.OneReader"


def png_size(path: Path) -> tuple[int, int]:
    payload = path.read_bytes()[:24]
    if len(payload) != 24 or payload[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path.relative_to(ROOT)} is not a valid PNG")
    return struct.unpack(">II", payload[16:24])


def add_equal(errors: list[str], label: str, actual: object, expected: object) -> None:
    if actual != expected:
        errors.append(f"{label}: expected {expected!r}, found {actual!r}")


def main() -> int:
    errors: list[str] = []
    mac_info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    ios_info = plistlib.loads((ROOT / "Resources/Info-iOS.plist").read_bytes())

    for label, payload in (("macOS Info", mac_info), ("iOS Info", ios_info)):
        add_equal(errors, f"{label} bundle id", payload.get("CFBundleIdentifier"), BUNDLE_ID)
        add_equal(
            errors,
            f"{label} marketing version",
            payload.get("CFBundleShortVersionString"),
            VERSION,
        )
        add_equal(errors, f"{label} build", payload.get("CFBundleVersion"), BUILD)
        add_equal(errors, f"{label} executable", payload.get("CFBundleExecutable"), "OneReader")

    add_equal(errors, "macOS minimum version", mac_info.get("LSMinimumSystemVersion"), "26.1")
    add_equal(errors, "macOS icon", mac_info.get("CFBundleIconFile"), "AppIcon")
    add_equal(errors, "iOS device requirement", ios_info.get("LSRequiresIPhoneOS"), True)
    add_equal(
        errors,
        "iOS open-in-place",
        ios_info.get("LSSupportsOpeningDocumentsInPlace"),
        True,
    )
    if not ios_info.get("UISupportedInterfaceOrientations~ipad"):
        errors.append("iPad orientations are missing")

    package = (ROOT / "Package.swift").read_text(encoding="utf-8")
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    for expected in (
        '.macOS("26.1")',
        '.iOS("26.1")',
        '.library(name: "OneReader"',
        '.executable(name: "OneReaderApp"',
    ):
        if expected not in package:
            errors.append(f"Package.swift is missing {expected}")
    for expected in (
        "OneReader-macOS:",
        "OneReader-iOS:",
        'TARGETED_DEVICE_FAMILY: "1,2"',
        "SUPPORTS_MACCATALYST: false",
    ):
        if expected not in project:
            errors.append(f"project.yml is missing {expected}")

    master = ROOT / "Design/AppIcon/OneReader-AppIcon-1024.png"
    try:
        add_equal(errors, "icon master dimensions", png_size(master), (1024, 1024))
    except (OSError, ValueError) as error:
        errors.append(str(error))

    catalog = ROOT / "Resources/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((catalog / "Contents.json").read_text(encoding="utf-8"))
    images = contents.get("images", [])
    expected_idioms = {"mac", "iphone", "ipad", "ios-marketing"}
    actual_idioms = {image.get("idiom") for image in images}
    if actual_idioms != expected_idioms:
        errors.append(
            f"AppIcon idioms: expected {sorted(expected_idioms)}, found {sorted(actual_idioms)}"
        )
    for image in images:
        filename = image.get("filename")
        size = image.get("size", "0x0").split("x", 1)[0]
        scale = image.get("scale", "0x").removesuffix("x")
        if not filename:
            errors.append(f"AppIcon entry has no filename: {image}")
            continue
        path = catalog / filename
        try:
            pixels = round(float(size) * float(scale))
            add_equal(errors, f"{filename} dimensions", png_size(path), (pixels, pixels))
        except (OSError, ValueError) as error:
            errors.append(str(error))
    if not (ROOT / "Resources/AppIcon.icns").is_file():
        errors.append("Resources/AppIcon.icns is missing")

    for script in (
        "generate-app-icons.sh",
        "generate-xcode-project.sh",
        "check-xcode-project.sh",
        "build-ios-simulator.sh",
    ):
        if not (ROOT / "scripts" / script).is_file():
            errors.append(f"scripts/{script} is missing")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"Apple platform metadata validation passed ({len(images)} icon slots).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
