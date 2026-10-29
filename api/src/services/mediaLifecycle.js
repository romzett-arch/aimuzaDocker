import fs from 'node:fs/promises';
import { pool } from '../db.js';
import { DAY, collectKeys, unlinkMedia, walkFiles } from './media-files.js';

const roots = {
  uploads: process.env.UPLOADS_DIR || '/opt/aimuza/data/uploads',
  ffmpeg: process.env.FFMPEG_OUTPUT_DIR || '/opt/aimuza/data/ffmpeg-output',
};
const WAV_COLUMNS = ['wav_url', 'master_audio_url', 'normalized_audio_url'];

export async function loadReferences(client) {
  const { rows } = await client.query('SELECT * FROM public.media_live_references()');
  rows.push(...(await client.query("SELECT 'distribution_requests' AS table_name,id::text AS row_id,track_id::text,metadata AS payload FROM distribution_requests WHERE status NOT IN ('rejected','cancelled','failed')")).rows);
  // Terminal master jobs are historical provenance, not active consumers of source audio.
  const terminalJobs = new Set((await client.query("SELECT id FROM audio_master_jobs WHERE status IN ('completed','failed')")).rows.map(row => row.id));
  const refs = new Map();
  for (const row of rows) {
    if (row.table_name === 'audio_master_jobs' && terminalJobs.has(row.row_id)) continue;
    for (const key of collectKeys(row.payload)) {
      if (!refs.has(key)) refs.set(key, []);
      refs.get(key).push(row);
    }
  }
  return refs;
}

// A live primary playback file, a package, a distribution asset or legal evidence wins over TTL.
export function protectedWav(key, references, tracks) {
  return (references.get(key) || []).some(row => {
    if (['track_addons', 'audio_separations', 'track_health_reports'].includes(row.table_name)) {
      const t = tracks.get(row.track_id);
      return Boolean(t && (t.has_package || t.has_distribution || t.is_release_candidate || !['none', 'rejected', null].includes(t.distribution_status)));
    }
    if (row.table_name !== 'tracks') return true;
    const track = tracks.get(row.row_id);
    return !track || collectKeys(row.payload.audio_url).has(key)
      || track.is_release_candidate || !['none', 'rejected', null].includes(track.distribution_status)
      || track.has_package || track.has_distribution;
  });
}

async function expireWavs(client) {
  const due = await client.query(`SELECT EXISTS(SELECT 1 FROM tracks WHERE wav_expires_at<=now()
    AND (wav_url IS NOT NULL OR master_audio_url LIKE '%.wav' OR normalized_audio_url LIKE '%.wav'))
    OR EXISTS(SELECT 1 FROM track_addons a JOIN addon_services s ON s.id=a.addon_service_id
      WHERE s.name='convert_wav' AND a.status='completed'
      AND COALESCE(NULLIF(a.metadata->>'expires_at','')::timestamptz,a.updated_at+interval '3 days')<=now())
    OR EXISTS(SELECT 1 FROM audio_separations WHERE media_expires_at<=now() AND status='completed' AND result_urls::text LIKE '%.wav%')
    OR EXISTS(SELECT 1 FROM track_health_reports WHERE media_expires_at<=now() AND normalized_audio_url LIKE '%.wav') AS due`);
  if (!due.rows[0].due) return;
  // Serialize against settlement, track deletion, and package/distribution writers.
  await client.query('BEGIN');
  try {
    await client.query("SET LOCAL lock_timeout='3s'");
    await client.query('LOCK TABLE public.tracks, public.track_addons, public.release_packages, public.silk_releases, public.silk_release_assets, public.audio_separations, public.track_health_reports IN SHARE ROW EXCLUSIVE MODE');
    const { rows } = await client.query(`SELECT t.*,
      EXISTS(SELECT 1 FROM release_packages p WHERE p.track_id=t.id AND p.status IN ('processing','completed')) AS has_package,
      (EXISTS(SELECT 1 FROM silk_releases s WHERE s.source_track_id=t.id)
       OR EXISTS(SELECT 1 FROM distribution_requests d WHERE d.track_id=t.id AND d.status NOT IN ('rejected','cancelled','failed'))) AS has_distribution
      FROM tracks t`);
    const tracks = new Map(rows.map(t => [t.id, t]));
    const references = await loadReferences(client);
    const reports = await client.query("SELECT id,track_id,normalized_audio_url FROM track_health_reports WHERE media_expires_at<=now() AND normalized_audio_url LIKE '%.wav'");
    for (const report of reports.rows) {
      const keys = [...collectKeys(report.normalized_audio_url)];
      if (!keys.length || keys.some(key => protectedWav(key, references, tracks))) continue;
      await client.query('INSERT INTO media_cleanup_jobs(track_id,payload) VALUES($1,$2)', [report.track_id, { url: report.normalized_audio_url }]);
      await client.query('UPDATE track_health_reports SET normalized_audio_url=NULL WHERE id=$1', [report.id]);
    }
    const stems = await client.query("SELECT id,track_id,result_urls FROM audio_separations WHERE media_expires_at<=now() AND status='completed' AND result_urls::text LIKE '%.wav%'");
    for (const stem of stems.rows) {
      const urls = { ...stem.result_urls };
      for (const [name, value] of Object.entries(urls)) {
        const keys = [...collectKeys(value)];
        if (!keys.length || keys.some(key => !key.toLowerCase().endsWith('.wav') || protectedWav(key, references, tracks))) continue;
        await client.query('INSERT INTO media_cleanup_jobs(track_id,payload) VALUES($1,$2)', [stem.track_id, { url: value }]);
        delete urls[name];
      }
      if (Object.keys(urls).length !== Object.keys(stem.result_urls).length) await client.query('UPDATE audio_separations SET result_urls=$2 WHERE id=$1', [stem.id, urls]);
    }
    const due = await client.query(`SELECT a.id,a.track_id,a.result_url FROM track_addons a JOIN addon_services s ON s.id=a.addon_service_id
      WHERE s.name='convert_wav' AND a.status='completed' AND COALESCE(NULLIF(a.metadata->>'expires_at','')::timestamptz,a.updated_at+interval '3 days')<=now()`);
    for (const a of due.rows) {
      const keys = [...collectKeys(a.result_url)];
      if (keys.some(key => protectedWav(key, references, tracks))) continue;
      // Persist deletion intent before clearing the download link. Rollback cannot lose the file job.
      await client.query('INSERT INTO media_cleanup_jobs(track_id,payload) VALUES($1,$2)', [a.track_id, { result_url: a.result_url }]);
      await client.query("UPDATE track_addons SET status='expired',result_url=NULL,updated_at=now() WHERE id=$1", [a.id]);
    }
    for (const t of rows) {
      if (t.has_package || t.has_distribution || t.is_release_candidate || !['none', 'rejected', null].includes(t.distribution_status)) continue;
      if (!t.wav_expires_at || new Date(t.wav_expires_at).getTime() > Date.now()) continue;
      for (const column of WAV_COLUMNS) {
        const keys = [...collectKeys(t[column])];
        if (!keys.length || keys.some(key => !key.toLowerCase().endsWith('.wav') || protectedWav(key, references, tracks))) continue;
        await client.query('INSERT INTO media_cleanup_jobs(track_id,payload) VALUES($1,$2)', [t.id, { url: t[column] }]);
        await client.query(`UPDATE tracks SET ${column}=NULL WHERE id=$1`, [t.id]);
      }
    }
    await client.query('COMMIT');
  } catch (error) { await client.query('ROLLBACK'); throw error; }
}

async function drainJobs(client) {
  const jobs = await client.query('SELECT * FROM media_cleanup_jobs WHERE available_at<=now() ORDER BY id LIMIT 100');
  for (const job of jobs.rows) {
    try {
      const references = await loadReferences(client);
      const shared = [];
      const keys = collectKeys(job.payload);
      for await (const file of walkFiles(roots.ffmpeg)) {
        if (!/^\.source_[a-zA-Z0-9_.-]+\.json$/.test(file.relative)) continue;
        const provenance = JSON.parse(await fs.readFile(file.filename, 'utf8'));
        if ([...collectKeys(provenance.source)].some(key => keys.has(key)) && /^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$/.test(provenance.output)) keys.add(`ffmpeg/${provenance.output}`);
      }
      for (const key of keys) {
        // References may belong to another track/package: retry later, never break shared audio.
        if (references.has(key)) { shared.push(key); continue; }
        await unlinkMedia(key, roots);
      }
      if (shared.length) {
        // Keep URLs only, never retain deleted lyrics/prompts in a deferred job.
        const urls = shared.map(key => key.startsWith('ffmpeg/')
          ? `http://ffmpeg-api:3001/output/${key.slice(7)}`
          : `http://api:3000/storage/v1/object/public/${key}`);
        await client.query("UPDATE media_cleanup_jobs SET payload=$2,available_at=now()+interval '1 day',last_error='shared_reference' WHERE id=$1", [job.id, { urls }]);
      } else await client.query('DELETE FROM media_cleanup_jobs WHERE id=$1', [job.id]);
    } catch (error) {
      await client.query("UPDATE media_cleanup_jobs SET attempts=attempts+1,last_error=$2,available_at=now()+LEAST(interval '1 day',interval '30 seconds'*power(2,LEAST(attempts,11))) WHERE id=$1", [job.id, error.code || 'cleanup_failed']);
      console.error('[Media lifecycle] job failed', job.id, error.code || 'cleanup_failed');
    }
  }
}

async function sweep(client) {
  let references = await loadReferences(client);
  let removed = 0, bytes = 0;
  let candidates = 0;
  // Audio references expire regardless of historic upload_url/track references.
  // Orphan grace allows a provider upload to be linked atomically by its caller.
  for (const bucket of ['audio-references', 'tracks', 'covers', 'ffmpeg']) {
    const root = bucket === 'ffmpeg' ? roots.ffmpeg : `${roots.uploads}/${bucket}`;
    for await (const file of walkFiles(root)) {
      const key = `${bucket}/${file.relative}`;
      const age = Date.now() - file.stat.mtimeMs;
      const expiredReference = bucket === 'audio-references' && age >= DAY;
      const orphan = bucket !== 'audio-references' && age >= DAY && !references.has(key);
      if (bucket === 'ffmpeg' && /^\.source_[a-zA-Z0-9_.-]+\.json$/.test(file.relative) && age >= DAY) {
        const output = file.relative.slice('.source_'.length, -'.json'.length);
        try { await fs.stat(`${roots.ffmpeg}/${output}`); }
        catch (error) { if (error.code !== 'ENOENT') throw error; await fs.unlink(file.filename); }
        continue;
      }
      // ZIP/canonical evidence is never erased merely because an old row lost its link.
      if (!expiredReference && !(orphan && /\.(mp3|wav|flac|jpg|jpeg|png|webp)$/i.test(key))) continue;
      // Recheck database references immediately before unlink (fail closed on DB failure).
      if (++candidates % 50 === 1) references = await loadReferences(client);
      if (!expiredReference && references.has(key)) continue;
      if (await unlinkMedia(key, roots)) { removed++; bytes += file.stat.size; }
      if (removed >= 1000) break;
    }
  }
  await client.query('DELETE FROM user_audio_references WHERE expires_at<=now()');
  console.log('[Media lifecycle] sweep', { removed, bytes });
}

let running = false;
export async function runMediaLifecycle(fullSweep = false) {
  if (running) return;
  running = true;
  let client;
  try {
    client = await pool.connect();
    // Across replicas/restarts, only one worker owns the media volumes.
    const lock = await client.query('SELECT pg_try_advisory_lock(20261029,1200) AS locked');
    if (!lock.rows[0].locked) return;
    try {
      await expireWavs(client);
      await drainJobs(client);
      if (fullSweep) await sweep(client);
    } finally { await client.query('SELECT pg_advisory_unlock(20261029,1200)'); }
  } catch (error) { console.error('[Media lifecycle] cycle failed', error.code || 'cleanup_failed'); }
  finally { client?.release(); running = false; }
}

export function startMediaLifecycle() {
  void runMediaLifecycle(true);
  let ticks = 0;
  setInterval(() => { ticks++; void runMediaLifecycle(ticks % 120 === 0); }, 30000).unref();
}
