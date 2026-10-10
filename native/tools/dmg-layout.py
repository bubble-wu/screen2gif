#!/usr/bin/env python3
"""Write this installer's small Finder .DS_Store without UI automation.

The single-leaf Bud1/DSDB format and Finder keys follow the documented
implementations at https://github.com/dmgbuild/ds_store and
https://github.com/dmgbuild/dmgbuild. No external Python packages are needed.
"""

import ctypes
import os
import pathlib
import plistlib
import struct
import sys


def background_alias(path):
    # Finder's icvp key still expects an Alias Manager record, rather than a
    # modern URL bookmark. Generate it with the system API on the mounted HFS+
    # volume, so it contains the correct volume identity and relative path.
    carbon = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")
    carbon.FSNewAliasFromPath.argtypes = [
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_ubyte),
    ]
    carbon.FSNewAliasFromPath.restype = ctypes.c_int32
    carbon.GetAliasSize.argtypes = [ctypes.c_void_p]
    carbon.GetAliasSize.restype = ctypes.c_int32
    carbon.DisposeHandle.argtypes = [ctypes.c_void_p]
    carbon.DisposeHandle.restype = None
    handle = ctypes.c_void_p()
    status = carbon.FSNewAliasFromPath(None, os.fsencode(path), 0, ctypes.byref(handle), None)
    if status != 0:
        raise OSError(f"Cannot create Finder background alias: OSStatus {status}")
    try:
        size = carbon.GetAliasSize(handle)
        if not 0 < size < 65536:
            raise ValueError(f"Unexpected alias size: {size}")
        address = ctypes.cast(handle, ctypes.POINTER(ctypes.c_void_p)).contents.value
        return ctypes.string_at(address, size)
    finally:
        carbon.DisposeHandle(handle)


def record(name, key, kind, value):
    filename = name.encode("utf-16be")
    header = struct.pack(">I", len(filename) // 2) + filename + key.encode("ascii") + kind.encode("ascii")
    if kind == "blob":
        value = struct.pack(">I", len(value)) + value
    elif kind == "long":
        value = struct.pack(">I", value)
    elif kind != "type":
        raise ValueError(f"Unsupported Finder record kind: {kind}")
    return header + value


def write_layout(volume):
    view = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": background_alias(volume / ".background/installer.png"),
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
        "arrangeBy": "none", "showIconPreview": True, "showItemInfo": False,
        "labelOnBottom": True, "textSize": 13.0, "iconSize": 96.0,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    }
    window = {
        "WindowBounds": "{{160, 160}, {640, 420}}",
        "ContainerShowSidebar": False, "PreviewPaneVisibility": False,
        "SidebarWidth": 0, "ShowTabView": False, "ShowToolbar": False,
        "ShowStatusBar": False, "ShowPathbar": False, "ShowSidebar": False,
    }
    entries = [
        (".", "bwsp", "blob", plistlib.dumps(window, fmt=plistlib.FMT_BINARY)),
        (".", "icvl", "type", b"icnv"),
        (".", "icvp", "blob", plistlib.dumps(view, fmt=plistlib.FMT_BINARY)),
        (".", "vSrn", "long", 1),
        ("Applications", "Iloc", "blob", struct.pack(">4I", 460, 205, 0xFFFFFFFF, 0xFFFF0000)),
        ("screen2gif.app", "Iloc", "blob", struct.pack(">4I", 180, 205, 0xFFFFFFFF, 0xFFFF0000)),
    ]
    entries.sort(key=lambda entry: (entry[0].lower(), entry[1]))
    leaf = struct.pack(">2I", 0, len(entries)) + b"".join(record(*entry) for entry in entries)
    if len(leaf) > 4096:
        raise ValueError("Installer layout no longer fits the single-leaf store")

    # Three buddy blocks: allocator at 2048 (2 KiB), DSDB at 32 (32 B),
    # and the sole B-tree leaf at 4096 (4 KiB). Addresses are file offset - 4.
    addresses = [2048 | 11, 32 | 5, 4096 | 12] + [0] * 253
    allocator = struct.pack(">2I", 3, 0) + struct.pack(">256I", *addresses)
    allocator += struct.pack(">I", 1) + b"\x04DSDB" + struct.pack(">I", 1)
    for width in range(32):
        free = (1 << width) if width in range(6, 11) or width in range(13, 31) else None
        allocator += struct.pack(">2I", 1, free) if free is not None else struct.pack(">I", 0)
    if len(allocator) > 2048:
        raise ValueError("Installer layout allocator overflow")
    data = bytearray(8196)
    data[:36] = struct.pack(">I4sIII16s", 1, b"Bud1", 2048, 2048, 2048,
                            bytes.fromhex("0000100c000000870000200b00000000"))
    # Finder counts edges above the leaf, so a single-leaf tree has level 0.
    data[36:56] = struct.pack(">5I", 2, 0, len(entries), 1, 4096)
    data[2052:2052 + len(allocator)] = allocator
    data[4100:4100 + len(leaf)] = leaf
    (volume / ".DS_Store").write_bytes(data)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: dmg-layout.py <mounted-volume>")
    volume = pathlib.Path(sys.argv[1]).resolve()
    if not (volume / "screen2gif.app").is_dir() or not (volume / "Applications").is_symlink():
        raise SystemExit("Not a screen2gif installer volume")
    write_layout(volume)
