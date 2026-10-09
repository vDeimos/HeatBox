#!/bin/bash
# make-icon.sh: turn Resources/HeatBox/HeatBox.iconset into Resources/AppIcon.icns.
# The iconset is the approved HeatBox tile at every size; its 1024
# image is Resources/HeatBox/HeatBox_tile_1024.png. Needs only Apple's
# iconutil. The result is committed, so a normal build never runs this; run
# it after changing the artwork.
set -euo pipefail
cd "$(dirname "$0")/.."
iconutil -c icns Resources/HeatBox/HeatBox.iconset -o Resources/HeatBox/HeatBox.icns
cp Resources/HeatBox/HeatBox.icns Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
