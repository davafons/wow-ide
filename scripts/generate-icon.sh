#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source_svg="$project_dir/Resources/AppIcon.svg"
preview_png="$project_dir/Resources/AppIcon.png"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wow-ide-icon.XXXXXX")
iconset="$work_dir/AppIcon.iconset"
trap 'rm -rf "$work_dir"' EXIT INT TERM
mkdir -p "$iconset"

if command -v rsvg-convert >/dev/null 2>&1; then
    render() { rsvg-convert -w "$1" -h "$1" "$source_svg" -o "$2"; }
elif command -v magick >/dev/null 2>&1; then
    render() { magick -background none "$source_svg" -resize "$1x$1" "$2"; }
else
    echo "Install librsvg or ImageMagick to regenerate the icon." >&2
    exit 1
fi

render 16 "$iconset/icon_16x16.png"
render 32 "$iconset/icon_16x16@2x.png"
render 32 "$iconset/icon_32x32.png"
render 64 "$iconset/icon_32x32@2x.png"
render 128 "$iconset/icon_128x128.png"
render 256 "$iconset/icon_128x128@2x.png"
render 256 "$iconset/icon_256x256.png"
render 512 "$iconset/icon_256x256@2x.png"
render 512 "$iconset/icon_512x512.png"
render 1024 "$iconset/icon_512x512@2x.png"
render 1024 "$preview_png"

iconutil -c icns "$iconset" -o "$project_dir/Resources/AppIcon.icns"
echo "$project_dir/Resources/AppIcon.icns"
