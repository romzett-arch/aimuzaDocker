// Cache-Control для публичных объектов хранилища (GET /storage/v1/object/public/).
// tracks/audio/* и tracks/covers/* write-once: имя файла = id трека, suno-callback
// не перезаписывает существующие файлы, мастеринг пишет в gold-packs/. Годовой
// immutable убирает 304-ревалидацию и перекачку mp3 и обложек в приложении
// после простоя. wav/ может перезаписываться (upsert в wav-callback), а HTML
// (сертификаты) не кэшируется вовсе — им остаётся прежнее поведение.
export function publicCacheControl(bucket, filePath, ext) {
  if (ext === '.html') return 'no-store, max-age=0';
  const immutable = bucket === 'tracks'
    && (filePath.startsWith('audio/') || filePath.startsWith('covers/'));
  return immutable ? 'public, max-age=31536000, immutable' : 'public, max-age=86400';
}
