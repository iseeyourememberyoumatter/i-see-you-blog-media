#!/usr/bin/env bash
set -euo pipefail

request="${1:?Request JSON path is required}"
schema="$(jq -r '.schema // "isy-reel-request-v1"' "$request")"
week_id="$(jq -r '.week_id // empty' "$request")"
content_id="$(jq -r '.content_id // empty' "$request")"
duration="$(jq -r '.seconds_per_slide // 3' "$request")"
allow_static_slides="$(jq -r '.fallback.allow_static_slides // true' "$request")"
cinematic_url="$(jq -r '.cinematic.public_url // empty' "$request")"

if [[ -z "$week_id" || -z "$content_id" ]]; then
  echo "Invalid Reel request: week_id and content_id are required." >&2
  exit 1
fi
if ! [[ "$duration" =~ ^[0-9]+$ ]] || [[ "$duration" -lt 1 ]] || [[ "$duration" -gt 10 ]]; then
  echo "Invalid Reel request: seconds_per_slide must be an integer from 1 to 10." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out="reels/$week_id/$content_id/reel.mp4"
mkdir -p "$(dirname "$out")"

download_slide(){
  local url="$1" target="$2"
  curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$target"
}

render_static_part(){
  local slide="$1" part="$2"
  ffmpeg -y -loglevel error -loop 1 -i "$slide" -t "$duration" \
    -vf "split=2[bg][fg];[bg]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,gblur=sigma=24[bg2];[fg]scale=1080:1350:force_original_aspect_ratio=decrease[fg2];[bg2][fg2]overlay=(W-w)/2:(H-h)/2,format=yuv420p" \
    -r 30 -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$part"
}

render_all_static(){
  local -n static_urls_ref=$1
  : > "$work/concat.txt"
  for i in "${!static_urls_ref[@]}"; do
    local slide="$work/static_slide_$((i+1)).png"
    local part="$work/static_part_$((i+1)).mp4"
    download_slide "${static_urls_ref[$i]}" "$slide"
    render_static_part "$slide" "$part"
    printf "file '%s'\n" "$part" >> "$work/concat.txt"
  done
}

normalize_cinematic(){
  local total_seconds="$1"
  [[ -n "$cinematic_url" ]] || return 1
  curl -fsSL --retry 2 --retry-delay 2 "$cinematic_url" -o "$work/cinematic_source" || return 1
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$work/cinematic_source" | grep -q video || return 1
  ffmpeg -y -loglevel error -stream_loop -1 -i "$work/cinematic_source" -t "$total_seconds" \
    -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,fps=30,format=yuv420p" \
    -c:v libx264 -preset medium -crf 21 -pix_fmt yuv420p -movflags +faststart -an "$work/cinematic_bg.mp4"
}

# Legacy v1/v2 rendering is intentionally preserved for historical requests and manual dispatches.
render_legacy(){
  mapfile -t slides < <(jq -r '.slides[]?' "$request")
  if [[ ${#slides[@]} -ne 5 ]]; then
    echo "Invalid legacy Reel request: exactly five slides are required." >&2
    exit 1
  fi
  local cinematic_ok=0
  local total_seconds=$(( duration * 5 ))
  if normalize_cinematic "$total_seconds"; then cinematic_ok=1; fi
  : > "$work/concat.txt"
  for i in "${!slides[@]}"; do
    local slide="$work/legacy_slide_$((i+1)).png"
    local part="$work/legacy_part_$((i+1)).mp4"
    download_slide "${slides[$i]}" "$slide"
    if [[ "$cinematic_ok" -eq 1 ]]; then
      local offset=$(( i * duration ))
      if ! ffmpeg -y -loglevel error -ss "$offset" -i "$work/cinematic_bg.mp4" -loop 1 -i "$slide" -t "$duration" \
        -filter_complex "[0:v]drawbox=x=70:y=377:w=940:h=1166:color=black@0.18:t=fill[bg];[1:v]scale=900:1125:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p" \
        -r 30 -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$part"; then
        cinematic_ok=0
        render_static_part "$slide" "$part"
      fi
    else
      if [[ "$allow_static_slides" != "true" ]]; then
        echo "Cinematic clip unavailable and static fallback is disabled." >&2
        exit 1
      fi
      render_static_part "$slide" "$part"
    fi
    printf "file '%s'\n" "$part" >> "$work/concat.txt"
  done
  echo "$cinematic_ok"
}

wrap_text_file(){
  local source="$1" target="$2"
  python3 - "$source" "$target" <<'PY'
import pathlib, re, sys, textwrap
src, dst = map(pathlib.Path, sys.argv[1:3])
text = re.sub(r"\s+", " ", src.read_text(encoding="utf-8")).strip()
width = 29 if len(text) <= 115 else 25
wrapped = textwrap.fill(text, width=width, break_long_words=False, break_on_hyphens=False)
dst.write_text(wrapped, encoding="utf-8")
PY
}

render_v3_native(){
  local overlay_count
  overlay_count="$(jq -r '.overlay.slides | length' "$request" 2>/dev/null || echo 0)"
  if [[ "$overlay_count" != "5" ]]; then
    echo "Invalid v3 Reel request: overlay.slides must contain exactly five story beats." >&2
    exit 1
  fi

  mapfile -t static_slides < <(jq -r '.fallback.static_slides[]? // empty' "$request")
  if [[ "$allow_static_slides" == "true" && ${#static_slides[@]} -ne 5 ]]; then
    echo "Invalid v3 Reel request: static fallback requires exactly five static_slides." >&2
    exit 1
  fi

  local total_seconds=$(( duration * 5 ))
  if ! normalize_cinematic "$total_seconds"; then
    if [[ "$allow_static_slides" != "true" ]]; then
      echo "Cinematic clip unavailable and static fallback is disabled." >&2
      exit 1
    fi
    render_all_static static_slides
    echo "0"
    return 0
  fi

  local font_regular font_bold
  font_regular="$(fc-match -f '%{file}\n' 'DejaVu Sans' | head -1)"
  font_bold="$(fc-match -f '%{file}\n' 'DejaVu Sans:style=Bold' | head -1)"
  [[ -f "$font_regular" ]] || { echo "A usable sans-serif font was not found." >&2; return 1; }
  [[ -f "$font_bold" ]] || font_bold="$font_regular"

  local brand_name brand_tagline
  brand_name="$(jq -r '.overlay.brand.name // "I See You"' "$request")"
  brand_tagline="$(jq -r '.overlay.brand.tagline // "Remember You Matter"' "$request")"
  printf '%s' "$brand_name" > "$work/brand.txt"
  printf '%s' "$brand_tagline" > "$work/tagline.txt"

  : > "$work/native_concat.txt"
  local native_ok=1
  for i in 0 1 2 3 4; do
    local raw="$work/raw_$((i+1)).txt"
    local text="$work/text_$((i+1)).txt"
    local part="$work/native_part_$((i+1)).mp4"
    jq -r ".overlay.slides[$i].text // empty" "$request" > "$raw"
    if [[ ! -s "$raw" ]]; then native_ok=0; break; fi
    wrap_text_file "$raw" "$text"
    local chars fontsize offset
    chars="$(wc -m < "$raw" | tr -d ' ')"
    if [[ "$chars" -le 70 ]]; then fontsize=68; elif [[ "$chars" -le 120 ]]; then fontsize=60; else fontsize=52; fi
    offset=$(( i * duration ))

    # Full-screen motion remains the visual. The film is full-width and low-opacity;
    # there is no inset card and no finished slide image in the cinematic path.
    if ! ffmpeg -y -loglevel error -ss "$offset" -i "$work/cinematic_bg.mp4" -t "$duration" \
      -vf "drawbox=x=0:y=500:w=1080:h=850:color=black@0.16:t=fill,drawtext=fontfile='$font_bold':textfile='$work/brand.txt':fontcolor=white@0.94:fontsize=42:x=(w-text_w)/2:y=150:shadowcolor=black@0.65:shadowx=2:shadowy=2,drawtext=fontfile='$font_regular':textfile='$text':fontcolor=white:fontsize=$fontsize:line_spacing=20:x=(w-text_w)/2:y=(h-text_h)/2-10:shadowcolor=black@0.78:shadowx=3:shadowy=3,drawbox=x=390:y=1510:w=300:h=3:color=white@0.62:t=fill,drawtext=fontfile='$font_regular':textfile='$work/tagline.txt':fontcolor=white@0.90:fontsize=30:x=(w-text_w)/2:y=1550:shadowcolor=black@0.65:shadowx=2:shadowy=2,format=yuv420p" \
      -r 30 -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$part"; then
      native_ok=0
      break
    fi
    printf "file '%s'\n" "$part" >> "$work/native_concat.txt"
  done

  if [[ "$native_ok" -eq 1 ]]; then
    mv "$work/native_concat.txt" "$work/concat.txt"
    echo "1"
    return 0
  fi

  if [[ "$allow_static_slides" != "true" ]]; then
    echo "Native cinematic overlay failed and static fallback is disabled." >&2
    exit 1
  fi
  render_all_static static_slides
  echo "0"
}

cinematic_ok=0
case "$schema" in
  isy-reel-request-v3)
    cinematic_ok="$(render_v3_native)"
    ;;
  isy-reel-request-v1|isy-reel-request-v2)
    cinematic_ok="$(render_legacy)"
    ;;
  *)
    echo "Unsupported Reel request schema: $schema" >&2
    exit 1
    ;;
esac

ffmpeg -y -loglevel error -f concat -safe 0 -i "$work/concat.txt" -c copy -movflags +faststart "$out"
resolution="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$out")"
if [[ "$resolution" != "1080x1920" ]]; then
  echo "Unexpected Reel resolution: $resolution" >&2
  exit 1
fi
printf 'Rendered %s (%s) schema=%s cinematic=%s\n' "$out" "$resolution" "$schema" "$cinematic_ok"
