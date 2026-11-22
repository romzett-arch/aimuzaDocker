import Busboy from 'busboy';

// Multipart-парсер storage-роута, толерантный к частям с ПУСТЫМ именем поля.
//
// Зачем: supabase-js >= 2.9.x при storage.upload собирает FormData так:
//   body.append('cacheControl', ...); body.append('', fileBlob);
// — файл идёт с пустым именем поля (настоящий Supabase Storage это принимает).
// Multer на такое падает с MISSING_FIELD_NAME прямо в middleware, и запрос
// умирает 500 ещё до обработчика роута. Этот парсер собирает файл независимо
// от имени поля и текстовые части — в req.body, форма данных совместима
// с прежним multer.any(): req.files = [{ fieldname, originalname, mimetype, buffer, size }].

const MAX_FILE_SIZE = 100 * 1024 * 1024; // как прежний multer limits.fileSize
const MAX_FIELDS = 10;

export function parseStorageUpload(req, res, next) {
  const contentType = req.headers['content-type'] || '';
  if (!contentType.startsWith('multipart/form-data')) {
    // Raw body (не multipart) идёт через express.raw — пропускаем как раньше.
    return next();
  }

  let busboy;
  try {
    busboy = Busboy({
      headers: req.headers,
      limits: { fileSize: MAX_FILE_SIZE, files: 1, fields: MAX_FIELDS },
    });
  } catch {
    return res.status(400).json({ error: 'Invalid multipart request' });
  }

  const files = [];
  const body = {};
  let settled = false;
  let fileLimitHit = false;

  const finish = () => {
    if (settled) return;
    settled = true;
    req.files = files;
    Object.assign(req.body ?? {}, body);
    next();
  };

  busboy.on('file', (name, stream, info) => {
    const chunks = [];
    stream.on('data', (chunk) => chunks.push(chunk));
    stream.on('limit', () => {
      fileLimitHit = true;
    });
    stream.on('end', () => {
      const buffer = Buffer.concat(chunks);
      files.push({
        fieldname: name || 'file',
        originalname: info.filename,
        mimetype: info.mimeType,
        buffer,
        size: buffer.length,
      });
    });
  });

  busboy.on('field', (name, value) => {
    if (body[name] === undefined) body[name] = value;
  });

  busboy.on('error', (err) => {
    if (settled) return;
    settled = true;
    next(err);
  });

  busboy.on('close', () => {
    if (settled) return;
    if (fileLimitHit) {
      settled = true;
      return res.status(413).json({ error: 'File too large' });
    }
    finish();
  });

  req.pipe(busboy);
}
