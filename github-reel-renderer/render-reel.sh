#!/usr/bin/env bash
set -euo pipefail

request="${1:?Request JSON path is required}"
schema="$(jq -r '.schema // "isy-reel-request-v1"' "$request")"
render_id="$(jq -r '.render_id // empty' "$request")"
week_id="$(jq -r '.week_id // empty' "$request")"
content_id="$(jq -r '.content_id // empty' "$request")"
duration="$(jq -r '.seconds_per_slide // 3' "$request")"
allow_static_slides="$(jq -r '.fallback.allow_static_slides // true' "$request")"
cinematic_url="$(jq -r '.cinematic.public_url // empty' "$request")"
music_mode="$(jq -r '.music.mode // "OFF"' "$request" | tr '[:lower:]' '[:upper:]')"
music_mood="$(jq -r '.music.mood // "REFLECTION"' "$request" | tr '[:lower:]' '[:upper:]')"
music_source="$(jq -r '.music.source // empty' "$request")"

if [[ -z "$week_id" || -z "$content_id" ]]; then echo "Invalid Reel request: week_id and content_id are required." >&2; exit 1; fi
if [[ "$schema" == "isy-reel-request-v3" && -z "$render_id" ]]; then echo "Invalid v3 Reel request: render_id is required." >&2; exit 1; fi
if ! [[ "$duration" =~ ^[0-9]+$ ]] || [[ "$duration" -lt 1 ]] || [[ "$duration" -gt 10 ]]; then echo "Invalid Reel request: seconds_per_slide must be an integer from 1 to 10." >&2; exit 1; fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
out_dir="reels/$week_id/$content_id"; out="$out_dir/reel.mp4"; status_out="$out_dir/render-status.json"
mkdir -p "$out_dir"

download_slide(){ local url="$1" target="$2"; curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$target"; }
render_static_part(){ local slide="$1" part="$2"; ffmpeg -y -loglevel error -loop 1 -i "$slide" -t "$duration" -vf "split=2[bg][fg];[bg]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,gblur=sigma=24[bg2];[fg]scale=1080:1350:force_original_aspect_ratio=decrease[fg2];[bg2][fg2]overlay=(W-w)/2:(H-h)/2,format=yuv420p" -r 30 -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$part"; }
render_all_static(){ local -n a=$1; : > "$work/concat.txt"; for i in "${!a[@]}"; do local slide="$work/static_$i.png" part="$work/static_$i.mp4"; download_slide "${a[$i]}" "$slide"; render_static_part "$slide" "$part"; printf "file '%s'\n" "$part" >> "$work/concat.txt"; done; }
normalize_cinematic(){ local total="$1"; [[ -n "$cinematic_url" ]] || return 1; curl -fsSL --retry 2 --retry-delay 2 "$cinematic_url" -o "$work/cinematic_source" || return 1; ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$work/cinematic_source" | grep -q video || return 1; ffmpeg -y -loglevel error -stream_loop -1 -i "$work/cinematic_source" -t "$total" -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,fps=30,format=yuv420p" -c:v libx264 -preset medium -crf 21 -pix_fmt yuv420p -movflags +faststart -an "$work/cinematic_bg.mp4"; }
render_legacy(){ mapfile -t slides < <(jq -r '.slides[]?' "$request"); [[ ${#slides[@]} -eq 5 ]] || { echo "Invalid legacy Reel request: exactly five slides are required." >&2; exit 1; }; local cinematic_ok=0 total=$((duration*5)); if normalize_cinematic "$total"; then cinematic_ok=1; fi; : > "$work/concat.txt"; for i in "${!slides[@]}"; do local slide="$work/legacy_$i.png" part="$work/legacy_$i.mp4"; download_slide "${slides[$i]}" "$slide"; if [[ "$cinematic_ok" -eq 1 ]]; then local offset=$((i*duration)); if ! ffmpeg -y -loglevel error -ss "$offset" -i "$work/cinematic_bg.mp4" -loop 1 -i "$slide" -t "$duration" -filter_complex "[0:v]drawbox=x=70:y=377:w=940:h=1166:color=black@0.18:t=fill[bg];[1:v]scale=900:1125:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p" -r 30 -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$part"; then cinematic_ok=0; render_static_part "$slide" "$part"; fi; else [[ "$allow_static_slides" == "true" ]] || { echo "Cinematic clip unavailable and static fallback is disabled." >&2; exit 1; }; render_static_part "$slide" "$part"; fi; printf "file '%s'\n" "$part" >> "$work/concat.txt"; done; echo "$cinematic_ok"; }
wrap_text_file(){ local source="$1" target="$2"; python3 - "$source" "$target" <<'PY2'
import pathlib,re,sys,textwrap
src,dst=map(pathlib.Path,sys.argv[1:3]); text=re.sub(r"\s+"," ",src.read_text(encoding="utf-8")).strip(); width=29 if len(text)<=115 else 25; dst.write_text(textwrap.fill(text,width=width,break_long_words=False,break_on_hyphens=False),encoding="utf-8")
PY2
}
color_arg(){ local v="${1#\#}"; printf '0x%s' "$v"; }
alpha_for_support(){ case "${1^^}" in STRONG) echo '0.34';; SOFT) echo '0.20';; *) echo '0';; esac; }
alpha_for_film(){ case "${1^^}" in HIGH) echo '0.34';; MEDIUM) echo '0.23';; LOW) echo '0.13';; *) echo '0';; esac; }
reel_design_values(){
  design_family="$(jq -r '.overlay.design.family // "QUIET_CENTER"' "$request" | tr '[:lower:]' '[:upper:]')"
  design_position="$(jq -r '.overlay.design.position // "CENTER"' "$request" | tr '[:lower:]' '[:upper:]')"
  case "$design_family" in QUIET_CENTER|LEFT_STORY|LOWER_REFLECTION|FRAMED_THOUGHT|ACCENT_BAND|REVEAL_FOCUS|CLOSING_GLOW) ;; *) echo "Unsupported native Reel design family: $design_family" >&2; return 1;; esac
  case "$design_position" in LEFT|RIGHT|CENTER) ;; *) design_position=CENTER;; esac
  c_ivory="$(color_arg "$(jq -r '.overlay.design.palette.warm_ivory // "#F7F1E7"' "$request")")"
  c_white="$(color_arg "$(jq -r '.overlay.design.palette.white // "#FFFFFF"' "$request")")"
  c_dark="$(color_arg "$(jq -r '.overlay.design.palette.dark_text // "#243C40"' "$request")")"
  c_gold="$(color_arg "$(jq -r '.overlay.design.palette.gold // "#D89B2B"' "$request")")"
  c_olive="$(color_arg "$(jq -r '.overlay.design.palette.olive // "#556B2F"' "$request")")"
  c_rust="$(color_arg "$(jq -r '.overlay.design.palette.rust // "#9A4A18"' "$request")")"
  c_plum="$(color_arg "$(jq -r '.overlay.design.palette.plum // "#55305D"' "$request")")"
  c_teal="$(color_arg "$(jq -r '.overlay.design.palette.teal // "#0C6574"' "$request")")"
  c_char="$(color_arg "$(jq -r '.overlay.design.palette.charcoal // "#171B1D"' "$request")")"
  c_burg="$(color_arg "$(jq -r '.overlay.design.palette.burgundy // "#8F1F3D"' "$request")")"
  c_warm="$(color_arg "$(jq -r '.overlay.design.palette.warm_accent // "#D88945"' "$request")")"
  film_tone="$(jq -r '.overlay.design.background_profile.filmTone // ""' "$request" | tr '[:lower:]' '[:upper:]')"
  film_strength="$(jq -r '.overlay.design.background_profile.filmStrength // ""' "$request" | tr '[:lower:]' '[:upper:]')"
  text_support="$(jq -r '.overlay.design.background_profile.textZoneSupport // ""' "$request" | tr '[:lower:]' '[:upper:]')"
  logo_support="$(jq -r '.overlay.design.background_profile.logoZoneSupport // ""' "$request" | tr '[:lower:]' '[:upper:]')"
  preferred_text="$(jq -r '.overlay.design.background_profile.preferredTextTone // ""' "$request" | tr '[:lower:]' '[:upper:]')"
}
family_accent(){ case "$design_family" in LEFT_STORY) echo "$c_olive";; FRAMED_THOUGHT) echo "$c_plum";; CLOSING_GLOW) echo "$c_burg";; *) echo "$c_gold";; esac; }
footer_color(){ case "$design_family" in QUIET_CENTER) echo "$(color_arg '#03363D')";; LEFT_STORY) echo "$c_olive";; LOWER_REFLECTION) echo "$c_rust";; FRAMED_THOUGHT) echo "$c_plum";; ACCENT_BAND) echo "$c_teal";; REVEAL_FOCUS) echo "$c_char";; CLOSING_GLOW) echo "$c_burg";; esac; }
text_tone(){ case "$design_family" in QUIET_CENTER|ACCENT_BAND|CLOSING_GLOW) echo LIGHT;; *) if [[ "$preferred_text" == LIGHT || "$preferred_text" == DARK ]]; then echo "$preferred_text"; else case "$design_family" in LEFT_STORY|FRAMED_THOUGHT) echo DARK;; *) echo LIGHT;; esac; fi;; esac; }
text_geometry(){
  local closing="$1"; tx=151; ty=672; tw=778; th=538; align=center
  case "$design_family" in
    LEFT_STORY) tx=96; ty=499; tw=618; th=768; align=left;;
    LOWER_REFLECTION) tx=123; ty=979; tw=834; th=557; align=left;;
    FRAMED_THOUGHT) tx=215; ty=703; tw=650; th=515; align=center;;
    ACCENT_BAND) tx=123; ty=576; tw=769; th=692; align=left;;
    REVEAL_FOCUS) tx=128; ty=595; tw=651; th=768; align=left;;
    CLOSING_GLOW) tx=177; ty=710; tw=726; th=519; align=center;;
    QUIET_CENTER) tx=166; ty=691; tw=748; th=500; align=center;;
  esac
  if [[ "$closing" == true ]]; then
    case "$design_family" in
      LEFT_STORY) ty=518; th=787;; LOWER_REFLECTION) ty=941; th=614;; FRAMED_THOUGHT) ty=684; th=538;; ACCENT_BAND) ty=537; th=711;; REVEAL_FOCUS) ty=557; th=787;; CLOSING_GLOW) ty=672; th=538;; QUIET_CENTER) ty=653; th=519;;
    esac
  fi
  if [[ "$design_position" == RIGHT && "$design_family" =~ ^(LEFT_STORY|ACCENT_BAND|REVEAL_FOCUS)$ ]]; then tx=$((1080-tx-tw)); fi
  if [[ "$design_position" == CENTER ]]; then tx=$(((1080-tw)/2)); align=center; fi
}
family_filter(){
  local accent footer f="" right=0; accent="$(family_accent)"; footer="$(footer_color)"; [[ "$design_position" == RIGHT ]] && right=1
  case "$design_family" in
    QUIET_CENTER) f="drawbox=x=0:y=0:w=1080:h=1920:color=$c_char@0.50:t=fill,drawbox=x=410:y=499:w=260:h=3:color=$accent@0.95:t=fill,drawbox=x=535:y=490:w=11:h=11:color=$accent@0.95:t=fill";;
    LEFT_STORY)
      if [[ "$design_position" == CENTER ]]; then f="drawbox=x=119:y=0:w=842:h=1747:color=$c_ivory@0.68:t=fill,drawbox=x=410:y=451:w=260:h=3:color=$accent@0.95:t=fill,drawbox=x=535:y=442:w=11:h=11:color=$accent@0.95:t=fill";
      elif [[ $right -eq 1 ]]; then f="drawbox=x=335:y=0:w=745:h=1747:color=$c_ivory@0.68:t=fill,drawbox=x=1014:y=422:w=7:h=845:color=$accent@0.95:t=fill,drawbox=x=810:y=1344:w=189:h=3:color=$accent@0.95:t=fill";
      else f="drawbox=x=0:y=0:w=745:h=1747:color=$c_ivory@0.68:t=fill,drawbox=x=59:y=422:w=7:h=845:color=$accent@0.95:t=fill,drawbox=x=81:y=1344:w=189:h=3:color=$accent@0.95:t=fill"; fi;;
    LOWER_REFLECTION) f="drawbox=x=0:y=1747:w=1080:h=173:color=$c_char@0.58:t=fill,drawbox=x=0:y=1574:w=1080:h=173:color=$c_char@0.48:t=fill,drawbox=x=0:y=1401:w=1080:h=173:color=$c_char@0.39:t=fill,drawbox=x=0:y=1228:w=1080:h=173:color=$c_char@0.29:t=fill,drawbox=x=0:y=1055:w=1080:h=173:color=$c_char@0.19:t=fill,drawbox=x=0:y=882:w=1080:h=173:color=$c_char@0.10:t=fill,drawbox=x=108:y=1536:w=270:h=3:color=$accent@0.95:t=fill";;
    FRAMED_THOUGHT) f="drawbox=x=0:y=0:w=1080:h=1920:color=$c_plum@0.10:t=fill,drawbox=x=130:y=530:w=820:h=760:color=$c_ivory@0.90:t=fill,drawbox=x=130:y=530:w=820:h=760:color=$c_plum@0.95:t=6,drawbox=x=360:y=585:w=360:h=3:color=$c_plum@0.95:t=fill";;
    ACCENT_BAND) f="drawbox=x=0:y=0:w=1080:h=1920:color=$c_char@0.48:t=fill,drawbox=x=0:y=1382:w=1080:h=106:color=$c_teal@0.92:t=fill"; if [[ "$design_position" == CENTER ]]; then f+=",drawbox=x=410:y=470:w=260:h=5:color=$c_teal@0.98:t=fill"; elif [[ $right -eq 1 ]]; then f+=",drawbox=x=713:y=470:w=259:h=5:color=$c_teal@0.98:t=fill"; else f+=",drawbox=x=108:y=470:w=259:h=5:color=$c_teal@0.98:t=fill"; fi;;
    REVEAL_FOCUS)
      if [[ "$design_position" == CENTER ]]; then f="drawbox=x=119:y=346:w=140:h=1114:color=$c_char@0.30:t=fill,drawbox=x=259:y=346:w=140:h=1114:color=$c_char@0.35:t=fill,drawbox=x=399:y=346:w=140:h=1114:color=$c_char@0.40:t=fill,drawbox=x=539:y=346:w=140:h=1114:color=$c_char@0.40:t=fill,drawbox=x=679:y=346:w=140:h=1114:color=$c_char@0.35:t=fill,drawbox=x=819:y=346:w=140:h=1114:color=$c_char@0.30:t=fill,drawbox=x=410:y=1382:w=260:h=4:color=$accent@0.98:t=fill";
      elif [[ $right -eq 1 ]]; then f="drawbox=x=950:y=0:w=130:h=1920:color=$c_char@0.66:t=fill,drawbox=x=820:y=0:w=130:h=1920:color=$c_char@0.59:t=fill,drawbox=x=690:y=0:w=130:h=1920:color=$c_char@0.53:t=fill,drawbox=x=560:y=0:w=130:h=1920:color=$c_char@0.46:t=fill,drawbox=x=430:y=0:w=130:h=1920:color=$c_char@0.40:t=fill,drawbox=x=300:y=0:w=130:h=1920:color=$c_char@0.33:t=fill,drawbox=x=1009:y=442:w=7:h=883:color=$accent@0.98:t=fill,drawbox=x=810:y=1382:w=162:h=4:color=$accent@0.98:t=fill";
      else f="drawbox=x=0:y=0:w=130:h=1920:color=$c_char@0.66:t=fill,drawbox=x=130:y=0:w=130:h=1920:color=$c_char@0.59:t=fill,drawbox=x=260:y=0:w=130:h=1920:color=$c_char@0.53:t=fill,drawbox=x=390:y=0:w=130:h=1920:color=$c_char@0.46:t=fill,drawbox=x=520:y=0:w=130:h=1920:color=$c_char@0.40:t=fill,drawbox=x=650:y=0:w=130:h=1920:color=$c_char@0.33:t=fill,drawbox=x=65:y=442:w=7:h=883:color=$accent@0.98:t=fill,drawbox=x=108:y=1382:w=162:h=4:color=$accent@0.98:t=fill"; fi;;
    CLOSING_GLOW) f="drawbox=x=0:y=0:w=1080:h=1920:color=$c_char@0.46:t=fill,drawbox=x=0:y=1747:w=1080:h=173:color=$c_burg@0.30:t=fill,drawbox=x=0:y=1574:w=1080:h=173:color=$c_burg@0.25:t=fill,drawbox=x=0:y=1401:w=1080:h=173:color=$c_burg@0.20:t=fill,drawbox=x=0:y=1228:w=1080:h=173:color=$c_burg@0.15:t=fill,drawbox=x=421:y=518:w=86:h=3:color=$accent@0.95:t=fill,drawbox=x=572:y=518:w=86:h=3:color=$accent@0.95:t=fill,drawbox=x=532:y=503:w=15:h=15:color=$accent@0.95:t=fill";;
  esac
  if [[ "$design_family" =~ ^(QUIET_CENTER|ACCENT_BAND|CLOSING_GLOW)$ ]]; then f+=",drawbox=x=0:y=0:w=1080:h=202:color=$c_char@0.48:t=fill,drawbox=x=0:y=202:w=1080:h=86:color=$c_char@0.28:t=fill,drawbox=x=0:y=288:w=1080:h=67:color=$c_char@0.12:t=fill"; fi
  local film_a film_c text_a logo_a tone; film_a="$(alpha_for_film "$film_strength")"; case "$film_tone" in LIGHT) film_c="$c_ivory";; WARM) film_c="$c_warm";; *) film_c="$c_char";; esac
  [[ "$film_a" != 0 ]] && f+=",drawbox=x=0:y=0:w=1080:h=1920:color=$film_c@$film_a:t=fill"
  text_a="$(alpha_for_support "$text_support")"; tone="$(text_tone)"; if [[ "$text_a" != 0 ]]; then local support_c="$c_ivory"; [[ "$tone" == LIGHT ]] && support_c="$c_char"; f+=",drawbox=x=$((tx-27)):y=$((ty-38)):w=$((tw+54)):h=$((th+76)):color=$support_c@$text_a:t=fill"; fi
  logo_a="$(alpha_for_support "$logo_support")"; if [[ "$logo_a" != 0 ]]; then local logo_c="$c_ivory"; [[ "$tone" == LIGHT ]] && logo_c="$c_char"; f+=",drawbox=x=0:y=0:w=1080:h=288:color=$logo_c@$logo_a:t=fill"; fi
  f+=",drawbox=x=0:y=1776:w=1080:h=144:color=$footer@0.96:t=fill,drawbox=x=0:y=1776:w=1080:h=3:color=$c_gold@0.98:t=fill"
  printf '%s' "$f"
}
render_v3_native(){ local count; count="$(jq -r '.overlay.slides | length' "$request" 2>/dev/null || echo 0)"; [[ "$count" == "5" ]] || { echo "Invalid v3 Reel request: overlay.slides must contain exactly five story beats." >&2; exit 1; }; reel_design_values || exit 1; mapfile -t static_slides < <(jq -r '.fallback.static_slides[]? // empty' "$request"); if [[ "$allow_static_slides" == "true" && ${#static_slides[@]} -ne 5 ]]; then echo "Invalid v3 Reel request: static fallback requires exactly five static_slides." >&2; exit 1; fi; local total=$((duration*5)); if ! normalize_cinematic "$total"; then [[ "$allow_static_slides" == "true" ]] || { echo "Cinematic clip unavailable and static fallback is disabled." >&2; exit 1; }; render_all_static static_slides; echo 0; return; fi; local font_regular font_bold font_serif font_serif_bold; font_regular="$(fc-match -f '%{file}\n' 'DejaVu Sans' | head -1)"; font_bold="$(fc-match -f '%{file}\n' 'DejaVu Sans:style=Bold' | head -1)"; font_serif="$(fc-match -f '%{file}\n' 'Georgia' | head -1)"; font_serif_bold="$(fc-match -f '%{file}\n' 'Georgia:style=Bold' | head -1)"; [[ -f "$font_regular" ]] || { echo "A usable sans-serif font was not found." >&2; return 1; }; [[ -f "$font_bold" ]] || font_bold="$font_regular"; [[ -f "$font_serif" ]] || font_serif="$font_regular"; [[ -f "$font_serif_bold" ]] || font_serif_bold="$font_serif"; local brand_name brand_tagline; brand_name="$(jq -r '.overlay.brand.name // "I See You"' "$request")"; brand_tagline="$(jq -r '.overlay.brand.tagline // "Remember, You Matter"' "$request")"; printf '%s' "$brand_name" > "$work/brand.txt"; printf '%s' "$brand_tagline" > "$work/tagline.txt"; : > "$work/native_concat.txt"; local native_ok=1; for i in 0 1 2 3 4; do local raw="$work/raw_$i.txt" text="$work/text_$i.txt" part="$work/native_$i.mp4" closing=false; [[ "$i" -eq 4 ]] && closing=true; jq -r ".overlay.slides[$i].text // empty" "$request" > "$raw"; [[ -s "$raw" ]] || { native_ok=0; break; }; wrap_text_file "$raw" "$text"; text_geometry "$closing"; local chars fontsize offset tone textcolor textx texty filters; chars="$(wc -m < "$raw" | tr -d ' ')"; if [[ "$chars" -le 70 ]]; then fontsize=62; elif [[ "$chars" -le 120 ]]; then fontsize=56; else fontsize=50; fi; [[ "$design_family" == FRAMED_THOUGHT && "$fontsize" -gt 54 ]] && fontsize=54; offset=$((i*duration)); tone="$(text_tone)"; textcolor="$c_white"; [[ "$tone" == DARK ]] && textcolor="$c_dark"; textx="$tx"; [[ "$align" == center ]] && textx='(w-text_w)/2'; texty="$((ty+th/2))-(text_h/2)"; filters="$(family_filter)"; filters+=",drawtext=fontfile='$font_serif_bold':textfile='$work/brand.txt':fontcolor=$c_white@0.96:fontsize=44:x=(w-text_w)/2:y=70:shadowcolor=$c_char@0.70:shadowx=2:shadowy=2"; filters+=",drawtext=fontfile='$font_serif':textfile='$text':fontcolor=$textcolor:fontsize=$fontsize:line_spacing=18:x=$textx:y=$texty:shadowcolor=$c_char@0.72:shadowx=3:shadowy=3"; if [[ "$closing" == true && "$design_family" != FRAMED_THOUGHT ]]; then filters+=",drawbox=x=$((tx+tw*34/100)):y=$((ty+th+35)):w=$((tw*32/100)):h=3:color=$(family_accent)@0.95:t=fill"; fi; filters+=",drawtext=fontfile='$font_serif':textfile='$work/tagline.txt':fontcolor=$c_white@0.94:fontsize=31:x=(w-text_w)/2:y=1820:shadowcolor=$c_char@0.60:shadowx=2:shadowy=2,format=yuv420p"; if ! ffmpeg -y -loglevel error -ss "$offset" -i "$work/cinematic_bg.mp4" -t "$duration" -vf "$filters" -r 30 -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart -an "$part"; then native_ok=0; break; fi; printf "file '%s'\n" "$part" >> "$work/native_concat.txt"; done; if [[ "$native_ok" -eq 1 ]]; then mv "$work/native_concat.txt" "$work/concat.txt"; echo 1; return; fi; [[ "$allow_static_slides" == "true" ]] || { echo "Native cinematic design overlay failed and static fallback is disabled." >&2; exit 1; }; render_all_static static_slides; echo 0; }
ambient_frequencies(){ case "$music_mood" in RENEWAL|HOPE|OPENNESS) echo '196 246.94 293.66';; CALM|STILLNESS) echo '220 277.18 329.63';; REFLECTION|GRIEF|LONELINESS) echo '174.61 220 261.63';; *) echo '196 246.94 293.66';; esac; }
render_soft_music(){ local total="$1" fade; fade=$((total>2?total-2:0)); read -r f1 f2 f3 <<< "$(ambient_frequencies)"; ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=$f1:sample_rate=44100:duration=$total" -f lavfi -i "sine=frequency=$f2:sample_rate=44100:duration=$total" -f lavfi -i "sine=frequency=$f3:sample_rate=44100:duration=$total" -filter_complex "[0:a]volume=0.18[a0];[1:a]volume=0.15[a1];[2:a]volume=0.12[a2];[a0][a1][a2]amix=inputs=3:normalize=0,highpass=f=90,lowpass=f=1200,afade=t=in:st=0:d=1.5,afade=t=out:st=$fade:d=2[a]" -map '[a]' -c:a aac -b:a 96k "$work/soft-music.m4a"; }

cinematic_ok=0
case "$schema" in isy-reel-request-v3) cinematic_ok="$(render_v3_native)";; isy-reel-request-v1|isy-reel-request-v2) cinematic_ok="$(render_legacy)";; *) echo "Unsupported Reel request schema: $schema" >&2; exit 1;; esac
ffmpeg -y -loglevel error -f concat -safe 0 -i "$work/concat.txt" -c copy -movflags +faststart "$work/video-only.mp4"
audio_added=false
if [[ "$schema" == "isy-reel-request-v3" && "$music_mode" == "SOFT" ]]; then [[ "$music_source" == "BUILT_IN_AMBIENT_V1" ]] || { echo "Unsupported v3 music source: $music_source" >&2; exit 1; }; total_seconds=$((duration*5)); render_soft_music "$total_seconds"; ffmpeg -y -loglevel error -i "$work/video-only.mp4" -i "$work/soft-music.m4a" -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 96k -shortest -movflags +faststart "$out"; audio_added=true; else mv "$work/video-only.mp4" "$out"; fi
resolution="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$out")"; [[ "$resolution" == "1080x1920" ]] || { echo "Unexpected Reel resolution: $resolution" >&2; exit 1; }
if [[ "$schema" == "isy-reel-request-v3" && "$music_mode" == "SOFT" ]]; then audio_codec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$out")"; [[ "$audio_codec" == "aac" ]] || { echo "Required AAC soft-music track is missing." >&2; exit 1; }; fi
if [[ "$schema" == "isy-reel-request-v3" ]]; then jq -n --arg status READY --arg render_id "$render_id" --arg schema "$schema" --argjson audio "$audio_added" --arg music_source "$music_source" --arg design_family "${design_family:-}" --arg design_position "${design_position:-}" --arg layout "$(jq -r '.overlay.layout // ""' "$request")" --arg rendered_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{status:$status,render_id:$render_id,schema:$schema,audio:$audio,music_source:$music_source,design_family:$design_family,design_position:$design_position,layout:$layout,rendered_at:$rendered_at}' > "$status_out"; fi
printf 'Rendered %s (%s) schema=%s render_id=%s cinematic=%s audio=%s\n' "$out" "$resolution" "$schema" "$render_id" "$cinematic_ok" "$audio_added"
