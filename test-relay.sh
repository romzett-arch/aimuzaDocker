#!/bin/sh
dd if=/dev/urandom bs=1024 count=5000 of=/tmp/big.mp3 2>/dev/null
echo "=== Upload 5MB to 0x0.st ==="
TEMP_URL=$(curl -sS --max-time 120 -F "file=@/tmp/big.mp3" "https://0x0.st")
echo "URL: $TEMP_URL"
if [ -z "$TEMP_URL" ]; then
  echo "Upload to 0x0.st failed"
  exit 1
fi
echo "=== file-url-upload to Suno ==="
curl -sS --max-time 60 -X POST \
  -H "Authorization: Bearer e81b77211cf1b25b789e2371301bdc1d" \
  -H "Content-Type: application/json" \
  -d "{\"fileUrl\":\"${TEMP_URL}\",\"uploadPath\":\"audio-references/test\",\"fileName\":\"test.mp3\"}" \
  "https://sunoapiorg.redpandaai.co/api/file-url-upload"
echo ""
rm -f /tmp/big.mp3
