#!/bin/zsh
# Removes Gatekeeper quarantine metadata from the installed Kelvin bundle.
# Run after copying Kelvin.app to /Applications.
set -euo pipefail

APP="/Applications/Kelvin.app"

pause() {
    print ""
    read -r "reply?Press Return to close… " || true
}

if [[ ! -d "$APP" ]]; then
    print "Kelvin is not installed in /Applications."
    print "First drag Kelvin.app to the Applications folder, then run this script again."
    pause
    exit 1
fi

print "Removing quarantine metadata from $APP…"
if ! /usr/bin/xattr -cr "$APP"; then
    print "Administrator access is required for this copy."
    /usr/bin/sudo /usr/bin/xattr -cr "$APP"
fi

if ! /usr/bin/codesign --verify --deep --strict "$APP"; then
    print "The Kelvin application bundle is damaged or incomplete."
    print "Download the DMG again and reinstall it."
    pause
    exit 1
fi

print "Done. Opening Kelvin…"
/usr/bin/open "$APP"
pause
