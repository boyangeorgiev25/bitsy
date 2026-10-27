# dmgbuild settings for the Bitsy installer window. Used by release.sh:
#   dmgbuild -s dmg/settings.py -D app=build/Bitsy.app -D background=... -D volicon=... "Bitsy" dist/Bitsy.dmg
import os.path

app = defines.get("app", "build/Bitsy.app")  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("volicon")  # noqa: F821
background = defines.get("background")  # noqa: F821

# 640×420 window matching the background; Bitsy on the left, Applications on the right of the arrow
window_rect = ((200, 140), (640, 448))  # 420 of content plus the title bar
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {appname: (170, 215), "Applications": (470, 215)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
