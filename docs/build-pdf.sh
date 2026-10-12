#!/usr/bin/env bash
set -euo pipefail

# guide.html → docs/ticket-loop-guide.pdf (A4, 머리글·바닥글 없음)
# ticket-loop.sh를 고쳤으면 먼저 python3 docs/sync-guide.py로 부록 D를 다시 채운다.
#   bash docs/build-pdf.sh

DIR="$(cd "$(dirname "$0")" && pwd)"
CHROME="${CHROME:-}"
if [[ -z "$CHROME" ]]; then
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" google-chrome chromium chromium-browser; do
    if [[ -x "$c" ]] || command -v "$c" >/dev/null 2>&1; then CHROME="$c"; break; fi
  done
fi
[[ -n "$CHROME" ]] || { echo "Chrome/Chromium이 없습니다 (CHROME=경로로 지정)" >&2; exit 1; }
"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="$DIR/ticket-loop-guide.pdf" "file://$DIR/guide.html" 2>/dev/null
echo "→ $DIR/ticket-loop-guide.pdf"
