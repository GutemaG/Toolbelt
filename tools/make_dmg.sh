#!/bin/zsh
# Packs the installed ~/Applications/Toolbelt.app for a GitHub release. Writes two files to
# ~/Library/Developer/Toolbelt/release, and both go on the release:
#   Toolbelt.dmg   the app beside an Applications shortcut to drag it onto
#   appcast.xml    tells installed copies about this version, signed for Sparkle
# Usage: tools/make_dmg.sh "What's new in this version"
# Run ./build.sh first. Finder opens the image briefly to place the icons, and macOS may
# ask to allow that.
set -euo pipefail
name="Toolbelt"
app="$HOME/Applications/$name.app"
release="$HOME/Library/Developer/$name/release"
volume="/Volumes/$name"

notes="${1:-}"
[[ -n "$notes" ]] || { echo "usage: tools/make_dmg.sh \"What's new in this version\""; exit 1; }
sign_update="$HOME/Library/Developer/$name/build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$sign_update" ]] || { echo "no sign_update: run ./build.sh first"; exit 1; }
[[ -d "$app" ]] || { echo "no $app: run ./build.sh first"; exit 1; }
[[ ! -e "$volume" ]] || { echo "$volume is already mounted: eject it first"; exit 1; }
codesign --verify --deep --strict "$app"
# Permissions survive an update only while this certificate signs every release.
requirement='identifier "com.birhanu.toolbelt" and certificate leaf = H"cd166fb0bdac8fbd868d4deff2a353222ab0f4cd"'
[[ "$(codesign -d -r- "$app" 2>&1)" == *"$requirement"* ]] || { echo "refusing to package: $app isn't signed with the Toolbelt Code Signing certificate (see Releases in CLAUDE.md)"; exit 1; }

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

# Each version's download stays at its own tag, so older copies can always reach it.
info="$app/Contents/Info.plist"
short=$(plutil -extract CFBundleShortVersionString raw "$info")
build=$(plutil -extract CFBundleVersion raw "$info")
minimum=$(plutil -extract LSMinimumSystemVersion raw "$info")
signature=$("$sign_update" "$release/$name.dmg")
cat > "$release/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$name</title>
    <item>
      <title>$name $short</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$short</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>$notes</p>]]></description>
      <enclosure url="https://github.com/GutemaG/$name/releases/download/v$short/$name.dmg" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$release/appcast.xml"
echo "$release/$name.dmg"
echo "$release/appcast.xml"
