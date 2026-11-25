import crypto from 'node:crypto';
import { pool, setJWTClaims } from '../db.js';
import { normalizeStudioGeneration as normalizeInput, studioSunoPayload } from './studio-generation-input.js';
import { readAudioReference } from './studio-audio-reference.js';
import { getAvailableVoice } from './voice-profile-worker.js';

const fingerprint = value => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');

export async function createStudioGeneration(req, res, next) {
  const authorization = req.get('authorization');
  let client;
  try {
    const input = normalizeInput(req.body);
    if (req.voiceSongRequest && !input.voiceProfileId) {
      return res.status(400).json({ error: 'Выберите подтверждённый голос' });
    }
    const voiceSecret = process.env.SERVICE_ROLE_KEY;
    if (input.voiceProfileId && (!voiceSecret || !process.env.DENO_FUNCTIONS_URL || !authorization)) {
      return res.status(503).json({ error: 'Генерация с голосом временно недоступна' });
    }
    const payloadHash = fingerprint({ ...input, requestId: undefined });
    client = await pool.connect();
    await client.query('BEGIN');
    await setJWTClaims(client, req.user);
    await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`studio:${req.user.id}:${input.requestId}`]);

    const prior = await client.query(
      `SELECT l.generation_params, l.cost_rub, t.id, t.title, t.status, t.audio_url, t.cover_url, t.duration
       FROM public.generation_logs l JOIN public.tracks t ON t.id = l.track_id
       WHERE l.user_id = $1 AND l.request_id = $2 ORDER BY l.created_at ASC`, [req.user.id, input.requestId],
    );
    if (prior.rows.length) {
      const params = prior.rows[0].generation_params || {};
      if (params.studio_payload_hash !== payloadHash) {
        await client.query('ROLLBACK');
        return res.status(409).json({ error: 'Этот идентификатор уже использован с другими параметрами' });
      }
      await client.query('COMMIT');
      const amountDebited = prior.rows.reduce((sum, row) => sum + Number(row.cost_rub || 0), 0);
      const tracks = prior.rows.map(({ cost_rub: _cost, generation_params: _params, ...row }) => row);
      return res.status(202).json({ requestId: input.requestId, status: params.dispatch_state || 'pending', taskId: params.task_id || null, tracks, amountDebited, replayed: true });
    }

    const audioReferenceUrl = input.audioReference ? readAudioReference(req.user.id, input.audioReference) : undefined;
    if (input.audioReference && !audioReferenceUrl) {
      await client.query('ROLLBACK');
      return res.status(400).json({ error: 'Аудиореференс недоступен. Прикрепите аудио заново' });
    }
    let providerPersonaId;
    if (input.voiceProfileId) {
      try {
        providerPersonaId = await getAvailableVoice(client, req.user.id, input.voiceProfileId);
      } catch (error) {
        if (!error.status) throw error;
        await client.query('ROLLBACK');
        return res.status(error.status).json({ error: error.message });
      }
    } else if (input.personaId) {
      const persona = await client.query(
        `SELECT suno_persona_id FROM public.personas WHERE id = $1 AND user_id = $2
         AND status = 'ready' AND NULLIF(suno_persona_id, '') IS NOT NULL FOR SHARE`,
        [input.personaId, req.user.id],
      );
      providerPersonaId = persona.rows[0]?.suno_persona_id;
      if (!providerPersonaId) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'Персона недоступна. Выберите её заново' });
      }
    }

    if (input.songIdeaId) {
      const acceptedIdea = await client.query(
        'SELECT id FROM public.song_idea_discoveries WHERE user_id = $1 AND idea_id = $2 AND accepted_at IS NOT NULL FOR SHARE',
        [req.user.id, input.songIdeaId],
      );
      if (!acceptedIdea.rows.length) {
        await client.query('ROLLBACK');
        return res.status(400).json({ error: 'Сначала примите идею в своей библиотеке', code: 'SONG_IDEA_NOT_ACCEPTED' });
      }
    }

    let debit;
    try {
      debit = await client.query("SELECT * FROM public.debit_for_generation_v6($1, '{}'::uuid[], $2)", [req.user.id, `Музыкальная генерация: ${input.title || input.prompt.slice(0, 60)}`]);
    } catch (error) {
      await client.query('ROLLBACK');
      if (/Insufficient balance/i.test(error.message)) return res.status(402).json({ error: 'Недостаточно средств для генерации', code: 'INSUFFICIENT_FUNDS' });
      throw error;
    }
    const billing = debit.rows[0];
    const description = input.mode === 'custom' ? input.lyrics || input.style : input.prompt;
    const created = await client.query(
      `INSERT INTO public.tracks (user_id, title, description, lyrics, status, is_public, audio_reference_url)
       VALUES ($1,$2,$3,$4,'pending',false,$5),($1,$2,$3,$4,'pending',false,$5)
       RETURNING id, title, status, audio_url, cover_url, duration`,
      [req.user.id, input.title || 'Новый трек', description, input.instrumental ? null : input.lyrics || null, audioReferenceUrl ?? null],
    );
    const generationParams = { ...input, audioReference: undefined, audio_reference_url: audioReferenceUrl, studio_payload_hash: payloadHash, dispatch_state: 'dispatching' };
    const amount = Number(billing.amount_debited);
    for (const [index, track] of created.rows.entries()) {
      const trackCost = index === 0 ? Math.ceil(amount / 2) : Math.floor(amount / 2);
      await client.query(
        `INSERT INTO public.generation_logs (user_id, track_id, request_id, service_id, service_name, provider, provider_operation, provider_model, cost_rub, sale_price_rub, discount_rub, base_cost_credits, generation_params, status)
         VALUES ($1,$2,$3,$4,'generate_music_v6','sunoapi',$10,'V6',$5,$6,$7,$8,$9,'pending')`,
        [req.user.id, track.id, input.requestId, billing.generation_service_id, trackCost, Number(billing.generation_sale_price_rub) / 2, Number(billing.discount_amount) / 2, Number(billing.generation_base_cost_credits || 0) / 2, generationParams, audioReferenceUrl ? 'upload_cover' : 'generate'],
      );
      await client.query(
        `INSERT INTO public.user_prompts (user_id, track_id, title, description, lyrics, is_public, price)
         VALUES ($1,$2,$3,$4,$5,false,0)`, [req.user.id, track.id, track.title, description, input.instrumental ? null : input.lyrics || null],
      );
    }
    if (input.songIdeaId) {
      await client.query('SELECT public.record_song_idea_generation($1, $2::uuid[])', [input.songIdeaId, created.rows.map((track) => track.id)]);
    }
    await client.query('COMMIT');
    client.release(); client = null;

    const denoUrl = process.env.DENO_FUNCTIONS_URL;
    if (!denoUrl || !authorization) throw new Error('Генератор временно недоступен');
    const run = await fetch(`${denoUrl.replace(/\/$/, '')}/functions/v1/suno-generate`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json', Authorization: authorization,
        ...(input.voiceProfileId ? {
          'X-Aimuza-Voice-Authorization': crypto.createHmac('sha256', voiceSecret)
            .update(JSON.stringify([req.user.id, created.rows.map(track => track.id), providerPersonaId])).digest('hex'),
        } : {}),
      },
      body: JSON.stringify(studioSunoPayload(input, created.rows, { personaId: providerPersonaId, audioReferenceUrl })),
    });
    const result = await run.json().catch(() => null);
    const taskId = result?.taskId || result?.task_id || null;
    const dispatchState = run.ok && taskId ? 'submitted' : 'unknown';
    await pool.query(`UPDATE public.generation_logs SET generation_params = generation_params || $1::jsonb WHERE user_id=$2 AND request_id=$3`, [JSON.stringify({ dispatch_state: dispatchState, task_id: taskId }), req.user.id, input.requestId]);
    if (!run.ok || !taskId) return res.status(202).json({ requestId: input.requestId, status: 'unknown', tracks: created.rows, amountDebited: Number(billing.amount_debited), newBalance: Number(billing.new_balance) });
    return res.status(202).json({ requestId: input.requestId, status: 'submitted', taskId, tracks: created.rows, amountDebited: Number(billing.amount_debited), newBalance: Number(billing.new_balance) });
  } catch (error) {
    if (client) { try { await client.query('ROLLBACK'); } catch {} client.release(); }
    next(error);
  }
}
