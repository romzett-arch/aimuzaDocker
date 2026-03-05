#!/bin/sh
dd if=/dev/urandom bs=1024 count=5000 of=/tmp/big.mp3 2>/dev/null
echo "=== Upload to tmpfiles.org ==="
RESP=$(curl -sS --max-time 60 -F "file=@/tmp/big.mp3" "https://tmpfiles.org/api/v1/upload")
echo "tmpfiles response: $RESP"
URL=$(echo "$RESP" | grep -o '"url":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "URL: $URL"
DIRECT=$(echo "$URL" | sed 's|tmpfiles.org/|tmpfiles.org/dl/|')
echo "Direct URL: $DIRECT"
echo ""
echo "=== file-url-upload to Suno ==="
curl -sS --max-time 60 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -H "Content-Type: application/json" -d "{\"fileUrl\":\"${DIRECT}\",\"uploadPath\":\"audio-references/test\",\"fileName\":\"test.mp3\"}" "https://sunoapiorg.redpandaai.co/api/file-url-upload"
echo ""
rm -f /tmp/big.mp3
