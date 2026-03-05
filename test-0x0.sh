#!/bin/sh
dd if=/dev/urandom bs=1024 count=5000 of=/tmp/big.mp3 2>/dev/null
echo "=== Upload 5MB to 0x0.st ==="
TEMP_URL=$(curl -sS --max-time 120 -F "file=@/tmp/big.mp3" "https://0x0.st")
echo "Temp URL: $TEMP_URL"
if [ -n "$TEMP_URL" ]; then
  echo "=== file-url-upload to Suno ==="
  curl -sS --max-time 60 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -H "Content-Type: application/json" -d "{\"fileUrl\":\"${TEMP_URL}\",\"uploadPath\":\"audio-references/test\",\"fileName\":\"test.mp3\"}" "https://sunoapiorg.redpandaai.co/api/file-url-upload"
  echo ""
fi
rm -f /tmp/big.mp3
