#!/bin/sh
dd if=/dev/urandom bs=1024 count=5000 of=/tmp/bigtest.mp3 2>/dev/null
echo "File size: $(wc -c < /tmp/bigtest.mp3) bytes"
curl -sS --http1.1 --max-time 120 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/bigtest.mp3;type=audio/mpeg;filename=test.mp3" -F "uploadPath=test" -F "fileName=test.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
echo "EXIT: $?"
rm -f /tmp/bigtest.mp3
