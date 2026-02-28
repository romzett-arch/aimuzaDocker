/**
 * Edge Functions proxy — проксирование в Deno-сервер
 * POST /functions/v1/:name
 */
import { Router } from 'express';

const router = Router();

const DENO_URL = process.env.DENO_FUNCTIONS_URL || 'http://deno-functions:8081';

const ALLOWED_FUNCTIONS = new Set([
  'admin-create-user', 'admin-delete-user', 'admin-impersonate', 'admin-recheck-track',
  'ad-targeting', 'aggregate-votes', 'analyze-audio', 'analyze-lyrics',
  'approve-distribution', 'audio-separation', 'boost-style', 'check-plagiarism',
  'classify-audio', 'cleanup-wav', 'convert-to-wav', 'create-persona', 'db-admin',
  'deepseek-lyrics', 'distribution-check', 'download-track', 'export-database',
  'forum-ai-helper', 'forum-analyze-report', 'forum-automod', 'forum-sitemap',
  'generate-ai-cover', 'generate-gold-pack', 'generate-hd-cover', 'generate-lyrics',
  'generate-promo-video', 'generate-ringtone', 'generate-short-video',
  'get-timestamped-lyrics', 'indexnow-notify', 'lyrics-callback', 'lyrics-deposit',
  'maintenance-status', 'normalize-audio', 'og-renderer', 'process-master-audio',
  'promo-video-callback', 'request-distribution', 'resolve-voting',
  'robokassa-callback', 'robokassa-create', 'robots-txt', 'send-admin-email',
  'send-auth-email', 'seo-ai-generate', 'sitemap-generator', 'submit-to-distributor',
  'suno-callback', 'suno-check-status', 'suno-credits', 'suno-generate',
  'suno-video-callback', 'support-categorize', 'support-suggest-reply',
  'track-deposit', 'track-metadata', 'update-chart', 'update-voter-ranks',
  'upload-add-vocal', 'upload-audio-reference', 'upload-cover', 'verify-email-code',
  'wav-callback', 'yookassa-callback', 'yookassa-create',
]);

router.all('/:name', async (req, res) => {
  try {
    const name = req.params.name;

    if (!/^[a-z][a-z0-9-]{1,60}$/.test(name) || !ALLOWED_FUNCTIONS.has(name)) {
      return res.status(404).json({ error: 'Function not found' });
    }

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
      fetchOptions.body = Buffer.isBuffer(req.body) ? req.body : JSON.stringify(req.body);
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
    console.error('[Functions Proxy]', req.params?.name, err.message);
    res.status(502).json({ error: 'Edge function unavailable' });
  }
});

export default router;
