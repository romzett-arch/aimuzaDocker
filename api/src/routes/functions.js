/**
 * Edge Functions proxy — проксирование в Deno-сервер
 * POST /functions/v1/:name
 * 
 * ВАЖНО: Прокидываем query-параметры и заголовки целиком,
 * иначе callback от внешних сервисов (Suno и др.) теряет ?secret= и отклоняется.
 */
import { Router } from 'express';

const router = Router();

const DENO_URL = process.env.DENO_FUNCTIONS_URL || 'http://deno-functions:8081';

router.all('/:name', async (req, res) => {
  try {
    const name = req.params.name;

    // CRITICAL: Сохраняем query string при проксировании
    // Без этого Suno callback ?secret=... терялся и Deno отклонял запрос
    const queryString = req.url.includes('?') ? req.url.substring(req.url.indexOf('?')) : '';
    const targetUrl = `${DENO_URL}/${name}${queryString}`;

    // Проксируем запрос в Deno — прокидываем все значимые заголовки
    const headers = {
      'Content-Type': req.headers['content-type'] || 'application/json',
    };

    // Прокидываем авторизацию
    if (req.headers.authorization) {
      headers['Authorization'] = req.headers.authorization;
    }

    // Прокидываем кастомные заголовки callback-ов
    const headersToForward = [
      'x-callback-secret',
      'x-client-info',
      'apikey',
      'x-supabase-client-platform',
      'x-supabase-client-platform-version',
      'x-supabase-client-runtime',
      'x-supabase-client-runtime-version',
    ];
    for (const h of headersToForward) {
      if (req.headers[h]) {
        headers[h] = req.headers[h];
      }
    }

    const fetchOptions = {
      method: req.method,
      headers,
    };

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      fetchOptions.body = JSON.stringify(req.body);
    }

    console.log(`[Functions Proxy] ${req.method} ${targetUrl}`);

    const response = await fetch(targetUrl, fetchOptions);
    const contentType = response.headers.get('content-type') || '';

    // Прокидываем статус и CORS-заголовки из Deno
    res.status(response.status);
    const corsHeaderNames = [
      'access-control-allow-origin',
      'access-control-allow-headers',
      'access-control-allow-methods',
    ];
    for (const h of corsHeaderNames) {
      const val = response.headers.get(h);
      if (val) res.set(h, val);
    }

    if (contentType.includes('application/json')) {
      const data = await response.json();
      res.json(data);
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
