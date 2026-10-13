import test, { after } from "node:test";
import assert from "node:assert";

// No real infrastructure needed: pools connect lazily, only validation/health routes are hit.
process.env.DB_WRITE_URL = "postgres://u:p@127.0.0.1:1/x";
process.env.REDIS_URL = "redis://127.0.0.1:1";

const { app } = await import("../src/app.js");
const { default: redis } = await import("../src/redisClient.js");
const { closeQueue } = await import("../src/queue.js");

const server = app.listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

after(async () => {
  server.close();
  redis.disconnect();
  await closeQueue();
});

test("GET /api/health returns ok", async () => {
  const res = await fetch(`${base}/api/health`);
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(await res.json(), { status: "ok" });
});

test("GET /api/health/live does not depend on any dependency", async () => {
  const res = await fetch(`${base}/api/health/live`);
  assert.strictEqual(res.status, 200);
});

test("POST /api/items without a name returns 400", async () => {
  const res = await fetch(`${base}/api/items`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({}),
  });
  assert.strictEqual(res.status, 400);
});

test("GET /metrics exposes Prometheus metrics including request counters", async () => {
  const res = await fetch(`${base}/metrics`);
  assert.strictEqual(res.status, 200);
  assert.match(await res.text(), /http_requests_total/);
});
