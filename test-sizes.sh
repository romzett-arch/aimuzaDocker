#!/bin/sh
echo "=== 5 bytes ==="
echo "test" > /tmp/t5.mp3
curl -sS --max-time 60 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/t5.mp3;type=audio/mpeg;filename=t.mp3" -F "uploadPath=test" -F "fileName=t.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
echo "=== 10KB ==="
dd if=/dev/urandom bs=1024 count=10 of=/tmp/t10k.mp3 2>/dev/null
curl -sS --max-time 60 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/t10k.mp3;type=audio/mpeg;filename=t.mp3" -F "uploadPath=test" -F "fileName=t.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
echo "=== 50KB ==="
dd if=/dev/urandom bs=1024 count=50 of=/tmp/t50k.mp3 2>/dev/null
curl -sS --max-time 60 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/t50k.mp3;type=audio/mpeg;filename=t.mp3" -F "uploadPath=test" -F "fileName=t.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
echo "=== 50KB with retry ==="
curl -sS --retry 3 --retry-all-errors --max-time 60 -X POST -H "Authorization: Bearer ${SUNO_API_KEY}" -F "file=@/tmp/t50k.mp3;type=audio/mpeg;filename=t.mp3" -F "uploadPath=test" -F "fileName=t.mp3" "https://sunoapiorg.redpandaai.co/api/file-stream-upload"
echo ""
rm -f /tmp/t5.mp3 /tmp/t10k.mp3 /tmp/t50k.mp3
