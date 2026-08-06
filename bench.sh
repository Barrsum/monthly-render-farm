#!/bin/bash
# Renderer benchmark worker. Runs entirely on a GitHub runner.
#   bench.sh <Language/Sign> <JOB> <renderer> <seconds>
#
# renderer: moviepy | ffmpeg | hyperframes
# Pulls the same inputs every renderer needs, times the render, and pushes both
# the MP4 and a timing JSON to <JOB>/bench/<renderer>/ on the share.
# Never uploads to YouTube.
set -euo pipefail

ITEM="$1"; JOB="$2"; RENDERER="$3"; SECONDS_ARG="${4:-180}"
LANG_NAME="${ITEM%%/*}"
SIGN="${ITEM##*/}"

AZ=(--account-name "$STORAGE" --sas-token "$AZURE_SAS" -s "$SHARE")
fetch() { az storage file download "${AZ[@]}" -p "$1" --dest "$2" -o none; }

echo "=== BENCH  $RENDERER  $LANG_NAME/$SIGN  ${SECONDS_ARG}s ==="

echo "::group::Fetch inputs"
az storage file download-batch "${AZ[@]}" -d . --pattern "$JOB/code/*"   -o none
az storage file download-batch "${AZ[@]}" -d . --pattern "$JOB/assets/*" -o none
mv "$JOB/code" ./code
mv "$JOB/assets" ./assets

AUD="monthly/output/$JOB/$LANG_NAME/audio"
TXT="monthly/output/$JOB/$LANG_NAME/text"
mkdir -p "$AUD" "$TXT" "monthly/output/$JOB/$LANG_NAME/clips_16_9"
fetch "$JOB/data/$LANG_NAME/audio/$SIGN.wav"   "$AUD"
fetch "$JOB/data/$LANG_NAME/text/$SIGN.png"    "$TXT"
fetch "$JOB/data/$LANG_NAME/text/$SIGN.json"   "$TXT"
fetch "$JOB/data/$LANG_NAME/text/_Header.png"  "$TXT"
fetch "$JOB/data/$LANG_NAME/text/_Header.json" "$TXT"
cp code/*.py monthly/ 2>/dev/null || true
mkdir -p hyperframe-test && cp code/render_ffmpeg.py code/make_composition.py hyperframe-test/ 2>/dev/null || true
echo "::endgroup::"

mkdir -p bench_out
START=$(date +%s)

case "$RENDERER" in

  ffmpeg)
    echo "::group::FFmpeg filter-graph render"
    python hyperframe-test/render_ffmpeg.py "$LANG_NAME" "$SIGN" "$JOB" "$SECONDS_ARG"
    echo "::endgroup::"
    cp hyperframe-test/output/*.mp4 bench_out/ 2>/dev/null || true
    ;;

  hyperframes)
    echo "::group::Build composition"
    python hyperframe-test/make_composition.py "$LANG_NAME" "$SIGN" "$JOB" hf_proj "$SECONDS_ARG"
    echo "::endgroup::"

    echo "::group::hyperframes lint + check"
    cd hf_proj
    npx --yes hyperframes@latest lint  || { echo "::warning::lint reported issues"; }
    npx --yes hyperframes@latest check || { echo "::warning::check reported issues"; }
    echo "::endgroup::"

    echo "::group::hyperframes render"
    npx --yes hyperframes@latest render --output "../bench_out/hyperframes_${LANG_NAME}_${SIGN}_${SECONDS_ARG}s.mp4"
    cd ..
    echo "::endgroup::"
    ;;

  moviepy)
    echo "::group::moviepy render (baseline)"
    python monthly/monthly_video_generator.py "$LANG_NAME" "$SIGN" "$JOB" "$SECONDS_ARG"
    echo "::endgroup::"
    cp "monthly/output/$JOB/$LANG_NAME/clips_16_9/${SIGN}_16_9.mp4" \
       "bench_out/moviepy_${LANG_NAME}_${SIGN}_${SECONDS_ARG}s.mp4" 2>/dev/null || true
    ;;

  *) echo "::error::unknown renderer $RENDERER"; exit 1 ;;
esac

ELAPSED=$(( $(date +%s) - START ))
echo "=== $RENDERER finished in ${ELAPSED}s ($((ELAPSED/60))m $((ELAPSED%60))s) ==="

ls -lh bench_out/ || true
FILE=$(ls bench_out/*.mp4 2>/dev/null | head -1)
if [ -z "$FILE" ]; then echo "::error::$RENDERER produced no MP4"; exit 1; fi

SIZE=$(stat -c%s "$FILE")
cat > "bench_out/timing_${RENDERER}.json" <<EOF
{"renderer":"$RENDERER","item":"$ITEM","seconds":$SECONDS_ARG,
 "wall_seconds":$ELAPSED,"realtime_x":$(python -c "print(round($SECONDS_ARG/max($ELAPSED,1),3))"),
 "output_bytes":$SIZE,"output":"$(basename "$FILE")"}
EOF
cat "bench_out/timing_${RENDERER}.json"

echo "::group::Push results to share"
az storage file upload-batch --account-name "$STORAGE" --sas-token "$AZURE_SAS" \
  --destination "$SHARE" --destination-path "$JOB/bench/$RENDERER" --source bench_out -o none
echo "::endgroup::"
