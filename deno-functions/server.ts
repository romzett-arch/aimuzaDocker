/**
 * Deno HTTP Server — хостит все Supabase Edge Functions как HTTP endpoints
 * 
 * Supabase Edge Functions используют serve() из deno/std, который внутри
 * вызывает Deno.listen() + Deno.serveHttp(). Мы перехватываем оба,
 * чтобы захватить обработчик и не стартовать отдельный сервер для каждой функции.
 */

const PORT = parseInt(Deno.env.get("DENO_PORT") || "8081");
const FUNCTIONS_DIR = "./functions";

// ─── Polyfill: auth.getClaims() ─────────────────────────────────────
// Множество Deno-функций используют supabaseClient.auth.getClaims(token),
// но этот метод НЕ существует в @supabase/supabase-js@2.
// Добавляем его как клиентский JWT-декодер (проверка уже на стороне API-сервера).
try {
  const { createClient } = await import("https://esm.sh/@supabase/supabase-js@2");
  const _tmpClient = createClient("http://localhost:9999", "polyfill-key");
  const authProto = Object.getPrototypeOf(_tmpClient.auth);
  if (authProto && typeof authProto.getClaims !== 'function') {
    authProto.getClaims = async function(_token?: string) {
      try {
        // Если передан токен — декодируем его; иначе пробуем getUser()
        const token = _token || this._getSessionToken?.();
        if (!token || typeof token !== 'string') {
          return { data: null, error: new Error("No token provided") };
        }
        // Декодируем JWT payload (base64url → JSON)
        const parts = token.split('.');
        if (parts.length !== 3) {
          return { data: null, error: new Error("Invalid token format") };
        }
        const base64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
        const jsonStr = atob(base64);
        const payload = JSON.parse(jsonStr);
        return { data: { claims: payload }, error: null };
      } catch (err) {
        return { data: null, error: err };
      }
    };
    console.log("[Deno] Polyfill: auth.getClaims() installed");
  }
} catch (e) {
  console.warn("[Deno] Polyfill getClaims failed:", e);
}

// Хранилище обработчиков
const handlers = new Map<string, (req: Request) => Promise<Response> | Response>();

// Текущее имя функции при загрузке
let _currentLoadingName: string | null = null;

// ─── Перехватываем Deno.serve ──────────────────────────────────────
const _originalServe = Deno.serve;

// @ts-ignore: override  
Deno.serve = function(optionsOrHandler: any, maybeHandler?: any) {
  let handler: ((req: Request) => Promise<Response> | Response) | undefined;
  
  if (typeof optionsOrHandler === 'function') {
    handler = optionsOrHandler;
  } else if (typeof maybeHandler === 'function') {
    handler = maybeHandler;
  } else if (optionsOrHandler && typeof optionsOrHandler.handler === 'function') {
    handler = optionsOrHandler.handler;
  }

  if (handler && _currentLoadingName) {
    handlers.set(_currentLoadingName, handler);
  }
  
  // Mock Deno.Server object
  return { 
    finished: Promise.resolve(), 
    ref: () => {}, 
    unref: () => {}, 
    shutdown: () => Promise.resolve(),
    addr: { transport: "tcp" as const, hostname: "0.0.0.0", port: 0 },
  };
};

// ─── Перехватываем Deno.listen (для старой serve() из deno/std) ────
const _originalListen = Deno.listen;

// @ts-ignore: override
Deno.listen = function(options: any) {
  if (_currentLoadingName) {
    // Не запускаем реальный listener — возвращаем mock
    return {
      addr: { transport: "tcp", hostname: options?.hostname || "0.0.0.0", port: options?.port || 0 },
      rid: -1,
      close: () => {},
      [Symbol.asyncIterator]: async function*() { /* noop */ },
      ref: () => {},
      unref: () => {},
      accept: () => new Promise(() => {}), // never resolves
    };
  }
  return _originalListen.call(Deno, options);
};

// ─── Перехватываем Deno.serveHttp (для старой serve()) ─────────────
const _originalServeHttp = (Deno as any).serveHttp;

// @ts-ignore: override
(Deno as any).serveHttp = function(conn: any) {
  if (_currentLoadingName) {
    // Mock httpConn
    return {
      rid: -1,
      close: () => {},
      nextRequest: () => Promise.resolve(null),
      [Symbol.asyncIterator]: async function*() { /* noop */ },
    };
  }
  return _originalServeHttp?.call(Deno, conn);
};

// ─── Загрузка функций ──────────────────────────────────────────────
async function loadFunctions() {
  for await (const entry of Deno.readDir(FUNCTIONS_DIR)) {
    if (!entry.isDirectory) continue;
    
    const indexPath = `${FUNCTIONS_DIR}/${entry.name}/index.ts`;
    try {
      await Deno.stat(indexPath);
    } catch {
      continue; // нет index.ts
    }

    _currentLoadingName = entry.name;
    
    try {
      const mod = await import(`./${indexPath}`);
      
      // Если handler не захвачен через serve/Deno.serve, проверяем default export
      if (!handlers.has(entry.name) && typeof mod.default === 'function') {
        handlers.set(entry.name, mod.default);
      }
      
      // Если всё ещё нет — попробуем обработать serve() вызов
      // serve() из deno/std передаёт handler в первый аргумент
      // Наш перехват Deno.listen + mock уже должен был предотвратить краш
      
    } catch (err) {
      // Логируем но не крашимся
      const msg = err instanceof Error ? err.message : String(err);
      // Игнорируем ошибки адреса (уже обработаны моком)
      if (!msg.includes('AddrInUse') && !msg.includes('Address already')) {
        console.error(`[Deno] Error loading ${entry.name}: ${msg}`);
      }
    }
    
    _currentLoadingName = null;
    
    if (handlers.has(entry.name)) {
      console.log(`[Deno] Loaded: ${entry.name}`);
    }
  }
}

// Перехватываем serve из deno/std — она экспортируется как именованная функция
// и принимает handler как первый аргумент. Но мы не можем перехватить импорт.
// Вместо этого мы перехватываем Deno.listen + Deno.serveHttp
// и для serve()-based функций вручную парсим их handler из исходника.

/**
 * Fallback: для функций которые используют serve() из deno/std
 * и не были захвачены — создаём обработчик который парсит запрос 
 * и проксирует его
 */
async function loadServeBasedFunctions() {
  for await (const entry of Deno.readDir(FUNCTIONS_DIR)) {
    if (!entry.isDirectory || handlers.has(entry.name)) continue;

    const indexPath = `${FUNCTIONS_DIR}/${entry.name}/index.ts`;
    try {
      const code = await Deno.readTextFile(indexPath);
      
      // Проверяем есть ли serve(async (req) => { ... }) паттерн
      if (code.includes('serve(async') || code.includes('serve(function')) {
        // Извлекаем handler из serve() вызова
        // Для этого динамически создаём модифицированный код
        const modifiedCode = code
          // Заменяем import serve на наш стаб
          .replace(
            /import\s*\{\s*serve\s*\}\s*from\s*"https:\/\/deno\.land\/std[^"]*\/http\/server\.ts"/g,
            `const serve = (handler: any) => { (globalThis as any).__capturedHandler = handler; }`
          );
        
        // Создаём temp файл с модифицированным кодом
        const tmpPath = `/tmp/_fn_${entry.name}.ts`;
        await Deno.writeTextFile(tmpPath, modifiedCode);
        
        try {
          (globalThis as any).__capturedHandler = null;
          await import(tmpPath);
          
          const captured = (globalThis as any).__capturedHandler;
          if (typeof captured === 'function') {
            handlers.set(entry.name, captured);
            console.log(`[Deno] Loaded (serve-compat): ${entry.name}`);
          }
        } catch (loadErr) {
          // Не критично — функция может требовать специфичные зависимости
          const msg = loadErr instanceof Error ? loadErr.message : String(loadErr);
          if (!msg.includes('AddrInUse') && !msg.includes('already')) {
            console.warn(`[Deno] Skipped ${entry.name}: ${msg.substring(0, 80)}`);
          }
        }
      }
    } catch {
      // Файл не найден или ошибка чтения
    }
  }
}

await loadFunctions();
await loadServeBasedFunctions();

console.log(`[Deno] ${handlers.size} functions ready`);

// ─── Запускаем единый HTTP-сервер ──────────────────────────────────
_originalServe.call(Deno, { port: PORT, hostname: "0.0.0.0" }, async (req: Request) => {
  const url = new URL(req.url);
  const pathParts = url.pathname.split('/').filter(Boolean);
  const functionName = pathParts[0];

  // Health check
  if (functionName === 'health' || !functionName) {
    return new Response(JSON.stringify({ 
      status: 'ok', 
      functions: handlers.size,
      loaded: [...handlers.keys()],
    }), {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Authorization, Content-Type, apikey, x-client-info, x-supabase-client-platform, x-supabase-client-platform-version',
      },
    });
  }

  const handler = handlers.get(functionName);
  if (!handler) {
    // Для незагруженных функций: вернём заглушку вместо 404
    return new Response(JSON.stringify({ error: `Function '${functionName}' not available` }), {
      status: 501,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
  }

  try {
    const response = await handler(req);
    const headers = new Headers(response.headers);
    headers.set('Access-Control-Allow-Origin', '*');
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  } catch (err) {
    console.error(`[Deno] Error in ${functionName}:`, err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
  }
});
