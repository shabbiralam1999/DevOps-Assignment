import pg from "pg";

const { Pool } = pg;

// Credentials are never hardcoded: they come from the environment (Secret in k8s,
// .env / compose environment locally). Either DB_WRITE_URL or the DB_* parts are required.
function buildConnectionString() {
  const { DB_USER, DB_PASSWORD, DB_HOST = "localhost", DB_PORT = "5432", DB_NAME } = process.env;
  if (!DB_USER || !DB_PASSWORD || !DB_NAME) {
    throw new Error("Set DB_WRITE_URL, or DB_USER, DB_PASSWORD and DB_NAME (see backend/.env.example)");
  }
  return `postgres://${encodeURIComponent(DB_USER)}:${encodeURIComponent(DB_PASSWORD)}@${DB_HOST}:${DB_PORT}/${DB_NAME}`;
}

// Simulated read/write DB cluster: two pools pointed at different env vars.
// Locally both usually resolve to the same Postgres instance, but the app
// already treats reads and writes as separate targets, so pointing
// DB_READ_URL at a real replica later is a config-only change - no code edits.
const writePool = new Pool({
  connectionString: process.env.DB_WRITE_URL || buildConnectionString(),
});

const readPool = new Pool({
  connectionString:
    process.env.DB_READ_URL || process.env.DB_WRITE_URL || buildConnectionString(),
});

export async function initSchema() {
  await writePool.query(`
    CREATE TABLE IF NOT EXISTS items (
      id SERIAL PRIMARY KEY,
      name TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  `);
}

// All INSERT/UPDATE/DELETE statements must go through write() -> writePool,
// which in a real cluster points at the primary.
export function write(query, params) {
  return writePool.query(query, params);
}

// SELECTs can be served from read() -> readPool, which in a real cluster
// points at a replica. Anything that just read its own write (e.g. a
// "did my update succeed" check right after a write) should still use
// write()/writePool to avoid replication-lag surprises.
export function read(query, params) {
  return readPool.query(query, params);
}

export async function pingWrite() {
  await writePool.query("SELECT 1");
}

export async function pingRead() {
  await readPool.query("SELECT 1");
}
