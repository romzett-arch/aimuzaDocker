#!/usr/bin/liquidsoap

# AI Planet Radio — Liquidsoap 2.1.x Configuration

# ─── Settings ──────────────────────────────────────

set("init.allow_root", true)
set("server.telnet", true)
set("server.telnet.bind_addr", "127.0.0.1")
set("server.telnet.port", 1234)

set("log.file.path", "/var/log/liquidsoap/radio.log")
set("log.level", 3)

# ─── Sources ───────────────────────────────────────

main = playlist(
  id="main",
  mode="normal",
  reload_mode="watch",
  reload=10,
  mime_type="audio/x-mpegurl",
  "/tmp/radio_playlist.m3u"
)

priority = request.queue(id="priority")

silence = blank(id="silence", duration=30.0)

# ─── Processing ────────────────────────────────────

# Priority tracks override main playlist; silence is last-resort fallback
combined = fallback(
  track_sensitive=true,
  [priority, main, silence]
)

radio = crossfade(
  duration=3.0,
  fade_out=2.0,
  fade_in=1.5,
  combined
)

# mksafe guarantees continuous output even if all sources fail
radio = mksafe(radio)
radio = normalize(radio)

# ─── Metadata Notification ─────────────────────────

icecast_source_pass = getenv("ICECAST_SOURCE_PASS")
source_pass = if icecast_source_pass == "" then "changeme" else icecast_source_pass end

def on_track_change(m)
  title = m["title"]
  artist = m["artist"]
  track_id = m["track_id"]
  cover_url = m["cover_url"]
  dur = m["duration"]

  data = '{"title":"#{title}","artist":"#{artist}","track_id":"#{track_id}","cover_url":"#{cover_url}","duration":"#{dur}"}'

  log("Track changed: #{title} — #{artist}")

  ignore(
    http.post(
      data=data,
      headers=[("Content-Type", "application/json")],
      "http://127.0.0.1:3200/api/internal/track-changed"
    )
  )
end

radio.on_metadata(on_track_change)

# ─── Output to Icecast ─────────────────────────────

output.icecast(
  %mp3(bitrate=128, samplerate=44100, stereo=true),
  host="127.0.0.1",
  port=8000,
  password=source_pass,
  mount="/radio.mp3",
  name="AI Planet Radio",
  description="Smart Stream — AI Generated Music",
  genre="Electronic AI",
  url="https://aimuza.ru/radio",
  public=false,
  radio
)

output.icecast(
  %ogg(%opus(bitrate=64, samplerate=48000, channels=2, signal="music")),
  host="127.0.0.1",
  port=8000,
  password=source_pass,
  mount="/radio.opus",
  name="AI Planet Radio (Opus)",
  radio
)
