#!/usr/bin/env bash
set -euo pipefail
request="${1:?Story request JSON path is required}"
schema="$(jq -r '.schema // empty' "$request")"
render_id="$(jq -r '.render_id // empty' "$request")"
week_id="$(jq -r '.week_id // empty' "$request")"
content_id="$(jq -r '.content_id // empty' "$request")"
duration="$(jq -r '.seconds_per_frame // 8' "$request")"
cinematic_url="$(jq -r '.cinematic.public_url // empty' "$request")"
allow_static="$(jq -r '.fallback.allow_static_slides // true' "$request")"
music_mode="$(jq -r '.music.mode // "OFF"' "$request" | tr '[:lower:]' '[:upper:]')"
music_mood="$(jq -r '.music.mood // "REFLECTION"' "$request" | tr '[:lower:]' '[:upper:]')"
[[ "$schema" == "isy-story-request-v1" ]] || { echo "Unsupported Story schema: $schema" >&2; exit 1; }
[[ -n "$render_id" && -n "$week_id" && -n "$content_id" ]] || { echo "Story request requires render_id, week_id and content_id." >&2; exit 1; }
[[ "$duration" =~ ^[0-9]+$ ]] && [[ "$duration" -ge 6 && "$duration" -le 10 ]] || { echo "seconds_per_frame must be 6-10." >&2; exit 1; }
[[ "$(jq '.overlay.slides|length' "$request")" -eq 5 ]] || { echo "Story request must contain five native overlay slides." >&2; exit 1; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
out_dir="stories/$week_id/$content_id"; mkdir -p "$out_dir"
font='/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf'
font_bold='/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf'
[[ -f "$font" && -f "$font_bold" ]] || { echo "DejaVu Serif fonts are required." >&2; exit 1; }
color(){ printf '0x%s' "${1#\#}"; }
family="$(jq -r '.overlay.design.family // "QUIET_CENTER"' "$request" | tr '[:lower:]' '[:upper:]')"
position="$(jq -r '.overlay.design.position // "CENTER"' "$request" | tr '[:lower:]' '[:upper:]')"
case "$family" in QUIET_CENTER|LEFT_STORY|LOWER_REFLECTION|FRAMED_THOUGHT|ACCENT_BAND|REVEAL_FOCUS|CLOSING_GLOW) ;; *) family=QUIET_CENTER;; esac
accent="$(color "$(jq -r '.overlay.design.palette.gold // "#D89B2B"' "$request")")"
case "$family" in
  LEFT_STORY) accent="$(color "$(jq -r '.overlay.design.palette.olive // "#556B2F"' "$request")")";;
  LOWER_REFLECTION) accent="$(color "$(jq -r '.overlay.design.palette.rust // "#9A4A18"' "$request")")";;
  FRAMED_THOUGHT) accent="$(color "$(jq -r '.overlay.design.palette.plum // "#55305D"' "$request")")";;
  ACCENT_BAND) accent="$(color "$(jq -r '.overlay.design.palette.teal // "#0C6574"' "$request")")";;
  REVEAL_FOCUS) accent="$(color "$(jq -r '.overlay.design.palette.charcoal // "#171B1D"' "$request")")";;
  CLOSING_GLOW) accent="$(color "$(jq -r '.overlay.design.palette.burgundy // "#8F1F3D"' "$request")")";;
esac
footer="$accent"
light_logo_url="$(jq -r '.overlay.brand.logo_light_url // empty' "$request")"
dark_logo_url="$(jq -r '.overlay.brand.logo_dark_url // empty' "$request")"
tagline="$(jq -r '.overlay.brand.tagline // empty' "$request")"
[[ -n "$tagline" ]] || { echo "I See You Story tagline is required." >&2; exit 1; }
printf '%s\n' "$tagline" > "$work/tagline.txt"
[[ -n "$light_logo_url" && -n "$dark_logo_url" ]] || { echo "Approved I See You light and dark logos are required." >&2; exit 1; }
curl -fsSL --retry 3 "$light_logo_url" -o "$work/logo-light"
curl -fsSL --retry 3 "$dark_logo_url" -o "$work/logo-dark"
ffmpeg -y -loglevel error -i "$work/logo-light" -vf format=rgba -frames:v 1 "$work/logo-light.png"
ffmpeg -y -loglevel error -i "$work/logo-dark" -vf format=rgba -frames:v 1 "$work/logo-dark.png"
cinematic_ok=0
if [[ -n "$cinematic_url" ]]; then
  if curl -fsSL --retry 3 "$cinematic_url" -o "$work/cinematic" && ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$work/cinematic" | grep -q video; then cinematic_ok=1; fi
fi
mapfile -t fallback < <(jq -r '.fallback.static_slides[]?' "$request")
if [[ "$cinematic_ok" -eq 0 && ( "$allow_static" != "true" || ${#fallback[@]} -ne 5 ) ]]; then echo "Cinematic source unavailable and five-frame static fallback is unavailable." >&2; exit 1; fi
wrap_text(){ python3 - "$1" "$2" <<'PY'
import pathlib,re,sys,textwrap
src,dst=map(pathlib.Path,sys.argv[1:3])
t=re.sub(r'\s+',' ',src.read_text(encoding='utf-8')).strip()
width=28 if len(t)<=110 else 24
dst.write_text(textwrap.fill(t,width=width,break_long_words=False,break_on_hyphens=False),encoding='utf-8')
PY
}
mood_freq(){ case "$music_mood" in HEAVINESS) echo 174;; UNCERTAINTY) echo 196;; RELEASE) echo 220;; RENEWAL) echo 247;; HOPE) echo 262;; STILLNESS) echo 174;; OPENNESS) echo 220;; *) echo 196;; esac; }
for i in 1 2 3 4 5; do
  idx=$((i-1)); raw="$work/text-$i.txt"; wrapped="$work/wrapped-$i.txt"
  jq -r ".overlay.slides[$idx].text // empty" "$request" > "$raw"; [[ -s "$raw" ]] || { echo "Story frame $i has no text." >&2; exit 1; }; wrap_text "$raw" "$wrapped"
  text_tone="$(jq -r ".overlay.slides[$idx].text_tone // \"LIGHT\"" "$request" | tr '[:lower:]' '[:upper:]')"
  logo_tone="$(jq -r ".overlay.slides[$idx].logo_tone // \"LIGHT\"" "$request" | tr '[:lower:]' '[:upper:]')"
  [[ "$text_tone" == "DARK" ]] && text_color='0x243C40' || text_color='white'
  [[ "$logo_tone" == "DARK" ]] && logo="$work/logo-dark.png" || logo="$work/logo-light.png"
  base="$work/base-$i.mp4"
  if [[ "$cinematic_ok" -eq 1 ]]; then
    offset=$(((i-1)*duration))
    ffmpeg -y -loglevel error -stream_loop -1 -ss "$offset" -i "$work/cinematic" -t "$duration" -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,fps=30,format=yuv420p" -c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p -an "$base"
  else
    curl -fsSL --retry 3 "${fallback[$idx]}" -o "$work/static-$i"
    ffmpeg -y -loglevel error -loop 1 -i "$work/static-$i" -t "$duration" -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,fps=30,format=yuv420p" -c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p -an "$base"
  fi
  # Story-safe native treatment: keep key text inside 250..1610 px and brand away from app chrome.
  case "$family" in
    LEFT_STORY) panel="drawbox=x=0:y=0:w=760:h=1750:color=0xF7F1E7@0.68:t=fill,drawbox=x=58:y=430:w=7:h=820:color=$accent@0.95:t=fill"; tx=110; ty=580; tw=610;;
    LOWER_REFLECTION) panel="drawbox=x=0:y=0:w=1080:h=1920:color=black@0.26:t=fill,drawbox=x=80:y=1020:w=920:h=520:color=black@0.24:t=fill"; tx=125; ty=1110; tw=830;;
    FRAMED_THOUGHT) panel="drawbox=x=125:y=560:w=830:h=770:color=black@0.30:t=fill,drawbox=x=125:y=560:w=830:h=770:color=$accent@0.9:t=4"; tx=185; ty=730; tw=710;;
    ACCENT_BAND) panel="drawbox=x=0:y=0:w=1080:h=1920:color=black@0.30:t=fill,drawbox=x=0:y=520:w=1080:h=740:color=0x03363D@0.46:t=fill"; tx=130; ty=690; tw=820;;
    REVEAL_FOCUS) panel="drawbox=x=0:y=0:w=1080:h=1920:color=black@0.38:t=fill,drawbox=x=100:y=570:w=770:h=760:color=black@0.18:t=fill"; tx=150; ty=730; tw=680;;
    CLOSING_GLOW) panel="drawbox=x=0:y=0:w=1080:h=1920:color=black@0.46:t=fill,drawbox=x=150:y=640:w=780:h=620:color=0x8F1F3D@0.17:t=fill"; tx=190; ty=790; tw=700;;
    *) panel="drawbox=x=0:y=0:w=1080:h=1920:color=black@0.48:t=fill"; tx=155; ty=720; tw=770;;
  esac
  [[ "$position" == "RIGHT" && "$family" == "LEFT_STORY" ]] && { panel="drawbox=x=320:y=0:w=760:h=1750:color=0xF7F1E7@0.68:t=fill,drawbox=x=1015:y=430:w=7:h=820:color=$accent@0.95:t=fill"; tx=360; }
  frame="$work/frame-$i-silent.mp4"
  ffmpeg -y -loglevel error -i "$base" -i "$logo" -filter_complex "[0:v]$panel,drawbox=x=0:y=1532:w=1080:h=78:color=$footer@0.96:t=fill,drawtext=fontfile=$font:textfile='$work/tagline.txt':fontcolor=white:fontsize=34:x=(w-text_w)/2:y=1553,drawtext=fontfile=$font_bold:textfile='$wrapped':fontcolor=$text_color:fontsize=52:line_spacing=17:x=$tx:y=$ty:box=0[v0];[1:v]scale=220:-1[lg];[v0][lg]overlay=70:290,format=yuv420p[v]" -map '[v]' -t "$duration" -r 30 -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$frame"
  out="$out_dir/frame-$i.mp4"
  if [[ "$music_mode" == "SOFT" ]]; then
    freq="$(mood_freq)"
    ffmpeg -y -loglevel error -i "$frame" -f lavfi -i "sine=frequency=$freq:sample_rate=44100:duration=$duration" -filter_complex "[1:a]volume=-30dB,lowpass=f=900,afade=t=in:st=0:d=0.8,afade=t=out:st=$(awk -v d="$duration" 'BEGIN{printf "%.1f",d-0.8}'):d=0.8[a]" -map 0:v -map '[a]' -c:v copy -c:a aac -b:a 96k -shortest -movflags +faststart "$out"
  else cp "$frame" "$out"; fi
done
cat > "$out_dir/render-status.json" <<JSON
{"schema":"isy-story-render-status-v1","render_id":"$render_id","status":"READY","frames":5,"audio":$([[ "$music_mode" == "SOFT" ]] && echo true || echo false),"layout":"NATIVE_STORY_DESIGN_V1"}
JSON
