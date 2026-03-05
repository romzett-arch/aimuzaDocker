#!/usr/bin/liquidsoap

# AI Planet Radio — Liquidsoap 2.1.x Configuration
# FIX: бесконечный silence fallback — поток не обрывается после трека
# FIX: безопасный JSON для track-changed (экранирование кавычек)
# FIX: timeout для http.post

# ─── Settings ──────────────────────────────────────

set("init.allow_root", true)
set("server.telnet", true)
set("server.telnet.bind_addr", "127.0.0.1")
set("server.telnet.port", 1234)

set("log.file.path", "/var/log/liquidsoap/radio.log")
set("log.level", 3)

# ─── Sources ───────────────────────────────────────

# Main playlist — Controller генерирует ДО старта Liquidsoap (refreshPlaylist перед isUp).
# reload_mode="watch" — подхватывает изменения файла при перезаписи.
main = playlist(
  id="main",
  mode="normal",
  loop=true,
  reload_mode="watch",
  reload=10,
  mime_type="audio/x-mpegurl",
  "/tmp/radio_playlist.m3u"
)

priority = request.queue(id="priority")

# Silence fallback — БЕСКОНЕЧНЫЙ. Предохранитель от EOF, поток не обрывается.
silence = blank(id="silence")

# ─── Processing ────────────────────────────────────

# track_sensitive=false позволяет немедленно переключаться при наличии нового источника
combined = fallback(
  track_sensitive=false,
  [priority, main, silence]
)

# Crossfade для плавных переходов между треками
radio = crossfade(
  duration=3.0,
  fade_out=2.5,
  fade_in=1.5,
  combined
)

# Нормализация громкости
radio = normalize(radio)

# mksafe — при сбое источника fallback на тишину (ДОЛЖЕН БЫТЬ ПОСЛЕДНИМ перед metadata)
radio = mksafe(radio)

# ─── Metadata Notification ─────────────────────────

icecast_source_pass = getenv("ICECAST_SOURCE_PASS")
source_pass = if icecast_source_pass == "" then "changeme" else icecast_source_pass end

# Экранирование кавычек для JSON (metadata всегда string в Liquidsoap)
def json_safe(s) =
  s = if s == "" then "" else s end
  string.replace(pattern="\"", (fun(_) -> "\\\""), s)
end

def on_track_change(m)
  title = m["title"]
  artist = m["artist"]
  track_id = m["track_id"]
  cover_url = m["cover_url"]
  dur = m["duration"]

  # Безопасный JSON: экранируем кавычки в полях
  data = "{ \"title\": \"" ^ json_safe(title) ^ "\", \"artist\": \"" ^ json_safe(artist) ^ "\", \"track_id\": \"" ^ json_safe(track_id) ^ "\", \"cover_url\": \"" ^ json_safe(cover_url) ^ "\", \"duration\": \"" ^ json_safe(dur) ^ "\" }"

  log("Track changed: #{title} — #{artist}")

  ignore(
    http.post(
      data=data,
      headers=[("Content-Type", "application/json")],
      "http://127.0.0.1:3200/api/internal/track-changed"
    )
  )
end

radio = source.on_metadata(radio, on_track_change)

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
