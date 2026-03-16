#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
KEYWORDS="plastic surgeon"
MAX_POSTS=50
SORT_TYPE="relevance"
BASE_URL="https://api.data365.co/v1.1"
POLL_INTERVAL=3
POLL_MAX=100  # 100 * 3s = 5 minutes max

# ─── Load .env ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env file not found at $ENV_FILE"
  echo "Copy .env.example to .env and add your DATA365_TOKEN."
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ -z "${DATA365_TOKEN:-}" ]]; then
  echo "ERROR: DATA365_TOKEN is not set in .env"
  exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
KEYWORDS_ENCODED=$(printf '%s' "$KEYWORDS" | jq -sRr @uri)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SAFE_NAME=$(printf '%s' "$KEYWORDS" | tr ' ' '_' | tr -cd '[:alnum:]_')
RESULTS_DIR="$SCRIPT_DIR/results"
JSON_FILE="$RESULTS_DIR/${SAFE_NAME}_${TIMESTAMP}.json"
CSV_FILE="$RESULTS_DIR/${SAFE_NAME}_${TIMESTAMP}.csv"
VIDEOS_DIR="$RESULTS_DIR/videos/${SAFE_NAME}_${TIMESTAMP}"

mkdir -p "$RESULTS_DIR" "$VIDEOS_DIR"

api_call() {
  local method="$1" url="$2"
  local http_code body tmp

  tmp=$(mktemp)
  http_code=$(curl -s -o "$tmp" -w '%{http_code}' -X "$method" \
    -H "accept: application/json" \
    "$url&access_token=$DATA365_TOKEN")
  body=$(cat "$tmp")
  rm -f "$tmp"

  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    echo "ERROR: Authentication failed (HTTP $http_code). Check your DATA365_TOKEN."
    echo "$body" | jq . 2>/dev/null || echo "$body"
    exit 1
  elif [[ "$http_code" == "429" ]]; then
    echo "ERROR: Rate limited (HTTP 429). Wait and try again."
    exit 1
  elif [[ "$http_code" -ge 400 ]]; then
    echo "ERROR: API returned HTTP $http_code"
    echo "$body" | jq . 2>/dev/null || echo "$body"
    exit 1
  fi

  # Validate JSON
  if ! echo "$body" | jq empty 2>/dev/null; then
    echo "ERROR: Response is not valid JSON"
    echo "$body"
    exit 1
  fi

  echo "$body"
}

# ─── Credit estimate ──────────────────────────────────────────────────────────
echo "=== TikTok Post Search ==="
echo "Keywords:  $KEYWORDS"
echo "Max posts: $MAX_POSTS"
echo "Sort:      $SORT_TYPE"
echo "Estimated credits: $((7 + MAX_POSTS)) (7 search + ${MAX_POSTS} x 1 post)"
echo ""

# ─── Step 1: Start search task ───────────────────────────────────────────────
echo "Step 1: Starting search task..."
SEARCH_PARAMS="keywords=${KEYWORDS_ENCODED}&load_posts=true&max_posts=${MAX_POSTS}&sort_type=${SORT_TYPE}"

RESPONSE=$(api_call POST "${BASE_URL}/tiktok/search/post/update?${SEARCH_PARAMS}")
TASK_ID=$(echo "$RESPONSE" | jq -r '.data.task_id // empty')
STATUS=$(echo "$RESPONSE" | jq -r '.data.status // empty')

if [[ -z "$TASK_ID" ]]; then
  echo "ERROR: No task_id in response"
  echo "$RESPONSE" | jq .
  exit 1
fi

echo "  Task ID: $TASK_ID"
echo "  Status:  $STATUS"

# ─── Step 2: Poll until finished ─────────────────────────────────────────────
if [[ "$STATUS" != "finished" ]]; then
  echo ""
  echo "Step 2: Polling for completion..."
  printf "  "

  for ((i = 1; i <= POLL_MAX; i++)); do
    sleep "$POLL_INTERVAL"
    RESPONSE=$(api_call GET "${BASE_URL}/tiktok/search/post/update?${SEARCH_PARAMS}")
    STATUS=$(echo "$RESPONSE" | jq -r '.data.status // empty')

    if [[ "$STATUS" == "finished" ]]; then
      printf " done!\n"
      echo "  Completed after $((i * POLL_INTERVAL))s"
      break
    elif [[ "$STATUS" == "fail" || "$STATUS" == "error" ]]; then
      printf "\n"
      echo "ERROR: Task failed with status: $STATUS"
      echo "$RESPONSE" | jq .
      exit 1
    fi

    printf "."
  done

  if [[ "$STATUS" != "finished" ]]; then
    echo ""
    echo "ERROR: Timed out after $((POLL_MAX * POLL_INTERVAL))s (status: $STATUS)"
    exit 1
  fi
else
  echo "  Already finished (cached result)."
fi

# ─── Step 3: Fetch results ───────────────────────────────────────────────────
echo ""
echo "Step 3: Fetching post results..."
ITEMS_PARAMS="keywords=${KEYWORDS_ENCODED}&sort_type=${SORT_TYPE}&max_page_size=${MAX_POSTS}"

ITEMS_RESPONSE=$(api_call GET "${BASE_URL}/tiktok/search/post/items?${ITEMS_PARAMS}")

POST_COUNT=$(echo "$ITEMS_RESPONSE" | jq '.data.items | length // 0')
echo "  Found $POST_COUNT posts"

# ─── Step 4: Download videos ─────────────────────────────────────────────────
echo ""
echo "Step 4: Downloading $POST_COUNT videos to $VIDEOS_DIR ..."

DOWNLOAD_OK=0
DOWNLOAD_FAIL=0
# Build a JSON map of id -> local path for later injection
PATH_MAP="{}"

for i in $(seq 0 $((POST_COUNT - 1))); do
  POST_ID=$(echo "$ITEMS_RESPONSE" | jq -r ".data.items[$i].id")
  CURL_CMD=$(echo "$ITEMS_RESPONSE" | jq -r ".data.items[$i].video.request // empty")
  VIDEO_FILE="$VIDEOS_DIR/${POST_ID}.mp4"

  if [[ -z "$CURL_CMD" ]]; then
    printf "  [%d/%d] %s — no download URL, skipped\n" $((i+1)) "$POST_COUNT" "$POST_ID"
    DOWNLOAD_FAIL=$((DOWNLOAD_FAIL + 1))
    continue
  fi

  # Extract URL and headers from the API-provided curl command
  DL_URL=$(echo "$CURL_CMD" | grep -oP "(?<=curl ').*?(?=')")
  REFERER=$(echo "$CURL_CMD" | grep -oP "(?<=-H 'Referer: ).*?(?=')")
  COOKIE=$(echo "$CURL_CMD" | grep -oP "(?<=-H 'Cookie: ).*?(?=')")

  HTTP_CODE=$(curl -s -o "$VIDEO_FILE" -w '%{http_code}' \
    -H "Referer: ${REFERER}" \
    -H "Cookie: ${COOKIE}" \
    -L "$DL_URL")

  # Check we got a real video (>10KB) and not an error page
  FILE_SIZE=$(stat -c%s "$VIDEO_FILE" 2>/dev/null || stat -f%z "$VIDEO_FILE" 2>/dev/null || echo 0)

  if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 400 && "$FILE_SIZE" -gt 10000 ]]; then
    printf "  [%d/%d] %s — %s bytes OK\n" $((i+1)) "$POST_COUNT" "$POST_ID" "$FILE_SIZE"
    PATH_MAP=$(echo "$PATH_MAP" | jq --arg id "$POST_ID" --arg p "$VIDEO_FILE" '. + {($id): $p}')
    DOWNLOAD_OK=$((DOWNLOAD_OK + 1))
  else
    printf "  [%d/%d] %s — FAILED (HTTP %s, %s bytes)\n" $((i+1)) "$POST_COUNT" "$POST_ID" "$HTTP_CODE" "$FILE_SIZE"
    rm -f "$VIDEO_FILE"
    DOWNLOAD_FAIL=$((DOWNLOAD_FAIL + 1))
  fi
done

echo "  Downloads: $DOWNLOAD_OK OK, $DOWNLOAD_FAIL failed"

# ─── Save JSON with local paths ──────────────────────────────────────────────
echo ""
echo "Saving JSON..."
echo "$ITEMS_RESPONSE" | jq --argjson paths "$PATH_MAP" '
  .data.items |= [ .[] | .video_local_path = ($paths[.id] // "") ]
' > "$JSON_FILE"
echo "  $JSON_FILE"

# ─── Generate CSV ─────────────────────────────────────────────────────────────
echo "Saving CSV..."

echo 'id,created_time,author_username,author_id,text,lang,play_count,digg_count,share_count,comment_count,save_count,hashtags,video_duration,video_cover_url,music_title,location_created,video_local_path' > "$CSV_FILE"

jq -r --argjson paths "$PATH_MAP" '
  .data.items[]? |
  [
    (.id // ""),
    (.created_time // ""),
    (.author_username // ""),
    (.author_id // ""),
    (.text // "" | gsub("\n"; " ") | gsub("\r"; "")),
    (.lang // ""),
    (.play_count // 0),
    (.digg_count // 0),
    (.share_count // 0),
    (.comment_count // 0),
    (.save_count // 0),
    ([ .hashtags[]? // empty ] | join(";")),
    (.video.duration // 0),
    (.video.cover_url // ""),
    (.music.title // ""),
    (.location_created // ""),
    ($paths[.id] // "")
  ] | @csv
' <<< "$ITEMS_RESPONSE" >> "$CSV_FILE"

CSV_ROWS=$(($(wc -l < "$CSV_FILE") - 1))
echo "  $CSV_FILE ($CSV_ROWS rows)"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Complete ==="
echo "JSON:   $JSON_FILE"
echo "CSV:    $CSV_FILE"
echo "Videos: $VIDEOS_DIR ($DOWNLOAD_OK files)"
echo "Posts:  $POST_COUNT"
