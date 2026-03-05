#!/bin/sh
dd if=/dev/urandom bs=1024 count=50 of=/tmp/quick.mp3 2>/dev/null
curl -sS --http1.1 --max-time 60 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/quick.mp3;type=audio/mpeg;filename=test.mp3" -F "uploadPath=test" -F "fileName=test.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
rm -f /tmp/quick.mp3
