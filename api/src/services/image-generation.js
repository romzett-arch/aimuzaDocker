import { pool } from '../db.js';

const service = 'generate_image';
const metadata = 'id, prompt, aspect_ratio, resolution, status, price_rub, mime_type, created_at';

export async function imageHistory(userId) {
  return (await pool.query(
    `SELECT ${metadata} FROM public.image_generation_jobs WHERE user_id=$1
     ORDER BY created_at DESC, id DESC LIMIT 20`, [userId],
  )).rows;
}

export async function imageGallery(userId, cursor) {
  const limit = 12;
  const { rows } = await pool.query(
    `SELECT ${metadata} FROM public.image_generation_jobs
     WHERE user_id=$1 AND status='completed' AND image IS NOT NULL
       AND ($2::uuid IS NULL OR (created_at,id) < (
         SELECT created_at,id FROM public.image_generation_jobs WHERE user_id=$1 AND id=$2
       ))
     ORDER BY created_at DESC,id DESC LIMIT $3`, [userId, cursor, limit + 1],
  );
  const items = rows.slice(0, limit);
  return { items, nextCursor: rows.length > limit ? items.at(-1).id : null };
}

export async function getGeneratedImage(userId, id) {
  return (await pool.query(
    'SELECT image, mime_type, resolution FROM public.image_generation_jobs WHERE user_id=$1 AND id=$2 AND status=\'completed\'',
    [userId, id],
  )).rows[0];
}

export async function getImageJob(userId, id) {
  return (await pool.query(
    `SELECT ${metadata} FROM public.image_generation_jobs WHERE user_id=$1 AND id=$2`, [userId, id],
  )).rows[0];
}

export async function savePreparedCover(userId, id, image, resolution) {
  const result = await pool.query(
    `INSERT INTO public.image_generation_jobs
       (user_id,id,prompt,aspect_ratio,resolution,status,image,mime_type)
     VALUES ($1,$2,'Подготовленная обложка','1:1',$3,'completed',$4,'image/jpeg')
     ON CONFLICT (user_id,id) DO NOTHING RETURNING ${metadata}`,
    [userId, id, resolution, image],
  );
  return result.rows[0] ?? getImageJob(userId, id);
}

export async function reserveImage(userId, input) {
  const db = await pool.connect();
  try {
    await db.query('BEGIN');
    await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [`${service}:${userId}`]);
    const { rows: [existing] } = await db.query(
      `SELECT ${metadata} FROM public.image_generation_jobs WHERE user_id=$1 AND id=$2`,
      [userId, input.id],
    );
    if (existing) {
      await db.query('COMMIT');
      return { job: existing, isNew: false };
    }

    const { rows: [pending] } = await db.query(
      "SELECT id FROM public.image_generation_jobs WHERE user_id=$1 AND status='pending' LIMIT 1", [userId],
    );
    const { rows: [pricing] } = await db.query(
      'SELECT price_rub FROM public.addon_services WHERE name=$1 AND is_active FOR SHARE', [service],
    );
    const problem = pending ? 'GENERATION_PENDING' : !pricing || pricing.price_rub < 1
      ? 'UNAVAILABLE' : pricing.price_rub !== input.price ? 'PRICE_CHANGED' : null;
    if (problem) {
      await db.query('ROLLBACK');
      return { problem };
    }

    const { rows: [debit] } = await db.query(
      'SELECT * FROM public.debit_addon_service($1,$2,$3,$4)',
      [userId, service, 'Создание картинки', { request_id: input.id }],
    );
    const { rows: [job] } = await db.query(
      `INSERT INTO public.image_generation_jobs (user_id,id,prompt,aspect_ratio,resolution,price_rub)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING ${metadata}`,
      [userId, input.id, input.prompt, input.ratio, input.resolution, debit.amount_debited],
    );
    await db.query('COMMIT');
    return { job, isNew: true };
  } catch (error) {
    await db.query('ROLLBACK');
    if (error.message === 'Insufficient balance') return { problem: 'INSUFFICIENT_BALANCE' };
    throw error;
  } finally {
    db.release();
  }
}

export async function completeImage(userId, id, image, type) {
  const { rows: [job] } = await pool.query(
    `UPDATE public.image_generation_jobs SET image=$3, mime_type=$4, status='completed'
     WHERE user_id=$1 AND id=$2 AND status='pending' RETURNING ${metadata}`,
    [userId, id, image, type],
  );
  return job;
}

export function failImage(userId, id) {
  return pool.query('SELECT public.fail_image_generation($1,$2)', [userId, id]);
}

export function startImageRecovery() {
  const recover = async () => {
    try {
      await pool.query(`SELECT public.fail_image_generation(user_id,id)
        FROM (SELECT user_id,id FROM public.image_generation_jobs
              WHERE status='pending' AND created_at < now()-interval '5 minutes'
              ORDER BY created_at LIMIT 20 FOR UPDATE SKIP LOCKED) AS expired`);
    } catch (error) {
      console.error('[image recovery]', error.message);
    }
  };
  void recover();
  setInterval(() => void recover(), 60_000).unref();
}
