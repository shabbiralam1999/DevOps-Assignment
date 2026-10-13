import client from "prom-client";

export const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequests = new client.Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "route", "status"],
  registers: [register],
});

const httpDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request latency in seconds",
  labelNames: ["method", "route", "status"],
  buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
  registers: [register],
});

// Probes and the scrape endpoint itself would drown out real traffic.
const IGNORED = new Set(["/metrics", "/api/health/live", "/api/health/ready"]);

// Records metrics and writes one JSON log line per request (easy to filter in Loki).
export function metricsMiddleware(req, res, next) {
  if (IGNORED.has(req.path)) return next();
  const start = process.hrtime.bigint();
  res.on("finish", () => {
    const seconds = Number(process.hrtime.bigint() - start) / 1e9;
    const route = req.route ? req.baseUrl + req.route.path : "unmatched";
    const labels = { method: req.method, route, status: res.statusCode };
    httpRequests.inc(labels);
    httpDuration.observe(labels, seconds);
    console.log(
      JSON.stringify({
        level: res.statusCode >= 500 ? "error" : "info",
        msg: "request",
        method: req.method,
        path: req.originalUrl,
        status: res.statusCode,
        duration_ms: Math.round(seconds * 1000),
      })
    );
  });
  next();
}

export async function metricsHandler(req, res) {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
}
