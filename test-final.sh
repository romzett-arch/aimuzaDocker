#!/bin/sh
echo "=== curl version ==="
curl --version | head -1
echo "=== 5MB upload to Suno ==="
dd if=/dev/urandom bs=1024 count=5000 of=/tmp/final.mp3 2>/dev/null
curl -sS --http1.1 --max-time 120 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/final.mp3;type=audio/mpeg;filename=test.mp3" -F "uploadPath=test" -F "fileName=test.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
rm -f /tmp/final.mp3
