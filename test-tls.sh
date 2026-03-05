#!/bin/sh
echo "=== Test 1: 1MB with --tlsv1.2 ==="
dd if=/dev/urandom bs=1024 count=1024 of=/tmp/test1m.mp3 2>/dev/null
curl -sS --http1.1 --tlsv1.2 --max-time 120 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/test1m.mp3;type=audio/mpeg;filename=test.mp3" -F "uploadPath=test" -F "fileName=test.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
echo "=== Test 2: 1MB without tls flags ==="
curl -sS --max-time 120 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/test1m.mp3;type=audio/mpeg;filename=test.mp3" -F "uploadPath=test" -F "fileName=test.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
echo "=== Test 3: 100KB ==="
dd if=/dev/urandom bs=1024 count=100 of=/tmp/test100k.mp3 2>/dev/null
curl -sS --max-time 120 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/test100k.mp3;type=audio/mpeg;filename=test.mp3" -F "uploadPath=test" -F "fileName=test.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
rm -f /tmp/test1m.mp3 /tmp/test100k.mp3
