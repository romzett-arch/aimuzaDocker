#!/bin/sh
echo "=== 50KB to httpbin.org ==="
dd if=/dev/urandom bs=1024 count=50 of=/tmp/n50k.bin 2>/dev/null
curl -sS --max-time 30 -o /dev/null -w "HTTP %{http_code}, size_upload: %{size_upload}" -F "file=@/tmp/n50k.bin" "https://httpbin.org/post"
echo ""
echo "=== 1MB to httpbin.org ==="
dd if=/dev/urandom bs=1024 count=1024 of=/tmp/n1m.bin 2>/dev/null
curl -sS --max-time 60 -o /dev/null -w "HTTP %{http_code}, size_upload: %{size_upload}" -F "file=@/tmp/n1m.bin" "https://httpbin.org/post"
echo ""
echo "=== 50KB to file.io ==="
curl -sS --max-time 30 -F "file=@/tmp/n50k.bin" "https://file.io"
echo ""
rm -f /tmp/n50k.bin /tmp/n1m.bin
