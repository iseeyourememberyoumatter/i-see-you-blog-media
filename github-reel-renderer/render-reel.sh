#!/usr/bin/env bash
set -euo pipefail
request="${1:?Request JSON path is required}"
week_id="$(jq -r '.week_id' "$request")"
content_id="$(jq -r '.content_id' "$request")"
duration="$(jq -r '.seconds_per_slide // 3' "$request")"
allow_static_slides="$(jq -r '.fallback.allow_static_slides // true' "$request")"
cinematic_url="$(jq -r '.cinematic.public_url // empty' "$request")"
mapfile -t slides < <(jq -r '.slides[]' "$request")
if [[ -z "$week_id" || -z "$content_id" || ${#slides[@]} -ne 5 ]]; then
  echo "Invalid Reel request: week/content and exactly five slides are required." >&2
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out="reels/$week_id/$content_id/reel.mp4"
mkdir -p "$(dirname "$out")"

download_slide(){ local url="$1" target="$2"; curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$target"; }
render_static_part(){ local slide="$1" part="$2"; ffmpeg -y -loglevel error -loop 1 -i "$slide" -t "$duration" -vf "split=2[bg][fg];[bg]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,gblur=sigma=24[bg2];[fg]scale=1080:1350:force_original_aspect_ratio=decrease[fg2];[bg2][fg2]overlay=(W-w)/2:(H-h)/2,format=yuv420p" -r 30 -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$part"; }

cinematic_ok=0
total_seconds=$(( duration * 5 ))
if [[ -n "$cinematic_url" ]]; then
  if curl -fsSL --retry 2 --retry-delay 2 "$cinematic_url" -o "$work/cinematic_source" && ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$work/cinematic_source" | grep -q video; then
    if ffmpeg -y -loglevel error -stream_loop -1 -i "$work/cinematic_source" -t "$total_seconds" -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,fps=30,format=yuv420p" -c:v libx264 -preset medium -crf 21 -pix_fmt yuv420p -movflags +faststart -an "$work/cinematic_bg.mp4"; then cinematic_ok=1; fi
  fi
fi

: > "$work/concat.txt"
for i in "${!slides[@]}"; do
  slide="$work/slide_$((i+1)).png"
  part="$work/part_$((i+1)).mp4"
  download_slide "${slides[$i]}" "$slide"
  if [[ "$cinematic_ok" -eq 1 ]]; then
    offset=$(( i * duration ))
    if ! ffmpeg -y -loglevel error -ss "$offset" -i "$work/cinematic_bg.mp4" -loop 1 -i "$slide" -t "$duration" -filter_complex "[0:v]drawbox=x=70:y=377:w=940:h=1166:color=black@0.18:t=fill[bg];[1:v]scale=900:1125:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p" -r 30 -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$part"; then
      cinematic_ok=0
      render_static_part "$slide" "$part"
    fi
  else
    if [[ "$allow_static_slides" != "true" ]]; then echo "Cinematic clip unavailable and static fallback is disabled." >&2; exit 1; fi
    render_static_part "$slide" "$part"
  fi
  printf "file '%s'\n" "$part" >> "$work/concat.txt"
done
ffmpeg -y -loglevel error -f concat -safe 0 -i "$work/concat.txt" -c copy -movflags +faststart "$out"
resolution="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$out")"
if [[ "$resolution" != "1080x1920" ]]; then echo "Unexpected Reel resolution: $resolution" >&2; exit 1; fi
printf 'Rendered %s (%s) cinematic=%s\n' "$out" "$resolution" "$cinematic_ok"
