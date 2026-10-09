# dmgbuild layout for the My Notch installer window.
# Run via release.sh:  dmgbuild -s dmg/settings.py -D app=<path to MyNotch.app> "My Notch" out.dmg
import os.path

app = defines.get("app", "MyNotch.app")
appname = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

# Window: the background is 660x400 pt; Finder adds its title bar on top.
background = os.path.join(os.path.dirname(os.path.abspath(defines.get("settings_dir", "dmg/x"))), "background.tiff") \
    if "settings_dir" in defines else "dmg/background.tiff"
window_rect = ((240, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
# Centres of the two cards drawn in the background (see make_background.swift).
icon_locations = {appname: (180, 232), "Applications": (480, 232)}
