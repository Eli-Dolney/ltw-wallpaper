#!/bin/zsh
# Cut left/right hand PNGs out of a video frame that has a black background (e.g. a "Creation of Adam"
# banner clip) and write them to scenes/hands/left.png and right.png for the hands scene.
#   tools/cut-hands.sh <video> [time=0.3] [tolerance=0.05] [min_area=400] [edge=60]
# tolerance: brightness (0..1) below which a pixel can be background; min_area: dust blobs smaller than
# this many pixels are removed; edge: pixels of fade where an arm leaves the frame. Needs ffmpeg.
set -e
VID="$1"; T="${2:-0.3}"; TOL="${3:-0.05}"; MINAREA="${4:-400}"; EDGE="${5:-60}"
[ -f "$VID" ] || { sed -n '2,7p' "$0"; exit 1; }
cd "$(dirname "$0")/.."
OUT="scenes/hands"; TMP="$(mktemp -d)"
ffmpeg -y -v error -ss "$T" -i "$VID" -map 0:v:0 -frames:v 1 -pix_fmt rgb24 "$TMP/frame.png"
ffmpeg -y -v error -i "$TMP/frame.png" -f rawvideo -pix_fmt gray "$TMP/luma.gray"
W=$(sips -g pixelWidth "$TMP/frame.png" | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$TMP/frame.png" | awk '/pixelHeight/{print $2}')
python3 tools/matte.py "$TMP/luma.gray" "$W" "$H" "$TMP/alpha.gray" "$TOL" "$MINAREA" "$EDGE"
# merge the matte (slightly blurred for soft edges), lift near-black to black, split into halves
ffmpeg -y -v error -i "$TMP/frame.png" -f rawvideo -pix_fmt gray -s "${W}x${H}" -i "$TMP/alpha.gray" -filter_complex \
  "[1:v]gblur=sigma=1.2[a];[0:v]format=rgba[c];[c][a]alphamerge,lutrgb=r='clip((val-16)*255/239,0,255)':g='clip((val-16)*255/239,0,255)':b='clip((val-16)*255/239,0,255)'" \
  "$TMP/keyed.png"
# Split where the gap between the hands actually is (the widest empty column run in the middle of the
# matte), not at the frame's center line, so a fingertip that crosses the middle is never cut.
SPLIT=$(python3 - "$TMP/alpha.gray" "$W" "$H" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); W=int(sys.argv[2]); H=int(sys.argv[3])
lo,hi=int(W*0.3),int(W*0.7); best=(0,W//2); cur=0; start=0
for x in range(lo,hi):
    empty=all(d[y*W+x]<8 for y in range(int(H*0.1),int(H*0.9)))
    if empty:
        if cur==0: start=x
        cur+=1
        if cur>best[0]: best=(cur,start)
    else: cur=0
print(best[1]+best[0]//2 if best[0] else W//2)
PY
)
echo "split at x=$SPLIT (frame width $W)"
ffmpeg -y -v error -i "$TMP/keyed.png" -vf "crop=$SPLIT:ih:0:0"           "$TMP/left.png"
ffmpeg -y -v error -i "$TMP/keyed.png" -vf "crop=iw-$SPLIT:ih:$SPLIT:0"   "$TMP/right.png"
# Trim transparent margins so the image edge is the fingertip (cropdetect on the alpha channel).
trim() {
  local c
  c=$(ffmpeg -v info -i "$1" -vf "alphaextract,cropdetect=limit=8:round=2:reset=1:skip=0" -frames:v 1 -f null - 2>&1 | grep -o 'crop=[0-9:]*' | tail -1)
  if [ -n "$c" ]; then ffmpeg -y -v error -i "$1" -vf "$c" "$2"; else cp "$1" "$2"; fi
}
trim "$TMP/left.png"  "$OUT/left.png"
trim "$TMP/right.png" "$OUT/right.png"
rm -rf "$TMP"
for f in left right; do echo "$OUT/$f.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$f.png" | awk '/pixel/{printf "%s ", $2}')"; done
echo "left.png should point right, right.png should point left. Then: ./ltw reload"
