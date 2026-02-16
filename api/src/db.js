/**
 * PostgreSQL connection pool
 */
import pg from 'pg';
const { Pool } = pg;

export const pool = new Pool({
  host: process.env.DB_HOST || 'db',
  port: parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME || 'aimuza',
  user: process.env.DB_USER || 'aimuza',
  password: process.env.DB_PASSWORD || 'aimuza_secret',
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  console.error('[DB] Pool error:', err.message);
});

export async function testConnection() {
  try {
    const client = await pool.connect();
    const res = await client.query('SELECT NOW() as now');
    client.release();
    console.log(`[DB] Connected to PostgreSQL at ${process.env.DB_HOST || 'db'}:${process.env.DB_PORT || '5432'} — ${res.rows[0].now}`);
  } catch (err) {
    console.error('[DB] Connection failed:', err.message);
    throw err;
  }
}

/**
 * Устанавливает JWT claims для текущей транзакции (для auth.uid() и RLS)
 */
export async function setJWTClaims(client, user) {
  // A4: Use parameterized set_config instead of string interpolation
  if (user) {
    await client.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [user.id]);
    await client.query(`SELECT set_config('request.jwt.claim.role', 'authenticated', true)`);
    if (user.email) {
      await client.query(`SELECT set_config('request.jwt.claim.email', $1, true)`, [user.email]);
    }
  } else {
    await client.query(`SELECT set_config('request.jwt.claim.role', 'anon', true)`);
  }
}
