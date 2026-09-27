"""Write Finder presentation metadata on the mounted installer volume."""
from pathlib import Path
import sys

from ds_store import DSStore
from mac_alias import Alias

volume = Path(sys.argv[1]).resolve()
with DSStore.open(str(volume / ".DS_Store"), "w+") as store:
    store["."]["bwsp"] = {
        "WindowBounds": "{{180, 160}, {720, 512}}",
        "ShowToolbar": False,
        "ShowSidebar": False,
        "ContainerShowSidebar": False,
        "ShowStatusBar": False,
        "ShowPathbar": False,
        "ShowTabView": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "backgroundImageAlias": Alias.for_file(str(volume / ".background/install.png")).to_bytes(),
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": False,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": 13.0,
        "iconSize": 80.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", b"icnv")
    for name, position in {
        "Dock Preview.app": (180, 190),
        "Applications": (540, 190),
        "Installation Guide - English.txt": (150, 350),
        "安装指南 - 简体中文.txt": (390, 350),
        "License.txt": (590, 350),
    }.items():
        store[name]["Iloc"] = position
