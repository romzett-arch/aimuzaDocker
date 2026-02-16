#!/bin/sh
# Download track audio and covers from Suno CDN to local storage

UPLOADS="/opt/aimuza/data/uploads"
mkdir -p "$UPLOADS/tracks/audio" "$UPLOADS/tracks/covers"

# Track 1: 7ff67760 (Черновик 2 v1, batch 1)
echo "Downloading track 7ff67760..."
wget -q -O "$UPLOADS/tracks/audio/7ff67760-b0dd-4bf4-904a-1519904337c6.mp3" "https://tempfile.aiquickdraw.com/r/b62e53cda32347619ce8479a4f1f8940.mp3" && echo "  audio OK" || echo "  audio FAIL"
wget -q -O "$UPLOADS/tracks/covers/7ff67760-b0dd-4bf4-904a-1519904337c6.jpg" "https://cdn2.suno.ai/image_c12d6de9-8557-44fe-888a-93e6f6e91f34.jpeg" && echo "  cover OK" || echo "  cover FAIL"

# Track 2: 219028eb (Черновик 2 v2, batch 1)
echo "Downloading track 219028eb..."
wget -q -O "$UPLOADS/tracks/audio/219028eb-1c39-4b20-adf6-66713e2ae742.mp3" "https://tempfile.aiquickdraw.com/r/9841cd3bc396457cbdb185e2277c42da.mp3" && echo "  audio OK" || echo "  audio FAIL"
wget -q -O "$UPLOADS/tracks/covers/219028eb-1c39-4b20-adf6-66713e2ae742.jpg" "https://cdn2.suno.ai/image_82e4ce82-2663-4aa2-9f06-cb3fb345b347.jpeg" && echo "  cover OK" || echo "  cover FAIL"

# Track 3: 205e2d58 (Черновик 2 v1, batch 2)
echo "Downloading track 205e2d58..."
wget -q -O "$UPLOADS/tracks/audio/205e2d58-ac0f-4d46-a007-fdd1bf99cd16.mp3" "https://tempfile.aiquickdraw.com/r/856e9be671de4393898169f204d01698.mp3" && echo "  audio OK" || echo "  audio FAIL"
wget -q -O "$UPLOADS/tracks/covers/205e2d58-ac0f-4d46-a007-fdd1bf99cd16.jpg" "https://cdn2.suno.ai/image_4fccfc14-1b68-45ff-812e-483fbbd26af7.jpeg" && echo "  cover OK" || echo "  cover FAIL"

# Track 4: d59b3344 (Черновик 2 v2, batch 2)
echo "Downloading track d59b3344..."
wget -q -O "$UPLOADS/tracks/audio/d59b3344-5585-40df-be0a-7e6e30ff0277.mp3" "https://tempfile.aiquickdraw.com/r/50e970877b00476ca20be855bbb25ce2.mp3" && echo "  audio OK" || echo "  audio FAIL"
wget -q -O "$UPLOADS/tracks/covers/d59b3344-5585-40df-be0a-7e6e30ff0277.jpg" "https://cdn2.suno.ai/image_b0f59768-e8af-44fb-9e73-2fd797441a1d.jpeg" && echo "  cover OK" || echo "  cover FAIL"

echo "Done! Files:"
ls -la "$UPLOADS/tracks/audio/" "$UPLOADS/tracks/covers/"
