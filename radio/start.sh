#!/bin/bash
set -e

echo "═══════════════════════════════════════════"
echo " AIMUZA Radio Engine v3.0"
echo " Icecast + Liquidsoap + Node.js Controller"
echo "═══════════════════════════════════════════"

# Replace placeholders in icecast.xml with ENV values
sed -i "s|ICECAST_SOURCE_PASS_PLACEHOLDER|${ICECAST_SOURCE_PASS:-hackme}|g" /app/icecast/icecast.xml
sed -i "s|ICECAST_ADMIN_PASS_PLACEHOLDER|${ICECAST_ADMIN_PASS:-admin123}|g" /app/icecast/icecast.xml

# Create directories
mkdir -p /var/log/icecast /var/log/liquidsoap /tmp
# Icecast2 needs write access to logdir (runs as icecast2:icecast after changeowner)
chown -R icecast2:icecast /var/log/icecast 2>/dev/null || chmod -R 777 /var/log/icecast

# Generate empty playlist if not exists
if [ ! -f /tmp/radio_playlist.m3u ]; then
  echo "#EXTM3U" > /tmp/radio_playlist.m3u
fi

# Generate silence fallback for Icecast (30s — prevents EOF reconnect loops when Liquidsoap down)
if [ ! -f /usr/share/icecast2/web/silence.mp3 ]; then
  ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 30 -q:a 9 \
    /usr/share/icecast2/web/silence.mp3 2>/dev/null || true
fi

echo "[Start] Launching via supervisord..."
exec /usr/bin/supervisord -c /app/supervisord.conf
