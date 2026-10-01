#!/usr/bin/env bash
# Nice Scarfs Reels işleyicisi (GitHub Actions). nicescarfs.com/ig/reels listesindeki her Reels'i yeniden kurgular ve
# "reels" sürümüne <id>.mp4 olarak yükler; site dosyayı buradan kendisi çeker (IgRemote). Yalnız nicescarfs.com/media/
# adreslerinden indirir. Kurgu: 0,8 sn giriş kartı + kaynak video (9:16, üstten sabit kırpma, %4 yakınlaştırma üst kenar
# sabit, hafif renk, "NICE SCARFS" etiketi) + 1,5 sn kapanış kartı. Kalite düşürülmez: H.264 CRF 19 slow, 30 fps, AAC 128k,
# en çok 1080x1920, büyütme yok.
set -euo pipefail

MANIFEST="${MANIFEST:-https://nicescarfs.com/ig/reels}"
TAG=reels
FONT="$(pwd)/fonts/DMMono-Medium.ttf"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

gh release view "$TAG" >/dev/null 2>&1 || gh release create "$TAG" -t "Nice Scarfs Reels" -n "Otomatik işlenmiş Reels videoları."
have="$(gh release view "$TAG" --json assets -q '.assets[].name' || true)"

if [[ "${TEST:-0}" == "1" ]]; then
  # Deneme: örnek video (720x1280, 6 sn, sesli) ve kartlar burada üretilir; aynı kurgu uygulanır, "test.mp4" yüklenir.
  mkdir -p "$work/test"
  ffmpeg -y -loglevel error -f lavfi -i testsrc2=size=720x1280:rate=30 -f lavfi -i sine=frequency=440 -t 6 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$work/test/src.mp4"
  ffmpeg -y -loglevel error -f lavfi -i color=c=0x7A1F2B:s=1080x1920 -frames:v 1 "$work/test/intro.jpg"
  ffmpeg -y -loglevel error -f lavfi -i color=c=0xF5F2F0:s=1080x1920 -frames:v 1 "$work/test/close.jpg"
  echo '{"items":[{"id":"test"}]}' > "$work/m.json"
else
  curl -fsSL --retry 3 "$MANIFEST" -o "$work/m.json"
fi
count=$(jq '.items | length' "$work/m.json")
echo "Listede $count Reels"

safe() { [[ "$1" =~ ^https://nicescarfs\.com/media/[A-Za-z0-9/_.-]+$ ]]; }

jq -c '.items[]' "$work/m.json" | while read -r it; do
  id=$(jq -r .id <<<"$it"); src=$(jq -r .src <<<"$it"); intro=$(jq -r .intro <<<"$it"); close=$(jq -r .close <<<"$it")
  d="$work/$id"
  if [[ "$id" != "test" ]]; then
    [[ "$id" =~ ^[0-9]+$ ]] || { echo "geçersiz id"; continue; }
    if grep -qx "$id.mp4" <<<"$have"; then echo "$id hazır"; continue; fi
    safe "$src" && safe "$intro" && safe "$close" || { echo "$id: izin dışı adres, atlandı"; continue; }
    mkdir -p "$d"
    curl -fsSL --retry 3 "$src" -o "$d/src.mp4"
    curl -fsSL --retry 3 "$intro" -o "$d/intro.jpg"
    curl -fsSL --retry 3 "$close" -o "$d/close.jpg"
  fi

  read -r w h < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=' ' "$d/src.mp4")
  rot=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=rotation -of csv=p=0 "$d/src.mp4" | head -1 || true)
  if [[ "${rot#-}" == "90" || "${rot#-}" == "270" ]]; then t=$w; w=$h; h=$t; fi
  # 9:16 kırpma alanı kaynak çözünürlükte; fazlası alttan (baş kesilmez) ya da iki yandan eşit gider.
  if (( w * 16 > h * 9 )); then ch=$h; cw=$(( h * 9 / 16 )); else cw=$w; ch=$(( w * 16 / 9 )); fi
  cw=$(( cw / 2 * 2 )); ch=$(( ch / 2 * 2 ))
  oh=$(( ch < 1920 ? ch : 1920 )); oh=$(( oh / 2 * 2 )); ow=$(( oh * 9 / 16 / 2 * 2 ))
  zw=$(( ow * 104 / 100 / 2 * 2 )); zh=$(( oh * 104 / 100 / 2 * 2 ))
  fs=$(( oh * 22 / 1920 )); (( fs < 14 )) && fs=14
  pad=$(( ow * 40 / 1080 )); top=$(( oh * 250 / 1920 ))

  vid="crop=${cw}:${ch}:(iw-${cw})/2:0,scale=${zw}:${zh},crop=${ow}:${oh}:(iw-${ow})/2:0,eq=contrast=1.03:brightness=0.01:saturation=1.05,"
  vid+="drawtext=fontfile=${FONT}:text='NICE SCARFS':fontsize=${fs}:fontcolor=white@0.9:box=1:boxcolor=black@0.28:boxborderw=$(( fs / 2 )):x=w-tw-${pad}:y=${top},"
  vid+="setsar=1,fps=30,format=yuv420p"
  card="scale=${ow}:${oh}:force_original_aspect_ratio=increase,crop=${ow}:${oh}:(iw-${ow})/2:0,setsar=1,fps=30,format=yuv420p"

  if ffprobe -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$d/src.mp4" | grep -q .; then
    amid='[1:a]aresample=44100,aformat=channel_layouts=stereo[a1];'; ain='[a1]'; extra=()
  else
    amid=''; ain='[5:a]'; extra=(-f lavfi -i anullsrc=r=44100:cl=stereo)
  fi
  ffmpeg -y -hide_banner -loglevel error \
    -loop 1 -t 0.8 -i "$d/intro.jpg" -i "$d/src.mp4" -loop 1 -t 1.5 -i "$d/close.jpg" \
    -f lavfi -t 0.8 -i anullsrc=r=44100:cl=stereo -f lavfi -t 1.5 -i anullsrc=r=44100:cl=stereo "${extra[@]}" \
    -filter_complex "[0:v]${card}[v0];[1:v]${vid}[v1];[2:v]${card}[v2];${amid}[v0][3:a][v1]${ain}[v2][4:a]concat=n=3:v=1:a=1[v][a]" \
    -map '[v]' -map '[a]' -c:v libx264 -preset slow -crf 19 -profile:v high -pix_fmt yuv420p \
    -c:a aac -b:a 128k -ar 44100 -movflags +faststart "$d/$id.mp4"

  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$d/$id.mp4")
  echo "$id: ${w}x${h} → ${ow}x${oh}, ${dur} sn"
  gh release upload "$TAG" "$d/$id.mp4" --clobber
done

# 7 günden eski dosyalar silinir (site paylaştıktan sonra kendi kopyasını tutar).
cut=$(date -u -d '7 days ago' +%s)
gh release view "$TAG" --json assets -q '.assets[] | "\(.name) \(.createdAt)"' | while read -r name at; do
  (( $(date -u -d "$at" +%s) < cut )) && gh release delete-asset "$TAG" "$name" -y || true
done
