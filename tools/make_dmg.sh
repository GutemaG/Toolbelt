#!/bin/zsh
# Packs the installed ~/Applications/Toolbelt.app into a disk image for a GitHub release:
# ~/Library/Developer/Toolbelt/release/Toolbelt.dmg, with the app beside an Applications
# shortcut to drag it onto. Run ./build.sh first. Finder opens the image briefly to place
# the icons, and macOS may ask to allow that.
set -euo pipefail
name="Toolbelt"
app="$HOME/Applications/$name.app"
release="$HOME/Library/Developer/$name/release"
volume="/Volumes/$name"

[[ -d "$app" ]] || { echo "no $app: run ./build.sh first"; exit 1; }
[[ ! -e "$volume" ]] || { echo "$volume is already mounted: eject it first"; exit 1; }
codesign --verify "$app"

work=$(mktemp -d)
trap 'hdiutil detach "$volume" -quiet 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir "$work/stage"
ditto "$app" "$work/stage/$name.app"
ln -s /Applications "$work/stage/Applications"

hdiutil create -quiet -volname "$name" -srcfolder "$work/stage" -fs HFS+ -format UDRW "$work/rw.dmg"
hdiutil attach -quiet -noautoopen "$work/rw.dmg"

# Stops after 30 seconds if a permission prompt goes unanswered; the image still works, only unarranged.
perl -e 'alarm 30; exec @ARGV' osascript <<EOF || echo "warning: could not arrange the icons"
tell application "Finder"
  tell disk "$name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 200, 760, 560}
    set arrangement of icon view options of container window to not arranged
    set icon size of icon view options of container window to 112
    set position of item "$name.app" to {150, 160}
    set position of item "Applications" to {410, 160}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

sync
hdiutil detach -quiet "$volume"
mkdir -p "$release"
rm -f "$release/$name.dmg"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$release/$name.dmg"
echo "$release/$name.dmg"
