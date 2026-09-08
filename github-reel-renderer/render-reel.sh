#!/usr/bin/env bash
set -euo pipefail

request="${1:?Request JSON path is required}"
week_id="$(jq -r '.week_id' "$request")"
content_id="$(jq -r '.content_id' "$request")"
duration="$(jq -r '.seconds_per_slide // 3' "$request")"
mapfile -t slides < <(jq -r '.slides[]' "$request")

if [ -z "$week_id" ] || [ "$week_id" = null ] || [ -z "$content_id" ] || [ "$content_id" = null ]; then
  echo "Request is missing week_id or content_id." >&2
  exit 1
fi
if [ "${#slides[@]}" -ne 5 ]; then
  echo "Exactly five public slide URLs are required." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "reels/$week_id/$content_id"

for i in "${!slides[@]}"; do
  n=$((i + 1))
  curl --fail --location --silent --show-error "${slides[$i]}" -o "$work/slide-$n.png"
  ffmpeg -hide_banner -loglevel error -y -loop 1 -t "$duration" -i "$work/slide-$n.png" \
    -filter_complex "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=24:12[bg];[0:v]scale=1080:1350:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p" \
    -r 30 -c:v libx264 -preset medium -crf 20 -movflags +faststart "$work/part-$n.mp4"
  printf "file '%s'\n" "$work/part-$n.mp4" >> "$work/parts.txt"
done

ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$work/parts.txt" \
  -c:v libx264 -pix_fmt yuv420p -r 30 -movflags +faststart \
  "reels/$week_id/$content_id/reel.mp4"

ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
  -of csv=s=x:p=0 "reels/$week_id/$content_id/reel.mp4" | grep -qx '1080x1920'
