#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
design_dir="$repo_root/Design"
icon_dir="$repo_root/PilgrimJournal/PilgrimJournal/Assets.xcassets/AppIcon.appiconset"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

render_svg() {
  source_file=$1
  output_file=$2
  qlmanage -t -s 1024 -o "$work_dir" "$source_file" >/dev/null 2>&1
  rendered="$work_dir/$(basename "$source_file").png"
  opaque="$work_dir/$(basename "$source_file").jpg"
  sips -s format jpeg -s formatOptions 100 "$rendered" \
    --out "$opaque" >/dev/null
  sips -s format png "$opaque" --out "$output_file" >/dev/null
  rm -f "$rendered"
}

render_svg "$design_dir/AppIcon.svg" "$icon_dir/AppIcon-iOS.png"
render_svg "$design_dir/AppIcon-dark.svg" "$icon_dir/AppIcon-iOS-dark.png"
render_svg "$design_dir/AppIcon-tinted.svg" "$icon_dir/AppIcon-iOS-tinted.png"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_dir/AppIcon-iOS.png" \
    --out "$icon_dir/AppIcon-mac-$size.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$icon_dir/AppIcon-iOS.png" \
    --out "$icon_dir/AppIcon-mac-$size@2x.png" >/dev/null
done

echo "Generated Pilgrim Journal app icon assets."
