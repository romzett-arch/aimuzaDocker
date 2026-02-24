/**
 * Edge Functions proxy — проксирование в Deno-сервер
 * POST /functions/v1/:name
 */
import { Router } from 'express';

const router = Router();

const DENO_URL = process.env.DENO_FUNCTIONS_URL || 'http://deno-functions:8081';

router.all('/:name', async (req, res) => {
  try {
    const name = req.params.name;
    const qs = req.originalUrl.split('?')[1];
    const targetUrl = `${DENO_URL}/${name}${qs ? '?' + qs : ''}`;

    // Проксируем запрос в Deno
    const headers = {
      'Content-Type': req.headers['content-type'] || 'application/json',
    };

    // Прокидываем авторизацию
    if (req.headers.authorization) {
      headers['Authorization'] = req.headers.authorization;
    }

    const fetchOptions = {
      method: req.method,
      headers,
    };

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      fetchOptions.body = JSON.stringify(req.body);
    }

    const response = await fetch(targetUrl, fetchOptions);
    const contentType = response.headers.get('content-type') || '';

    res.status(response.status);

    // Forward important headers from Deno response
    const fwdHeaders = ['content-disposition', 'cache-control', 'x-request-id'];
    for (const h of fwdHeaders) {
      const v = response.headers.get(h);
      if (v) res.set(h, v);
    }

    if (contentType.includes('application/json')) {
      const data = await response.json();
      res.json(data);
    } else if (contentType.includes('audio/') || contentType.includes('application/octet-stream') || contentType.includes('audio/wav')) {
      const buf = Buffer.from(await response.arrayBuffer());
      res.set('Content-Type', contentType);
      res.set('Content-Length', String(buf.length));
      res.end(buf);
    } else {
      const text = await response.text();
      res.set('Content-Type', contentType);
      res.send(text);
    }
  } catch (err) {
    console.error('[Functions Proxy]', err.message);
    res.status(502).json({ error: 'Edge function unavailable', detail: err.message });
  }
});

export default router;
