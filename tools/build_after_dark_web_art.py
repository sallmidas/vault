#!/usr/bin/env python3
"""Build web-sized After Dark Set 1 card art (480 jpg/webp, 900 webp). No secrets."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

from PIL import Image

ROOT = Path("/workspace/Vaulted Shelf Collector Cards/print-packs/Set 1 Vault After Dark")
TRIMS = ROOT / "trim-5x7-jpgs"
TUE_BLEED = Path("/workspace/Vaulted Shelf Collector Cards/print-packs/Shipping Tuesday Set 1 copies/_work")
OUT = Path("/workspace/vault-claim-preview/assets/cards")
BLEED_X, BLEED_Y, TRIM_W, TRIM_H = 37, 37, 1500, 2100

# Vault card_no -> (stem used in print files, or special tuesday bleed)
CARDS = {
    "020": ("trim", "01_tumbler_01of12", "tumbler", 1),
    "021": ("trim", "02_lockette_01of12", "lockette", 1),
    "022": ("trim", "02_lockette_02of12", "lockette", 2),
    "023": ("trim", "03_ace_01of12", "ace", 1),
    "024": ("trim", "04_queen_01of12", "queen", 1),
    "025": ("trim", "04_queen_02of12", "queen", 2),
    "026": ("trim", "05_buzzby_01of12", "buzzby", 1),
    "027": ("trim", "06_keeper_01of12", "keeper", 1),
    "028": ("trim", "06_keeper_02of12", "keeper", 2),
    "029": ("tue", "01_tumbler_02of12", "tumbler", 2),
    "030": ("tue", "03_ace_02of12", "ace", 2),
    "031": ("tue", "04_queen_03of12", "queen", 3),
    "032": ("tue", "05_buzzby_02of12", "buzzby", 2),
}

SIZES = {"480": (480, 672), "900": (900, 1260)}


def load_builder():
    path = ROOT / "_work" / "build_set1_cards.py"
    spec = importlib.util.spec_from_file_location("build_set1_cards", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["build_set1_cards"] = mod
    spec.loader.exec_module(mod)
    return mod


def crop_bleed(im: Image.Image) -> Image.Image:
    return im.crop((BLEED_X, BLEED_Y, BLEED_X + TRIM_W, BLEED_Y + TRIM_H))


def save_web(im: Image.Image, no: str, side: str) -> None:
    rgb = im.convert("RGB")
    for label, size in SIZES.items():
        resized = rgb.resize(size, Image.Resampling.LANCZOS)
        stem = OUT / f"{no}-{side}-{label}"
        if label == "480":
            resized.save(stem.with_suffix(".jpg"), "JPEG", quality=88, optimize=True, progressive=True)
            resized.save(stem.with_suffix(".webp"), "WEBP", quality=80, method=6)
        else:
            resized.save(stem.with_suffix(".webp"), "WEBP", quality=82, method=6)


def front_image(b, spec):
    kind = spec[0]
    stem = spec[1]
    if kind == "trim":
        path = TRIMS / f"{stem}_FRONT_5x7.jpg"
        return Image.open(path)
    bleed = TUE_BLEED / f"{stem}_FRONT_bleed.jpg"
    return crop_bleed(Image.open(bleed))


def back_image(b, spec):
    # Print-pack trim backs were accidentally identical copies. Always rebuild
    # the typed back at the correct character and copy number.
    if len(spec) >= 4:
        key, copy = spec[2], spec[3]
    else:
        # trim tuples are ("trim", stem) — parse "01_tumbler_01of12"
        parts = spec[1].split("_")
        key = parts[1]
        copy = int(parts[2].split("of")[0])
    bleed = b.build_back(key, copy, 12)
    return crop_bleed(bleed)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    b = load_builder()
    for no, spec in CARDS.items():
        front = front_image(b, spec)
        back = back_image(b, spec)
        if front.size != (TRIM_W, TRIM_H):
            raise SystemExit(f"{no} front size {front.size}")
        if back.size != (TRIM_W, TRIM_H):
            raise SystemExit(f"{no} back size {back.size}")
        save_web(front, no, "front")
        save_web(back, no, "back")
        print(f"ok {no} {spec[1]}")


if __name__ == "__main__":
    main()
