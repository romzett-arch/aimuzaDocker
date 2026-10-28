import pg from 'pg';
export const gatewayPool = new pg.Pool({
  host:process.env.DB_HOST || 'db', port:Number(process.env.DB_PORT || 5432),
  database:process.env.DB_NAME || 'aimuza', user:process.env.GATEWAY_DB_USER || 'aimuza_gateway',
  password:process.env.GATEWAY_DB_PASSWORD, max:10, statement_timeout:10000,
  idle_in_transaction_session_timeout:15000, connectionTimeoutMillis:5000,
});
export async function testGatewayConnection() {
  if (!process.env.GATEWAY_DB_PASSWORD) throw new Error('GATEWAY_DB_PASSWORD must be configured');
  const {rows} = await gatewayPool.query('SELECT rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user');
  if (!rows.length || rows[0].rolsuper || rows[0].rolbypassrls) throw new Error('Unsafe gateway database role');
}
