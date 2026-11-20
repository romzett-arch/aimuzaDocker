import { pool } from '../db.js';
import { signToken } from '../middleware/auth.js';
import { getImageJob, imageHistory } from './image-generation.js';

export const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(value);
const port = Number(process.env.API_PORT || '3000');
const kinds = new Set(['music', 'image', 'lyrics']);

export class ChatActionError extends Error {
  constructor(code, status = 400) {
    super(code);
    this.status = status;
  }
}

async function existingApi(account, path, input) {
  const token = signToken({ ...account, session_origin: 'max' });
  const response = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(input),
    redirect: 'error',
    signal: AbortSignal.timeout(140_000),
  });
  const isJson = response.headers.get('content-type')?.includes('application/json');
  const data = isJson ? await response.json() : null;
  if (!response.ok || data?.problem) {
    await response.body?.cancel().catch(() => {});
    throw new ChatActionError(data?.code || data?.problem || 'ACTION_FAILED', response.status >= 400 ? response.status : 422);
  }
  return data ?? response;
}

async function profile(account) {
  const [balance, prices] = await Promise.all([
    pool.query('SELECT balance FROM public.profiles WHERE user_id=$1', [account.id]),
    pool.query("SELECT name,price_rub FROM public.addon_services WHERE name IN ('generate_music_v6','generate_image','generate_lyrics') AND is_active"),
  ]);
  const price = name => Number(prices.rows.find(row => row.name === name)?.price_rub || 0);
  return {
    ownerId: account.id,
    mode: account.mode,
    siteLinked: account.siteLinked,
    balance: Number(balance.rows[0]?.balance || 0),
    music: price('generate_music_v6'),
    image: price('generate_image'),
    lyrics: price('generate_lyrics'),
  };
}

async function start(account, { kind, id, prompt, price, lyricsId }) {
  if (!uuid(id) || !kinds.has(kind) || typeof prompt !== 'string' || !prompt.trim() ||
      prompt.length > (kind === 'lyrics' ? 200 : 1000) || !Number.isSafeInteger(price) || price < 1) {
    throw new ChatActionError('BAD_INPUT');
  }
  if (kind === 'music') {
    const prior = await pool.query('SELECT 1 FROM public.generation_logs WHERE user_id=$1 AND request_id=$2 LIMIT 1', [account.id,id]);
    if (!prior.rowCount && (await profile(account)).music !== price) throw new ChatActionError('PRICE_CHANGED');
    if (prior.rowCount) return { accepted: true };
    const input = {
      requestId: id, mode: 'simple', title: prompt.trim().slice(0,60), prompt: prompt.trim(),
    };
    if (lyricsId !== undefined) {
      const song = await lyric(account, { id: lyricsId });
      Object.assign(input, { mode: 'custom', title: song.title?.trim().slice(0,100) || 'Новая песня', lyrics: song.lyrics.slice(0,5000), style: prompt.trim() });
    }
    await existingApi(account, '/studio/v1/generations', input);
  } else if (kind === 'image') {
    const prior = await getImageJob(account.id,id);
    if (!prior) await existingApi(account, '/functions/v1/generate-image', {
      action:'generate', id, prompt:prompt.trim(), ratio:'1:1', resolution:'2K', price,
    });
  } else await existingApi(account, '/functions/v1/generate-lyrics', { prompt: prompt.trim(), requestId: id, expectedPrice: price });
  return { accepted: true };
}

async function musicStatus(account, id) {
  const load = () => pool.query(
    `SELECT t.id,t.title,t.status,t.audio_url,t.audio_url IS NOT NULL AS ready,l.generation_params->>'task_id' AS task
     FROM public.generation_logs l JOIN public.tracks t ON t.id=l.track_id
     WHERE l.user_id=$1 AND t.user_id=$1 AND l.request_id=$2 ORDER BY l.created_at,t.id`, [account.id,id],
  );
  let {rows} = await load();
  if (rows.some(item => ['pending','processing'].includes(item.status))) {
    const taskId = rows.find(row => row.task)?.task;
    if (taskId) await existingApi(account, '/functions/v1/suno-check-status', {taskId}).catch(() => {});
    ({rows}=await load());
  }
  return {
    pending: rows.some(item => ['pending','processing'].includes(item.status)),
    items: rows.filter(item => item.status==='completed' && item.ready).map(({id,title,audio_url}) => ({id,title,audioUrl:audio_url})),
  };
}

async function works(account, { kind, page = 0 }) {
  // The previous bot can run until its separate MAX deployment.
  if (kind === undefined) {
    const [music, images] = await Promise.all([works(account, { kind: 'music' }), works(account, { kind: 'image' })]);
    return { music: music.items, images: images.items };
  }
  if (!kinds.has(kind) || !Number.isSafeInteger(page) || page < 0 || page > 100000) throw new ChatActionError('BAD_INPUT');
  const offset = page * 5;
  let entries;
  if (kind === 'image') {
    entries = (await imageHistory(account.id, 6, offset)).map(({ id, prompt, status }) => ({
      id, title: prompt, status, ready: status === 'completed',
    }));
  } else {
    const query = kind === 'music'
      ? "SELECT id,title,status,audio_url IS NOT NULL AND status='completed' AS ready,audio_url FROM public.tracks WHERE user_id=$1"
      : "SELECT id,title,'completed' AS status,true AS ready,NULL::text AS audio_url FROM public.generated_lyrics WHERE user_id=$1 AND NULLIF(lyrics,'') IS NOT NULL";
    entries = (await pool.query(`${query} ORDER BY created_at DESC,id DESC LIMIT 6 OFFSET $2`, [account.id, offset])).rows
      .map(({audio_url, ...item}) => ({...item, audioUrl: item.ready ? audio_url : undefined}));
  }
  return { items: entries.slice(0, 5), more: entries.length > 5 };
}

async function lyric(account, { id }) {
  if (!uuid(id)) throw new ChatActionError('BAD_INPUT');
  const { rows: [item] } = await pool.query(
    "SELECT id,title,lyrics FROM public.generated_lyrics WHERE user_id=$1 AND id=$2 AND NULLIF(lyrics,'') IS NOT NULL",
    [account.id, id],
  );
  if (!item) throw new ChatActionError('NOT_FOUND', 404);
  return item;
}

async function lyricsStatus(account, id) {
  const { rows: [job] } = await pool.query(
    'SELECT status FROM public.lyrics_generation_jobs WHERE user_id=$1 AND id=$2', [account.id, id],
  );
  if (job?.status !== 'completed') return { pending: job?.status === 'pending', items: [] };
  const { rows: items } = await pool.query(
    "SELECT id,title FROM public.generated_lyrics WHERE user_id=$1 AND job_id=$2 AND NULLIF(lyrics,'') IS NOT NULL ORDER BY created_at,id",
    [account.id, id],
  );
  return { pending: false, items };
}

async function media(account, {id,kind}, res) {
  if (!uuid(id) || !['image','music'].includes(kind)) throw new ChatActionError('BAD_INPUT');
  if (kind==='image') {
    const image = await existingApi(account, '/functions/v1/generate-image', {action:'image',id});
    return res.type(image.mime_type).send(Buffer.from(image.image,'base64'));
  }
  const owns = await pool.query("SELECT 1 FROM public.tracks WHERE id=$1 AND user_id=$2 AND status='completed'",[id,account.id]);
  if (!owns.rowCount) throw new ChatActionError('NOT_FOUND',404);
  const file = await existingApi(account, '/functions/v1/download-track', {track_id:id, stream:true});
  if (!(file instanceof Response)) throw new ChatActionError('MEDIA_UNAVAILABLE',502);
  const buffer = Buffer.from(await file.arrayBuffer());
  if (buffer.length > 32 * 1024 * 1024) throw new ChatActionError('MEDIA_UNAVAILABLE',422);
  return res.type('audio/mpeg').send(buffer);
}

export const actions = {
  profile, start, works, media, lyric,
  async status(account,{id,kind}) {
    if (!uuid(id) || !kinds.has(kind)) throw new ChatActionError('BAD_INPUT');
    if (kind==='music') return musicStatus(account,id);
    if (kind==='lyrics') return lyricsStatus(account,id);
    const image = await getImageJob(account.id,id);
    return { pending:image?.status==='pending', items:image?.status==='completed' ? [{id,title:'Картинка готова'}] : [] };
  },
  async payment(account,{amount}) {
    if (!Number.isSafeInteger(amount) || amount < 10 || amount > 150000) throw new ChatActionError('BAD_AMOUNT');
    const payment = await existingApi(account,'/functions/v1/robokassa-create',{amount,payment_method:'all'});
    const url = new URL(payment.payment_url);
    if (url.origin!=='https://auth.robokassa.ru' || url.pathname!=='/Merchant/Index.aspx') throw new ChatActionError('ACTION_FAILED');
    return {url:url.href};
  },
};
