#!/bin/sh
echo "=== Downloading static curl ==="
curl -sS -L "https://github.com/moparisthebest/static-curl/releases/latest/download/curl-amd64" -o /tmp/curl-static
chmod +x /tmp/curl-static
echo "=== Static curl version ==="
/tmp/curl-static --version | head -1
echo "=== Test 50KB upload with static curl ==="
dd if=/dev/urandom bs=1024 count=50 of=/tmp/quick.mp3 2>/dev/null
/tmp/curl-static -sS --max-time 60 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/quick.mp3;type=audio/mpeg;filename=test.mp3" -F "uploadPath=test" -F "fileName=test.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
echo "=== Test 5MB upload with static curl ==="
dd if=/dev/urandom bs=1024 count=5000 of=/tmp/big.mp3 2>/dev/null
/tmp/curl-static -sS --max-time 120 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/big.mp3;type=audio/mpeg;filename=test.mp3" -F "uploadPath=test" -F "fileName=test.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
rm -f /tmp/quick.mp3 /tmp/big.mp3
