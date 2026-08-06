#!/bin/bash
# Per-item worker for the monthly render farm.
#   process.sh "<Language>/<Sign>" "<JOB>"
#
# Pulls only what this one sign needs from the Azure share, renders the clip,
# stitches intro + sign + outro, optionally uploads to YouTube, and pushes the
# finished MP4 back to the share.
#
# Nothing proprietary lives in this file - the render scripts themselves come
# down from the private share at runtime.
set -euo pipefail

ITEM="$1"          # e.g. "Marathi/Aries"
JOB="$2"           # e.g. "August_2026"
LANG_NAME="${ITEM%%/*}"
SIGN="${ITEM##*/}"

AZ=(--account-name "$STORAGE" --sas-token "$AZURE_SAS" -s "$SHARE")
say() { echo "::group::$*"; }
end() { echo "::endgroup::"; }

echo "=== $LANG_NAME / $SIGN  (job $JOB) ==="
START=$(date +%s)

# ---------------------------------------------------------------- fetch code
say "Fetching render scripts + assets"
az storage file download-batch "${AZ[@]}" -d . --pattern "$JOB/code/*"    -o none
az storage file download-batch "${AZ[@]}" -d . --pattern "$JOB/assets/*"  -o none
mv "$JOB/code" ./code
mv "$JOB/assets" ./assets
end

# --------------------------------------------------------- fetch this item's data
say "Fetching audio + pre-rendered text for $SIGN"
mkdir -p "monthly/output/$JOB/$LANG_NAME/audio" "monthly/output/$JOB/$LANG_NAME/text" \
         "monthly/output/$JOB/$LANG_NAME/clips_16_9" "monthly/input/$JOB/$LANG_NAME"

# NOTE: --dest must be an EXISTING DIRECTORY. Different az versions disagree
# about whether a --dest that looks like a file path is a file or a directory
# (the runner's build resolved "x.json" to "x.json/x.json"). Passing a directory
# that already exists is unambiguous everywhere, and az keeps the basename.
fetch() { az storage file download "${AZ[@]}" -p "$1" --dest "$2" -o none; }

AUD="monthly/output/$JOB/$LANG_NAME/audio"
TXT="monthly/output/$JOB/$LANG_NAME/text"
CLIPS="monthly/output/$JOB/$LANG_NAME/clips_16_9"
INP="monthly/input/$JOB/$LANG_NAME"

fetch "$JOB/data/$LANG_NAME/audio/$SIGN.wav"    "$AUD"
fetch "$JOB/data/$LANG_NAME/audio/Plug.wav"     "$AUD"
fetch "$JOB/data/$LANG_NAME/text/$SIGN.png"     "$TXT"
fetch "$JOB/data/$LANG_NAME/text/$SIGN.json"    "$TXT"
fetch "$JOB/data/$LANG_NAME/text/_Header.png"   "$TXT"
fetch "$JOB/data/$LANG_NAME/text/_Header.json"  "$TXT"
# DS text is only a fallback; the pre-rendered PNG is authoritative.
fetch "$JOB/data/$LANG_NAME/${SIGN}_DS.txt"     "$INP" || true
# The shared outro clip was rendered locally - no need to rebuild it here.
fetch "$JOB/data/$LANG_NAME/ZZ_Outro_16_9.mp4"  "$CLIPS"

echo "--- fetched ---"; ls -lh "$AUD" "$TXT" "$CLIPS"
end

# ------------------------------------------------------------------- render
say "Rendering $SIGN"
cp code/*.py monthly/
python monthly/monthly_video_generator.py "$LANG_NAME" "$SIGN" "$JOB"
end

say "Stitching final video"
python monthly/monthly_aggregate.py "$LANG_NAME" "$SIGN" "$JOB"
end

FINAL="monthly/output/$JOB/$LANG_NAME/${JOB}_${LANG_NAME}_${SIGN}_Monthly_16_9.mp4"
if [ ! -f "$FINAL" ]; then
  echo "::error::final video missing for $ITEM"; exit 1
fi
ls -lh "$FINAL"

# --------------------------------------------------------- push result FIRST
# The rendered MP4 goes to the share BEFORE any upload attempt. YouTube's API
# allows only ~6 uploads/day per project, so most of a 48-video batch will hit
# quota-exceeded. Uploading first would mean `set -e` killed the job and threw
# away a video that took an hour to render.
say "Pushing finished video to the share"
mkdir -p outbox
cp "$FINAL" "outbox/$(basename "$FINAL")"
az storage file upload-batch --account-name "$STORAGE" --sas-token "$AZURE_SAS" \
  --destination "$SHARE" --destination-path "$JOB/outputs/$LANG_NAME" --source outbox -o none
echo "video is safe on the share regardless of what the upload does"
end

# ------------------------------------------------------------------- upload
UPLOAD_STATUS="skipped"
if [ "${DO_UPLOAD:-false}" = "true" ]; then
  say "Uploading to YouTube"
  mkdir -p tokens meta
  fetch "$JOB/secrets/token_${LANG_NAME,,}.json" tokens
  fetch "$JOB/secrets/client_secret.json"        .
  fetch "$JOB/data/$LANG_NAME/metadata/$SIGN.json" meta

  # Non-fatal on purpose: a quota rejection must not fail the job or lose work.
  set +e
  python code/upload_youtube.py "$LANG_NAME" "$SIGN" "$FINAL" "meta/$SIGN.json" 2>&1 | tee upload.log
  UP_RC=${PIPESTATUS[0]}
  set -e

  if [ "$UP_RC" -eq 0 ]; then
    UPLOAD_STATUS="uploaded"
    echo "✅ uploaded $ITEM"
  elif grep -qiE "quotaExceeded|uploadLimitExceeded|exceeded your.*quota" upload.log; then
    UPLOAD_STATUS="quota_exceeded"
    echo "::warning::QUOTA EXCEEDED for $ITEM — video is on the share, retry the upload later"
  else
    UPLOAD_STATUS="failed"
    echo "::warning::upload failed for $ITEM (rc=$UP_RC) — video is on the share"
    tail -20 upload.log || true
  fi
  end
else
  echo "DO_UPLOAD not true - skipping YouTube upload"
fi

# ------------------------------------------------- record what happened
say "Recording upload status"
mkdir -p status
VID=""
[ -f upload_result.json ] && VID=$(python -c "import json;print(json.load(open('upload_result.json')).get('video_id',''))" 2>/dev/null || echo "")
cat > "status/${LANG_NAME}_${SIGN}.json" <<EOF
{"item":"$ITEM","status":"$UPLOAD_STATUS","video_id":"$VID","rendered":true}
EOF
cat "status/${LANG_NAME}_${SIGN}.json"
az storage file upload-batch --account-name "$STORAGE" --sas-token "$AZURE_SAS" \
  --destination "$SHARE" --destination-path "$JOB/status" --source status -o none
end

echo "=== done $ITEM in $(( ($(date +%s) - START) / 60 )) min ==="
