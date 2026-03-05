#!/bin/sh
dd if=/dev/urandom bs=1024 count=5000 of=/tmp/relay.mp3 2>/dev/null
echo "=== Upload 5MB to 0x0.st ==="
TEMP_URL=$(curl -sS --max-time 120 -F "file=@/tmp/relay.mp3" "https://0x0.st")
echo "Temp URL: $TEMP_URL"
if [ -z "$TEMP_URL" ]; then
  echo "FAILED - trying transfer.sh"
  TEMP_URL=$(curl -sS --max-time 120 --upload-file /tmp/relay.mp3 "https://transfer.sh/relay.mp3")
  echo "transfer.sh URL: $TEMP_URL"
fi
if [ -n "$TEMP_URL" ]; then
  echo "=== file-url-upload to Suno ==="
  curl -sS --max-time 60 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -H "Content-Type: application/json" -d "{\"fileUrl\":\"${TEMP_URL}\",\"uploadPath\":\"audio-references/test\",\"fileName\":\"test.mp3\"}" "https://sunoapiorg.redpandaai.co/api/file-url-upload"
  echo ""
fi
rm -f /tmp/relay.mp3
