# dmgbuild's settings for Side's DMG (scripts/release.sh). The window shows background.tiff
# (scripts/dmg/background.html) with Side on the left and Applications on the right, where the
# artwork's track runs between them and its label pills sit under them.
import os

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]
background = defines["background"]

# 640 x 400 of content, plus the title bar.
window_rect = ((200, 160), (640, 432))
default_view = "icon-view"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
hide_extensions = [os.path.basename(app)]
icon_locations = {os.path.basename(app): (170, 190), "Applications": (470, 190)}
