# Node + React + Postgres: Production-Style Local Platform

A full-stack app (React + Node.js/Express + PostgreSQL) taken through six stages: containerization, Kubernetes, Ingress/API gateway, CI/CD, platform services (Redis, queue, search, simulated read/write DB), and observability/scaling. Everything runs locally (Docker Compose, then `kind`).

## Repo structure

```
.
├── backend/                  # Express API + BullMQ worker (ESM), Prometheus metrics, unit tests
├── frontend/                 # React (Vite) app served by nginx
├── Dockerfile.backend        # multi-stage
├── Dockerfile.frontend       # multi-stage
├── .dockerignore
├── docker-compose.yml        # postgres, redis, search, backend, worker, frontend
├── k8s/                      # namespace, deployments, services, PV/PVC, ingress, HPA, network policies
├── observability/            # Prometheus, Grafana, Loki, Fluent Bit (namespace "monitoring")
├── scripts/                  # setup-kind.sh, setup-observability.sh, load-test.sh
├── docs/                     # screenshots / evidence
└── .github/workflows/ci-cd.yml
```

## Prerequisites

Docker (Compose v2), [`kind`](https://kind.sigs.k8s.io/), `kubectl`, `curl`. About 4 GB of free RAM (OpenSearch is the heavy part). On Windows use WSL2 (Docker Desktop with WSL integration) so the `.sh` scripts run.

## Quick start

| Goal | Command |
|---|---|
| Docker Compose (Task 1 and 5) | `docker compose up --build` |
| kind cluster + app (Tasks 2, 3, 5) | `./scripts/setup-kind.sh` |
| Observability + HPA demo (Task 6) | `./scripts/setup-observability.sh` |

After `setup-kind.sh`, add `127.0.0.1 node-react.local` to your hosts file (`/etc/hosts`, or `C:\Windows\System32\drivers\etc\hosts` on Windows) and open http://node-react.local.

---

## Troubleshooting

- **OpenSearch does not start / is OOM-killed:** it needs about 1.5 GB. The configs set `node.store.allow_mmap=false`, so the Linux `vm.max_map_count` host setting is not required; if you still see a `max virtual memory areas` error, run `sudo sysctl -w vm.max_map_count=262144`. To work without search, `docker compose up --build postgres backend frontend redis worker`.
- **Port already in use:** Compose publishes 8080 and 4000; kind publishes 80, 443 and 30080.
- **`node-react.local` does not resolve:** add `127.0.0.1 node-react.local` to the hosts file, or test with `curl -H "Host: node-react.local" http://localhost/api/health`.
- **Pods stuck in `ImagePullBackOff` on kind:** the images must be loaded with `kind load docker-image` (the setup script does this); do not apply the manifests before running it.

---

## Task 1: Local Docker Compose

```bash
docker compose up --build
```

- Frontend: http://localhost:8080
- Backend: http://localhost:4000/api/health
- Postgres: persisted in the named volume `postgres_data`. Check it: add an item, run `docker compose down` (without `-v`), run `docker compose up` again, and the item is still there.

**Dockerfiles (multi-stage).**
- `Dockerfile.backend`: a `deps` stage runs `npm ci --omit=dev`; the runtime stage copies only `node_modules` and `src` and runs as the unprivileged `node` user.
- `Dockerfile.frontend`: a Node stage builds the static bundle; the final image is `nginx:alpine` with only the compiled files (no Node, no sources).
- `.dockerignore` keeps `node_modules`, `.git`, manifests, docs and `.env` files out of the build context.

**Configuration through environment variables.** Compose passes `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` to the backend. The frontend's API base URL is `VITE_API_BASE_URL`, which Vite bakes in at build time; Compose sets it from the build argument `API_BASE_URL` (default `http://localhost:4000/api`, because the browser, not a container, calls the API). If it is empty the app falls back to `/api`, which is what Kubernetes uses (same origin behind the Ingress).

**Secrets.** Nothing is hardcoded in the application: `backend/src/db.js` has no password default and fails fast if no credentials are provided. The values in `docker-compose.yml` are local-development defaults; override them with a `.env` file (`cp .env.example .env`, which is git-ignored).

**Networking.** Services reach each other by service name on the Compose network (`postgres`, `redis`, `search`); `depends_on` with health checks makes the backend start only once Postgres accepts connections.

## Task 2: Kubernetes

```bash
./scripts/setup-kind.sh      # creates the cluster, builds + loads images, applies the manifests
# or manually, on an existing kind/minikube cluster with the images loaded:
kubectl apply -f k8s/namespace-dev.yaml
kubectl apply -n dev -f k8s/
kubectl get all -n dev
```

- The `dev` namespace holds every application resource.
- `backend-service` and `postgres-service` are `ClusterIP`: internal only.
- `frontend-service` is `NodePort` 30080 for direct access (http://localhost:30080 on kind); Task 3 adds the Ingress on top.
- Postgres stores its data on a `PersistentVolumeClaim` bound to a `hostPath` `PersistentVolume`, so data survives pod restarts. The Deployment uses `strategy: Recreate` because the volume is ReadWriteOnce, and `PGDATA` points to a sub-directory to avoid the `lost+found` init error.
- Configuration: non-secret settings in the `app-config` ConfigMap, credentials in the `app-secrets` Secret (dev-only placeholders; see Task 4 for other environments).
- `backend` has a `readinessProbe` on `/api/health/ready` (checks the database is reachable) and a `livenessProbe` on `/api/health/live` (process only), so a database outage stops traffic to a pod instead of restart-looping it.
- Images use the names `ghcr.io/<owner>/...-backend|frontend`. The setup script builds them locally and loads them into kind (`kind load docker-image`); the pipeline replaces the tag with the one it just pushed.

## Task 3: Ingress / API Gateway

`scripts/setup-kind.sh` installs ingress-nginx; the Ingress is `k8s/ingress-dev.yaml`.

```bash
echo "127.0.0.1 node-react.local" | sudo tee -a /etc/hosts
kubectl apply -n dev -f k8s/ingress-dev.yaml
curl http://node-react.local/api/health
# without touching the hosts file:
curl -H "Host: node-react.local" http://localhost/api/health
```

Routing: `/` goes to `frontend-service`, `/api` and `/api/*` go to `backend-service`. There are two Ingress objects on the same host (`web-ingress`, `api-ingress`) so rate limiting (Task 6) can apply to the API only.

**Request path:** `Browser -> Ingress -> Service -> Pod -> PostgreSQL`
1. The browser resolves `node-react.local` to `127.0.0.1` (hosts file); kind maps host port 80 to the node where the ingress controller listens.
2. The ingress controller (nginx) matches host and path: `/api/*` to `backend-service:4000`, everything else to `frontend-service:80`.
3. The Service is a stable virtual IP; kube-proxy picks one Ready pod from its endpoints.
4. The backend pod talks to PostgreSQL through `postgres-service` (writes) and `postgres-read-service` (reads), which lead to the Postgres pod and its volume.

**Ingress vs Service vs Pod.** A Pod runs the containers and its IP changes on every restart. A Service gives a set of pods one stable name and IP. An Ingress is only a set of routing rules; the ingress controller is the component that actually receives HTTP traffic and applies them.

**Kubernetes DNS.** CoreDNS gives every Service the name `<service>.<namespace>.svc.cluster.local`, for example `backend-service.dev.svc.cluster.local`. From a pod in the same namespace the short name `backend-service` also works, because `/etc/resolv.conf` contains the search domains `dev.svc.cluster.local svc.cluster.local cluster.local`. The manifests use short names so the same files work in `preprod` and `release`.

### Debugging

**(a) Ingress is reachable but the backend is not** (502/503/404 on `/api/*`):

```bash
kubectl -n dev get endpoints backend-service      # empty = selector mismatch or pods not Ready
kubectl -n dev get pods -l app=backend            # Running? READY 1/1? restarts?
kubectl -n dev describe pod <pod>                 # failing probes, image pull errors
kubectl -n dev logs deploy/backend                # DB errors, crashes
kubectl -n dev port-forward svc/backend-service 4000:4000
curl localhost:4000/api/health                    # bypasses the Ingress
kubectl -n dev describe ingress api-ingress       # right service and port?
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller | tail
```
Typical causes: readiness failing because Postgres is down, a Service selector not matching the pod labels, a wrong `targetPort`, a wrong path in the Ingress.

**(b) The frontend cannot talk to the backend:**
1. Browser dev tools, Network tab: which URL is called and what status comes back? The page shows the API base it uses (`API base: /api`).
2. `VITE_API_BASE_URL` is baked in at build time. If the browser calls `http://localhost:4000/api` inside Kubernetes, the image was built with the Compose value; rebuild it without the build argument so it uses `/api`.
3. The browser must never call `http://backend-service:4000`: that name only resolves inside the cluster.
4. `curl -i http://node-react.local/api/health` from the host: if it works, the problem is in the frontend build; if not, go to (a).
5. From inside the cluster: `kubectl -n dev run tmp --rm -it --image=busybox --restart=Never -- wget -qO- http://backend-service:4000/api/health` tests DNS, Service and Pod without the Ingress.
6. A 503/429 on bursts means the rate limit (Task 6) was hit.

### Evolving into microservices

The Ingress already acts as a lightweight gateway routing by path prefix. Splitting the backend into `users-service`, `orders-service` and so on means adding Deployments/ClusterIP Services and path rules (`/api/users`, `/api/orders`); DNS, probes and the Ingress pattern stay the same. Next steps: a dedicated gateway (Kong, Envoy Gateway, Gateway API) for authN/Z, per-route rate limits and tracing; one database per service; asynchronous communication over the queue (BullMQ today, RabbitMQ/Kafka later); and a service mesh for mTLS and retries.

## Task 4: CI/CD and multi-environment deployment

`.github/workflows/ci-cd.yml`

| Branch | Namespace | Ingress host |
|---|---|---|
| `master` | `dev` | `node-react.local` |
| `pre-release/v*` | `preprod` | `preprod.node-react.local` |
| `release/v*` | `release` | `release.node-react.local` |

Pipeline:
1. **build-and-test**: install backend and frontend dependencies, `node --check` build validation, backend unit tests (`npm test`), frontend build.
2. **build-and-push**: build both images, tag `<branch>-<short-sha>` (slashes become dashes) plus `<namespace>-latest`, push to GHCR on branch pushes. Pull requests run steps 1 and 2 without pushing.
3. **deploy**: patch a copy of `k8s/` with the new image tags, the target namespace, a per-environment PV name and the environment's Ingress host, then `kubectl apply` and wait for `rollout status`.

Environment differences handled by the pipeline: the target namespace is created first; the dev-only Namespace manifest, placeholder Secret and fixed NodePort are not applied outside `dev`; the PersistentVolume is renamed per environment (PVs are cluster-scoped); Ingress hosts differ (nginx rejects the same host and path in two namespaces).

**How CI secrets are stored and used**
- Registry: the built-in `GITHUB_TOKEN` (short-lived, scoped to the repo and run) logs in to GHCR. No long-lived registry credential exists.
- Cluster access: the kubeconfig is stored base64-encoded as the Actions secret `KUBECONFIG_B64`, ideally per GitHub Environment and backed by a service account limited to that namespace. The deploy job writes it to `~/.kube/config` with mode 600; it is never echoed. If it is not set (this assessment is local-only, a hosted runner cannot reach a laptop cluster) the kubectl steps are skipped with a notice and the run stays green.
- App credentials: `k8s/app-secrets.yaml` only holds dev placeholders and is applied to `dev` only. For `preprod` and `release` the pipeline creates `app-secrets` from the `DB_USER` and `DB_PASSWORD` secrets of the matching GitHub Environment and fails with a clear error if they are missing. Use URL-safe characters (they end up in connection URLs). In production, Sealed Secrets or External Secrets would replace this.

One-time GitHub setup: Settings, Environments, create `dev`, `preprod`, `release`; add `KUBECONFIG_B64` (and `DB_USER`, `DB_PASSWORD` for the last two); optionally require reviewers on `release`. A cluster that pulls from GHCR needs the packages to be public or an image pull secret.

**Rollback strategy**
- Automatic: if a rollout does not become healthy, the last deploy step runs `kubectl rollout undo` on the deployments.
- Manual, fast: Actions, CI/CD, Run workflow, enter the namespace (the `rollback` job), or `kubectl -n <ns> rollout undo deployment/backend [--to-revision=N]`; `kubectl rollout history` lists revisions.
- Precise: every image tag is immutable (`<branch>-<sha>`), so re-running the pipeline on a previous commit redeploys exactly that known-good image, without depending on an old ReplicaSet still existing.

## Task 5: Platform services (Redis, queue, search, read/write DB)

Added to both `docker-compose.yml` and `k8s/`. All of them are internal (`ClusterIP`, no published ports in Kubernetes); `k8s/network-policies.yaml` restricts who may connect to them (enforced when the CNI supports NetworkPolicy, such as Calico or Cilium; kind's default CNI ignores them).

| Service | Files | How the backend uses it |
|---|---|---|
| Redis | `redis-deployment.yaml`, `redis-service.yaml` (`maxmemory-policy noeviction`, required by BullMQ) | `REDIS_URL`; `GET /api/health/redis` |
| Queue (BullMQ over Redis) | `bullmq-worker-deployment.yaml` | every `POST /api/items` enqueues an `item-created` job (`backend/src/queue.js`); a separate worker process (`backend/src/worker.js`, same image, different `command`) consumes it, so it scales and fails independently of the API |
| Search (OpenSearch, single node, security plugin disabled, dev only) | `search-deployment.yaml`, `search-service.yaml` | `SEARCH_URL`; `GET /api/health/search` (health call only; real indexing would hook into the queue consumer) |
| Read/write DB | `DB_WRITE_URL` and `DB_READ_URL` | `backend/src/db.js` keeps two pools: `write()` always uses the writer, `read()` uses the reader |

Quick checks (Compose): `curl localhost:4000/api/health/redis`, `curl localhost:4000/api/health/search`, add an item and watch `docker compose logs worker`. In Kubernetes: `kubectl -n dev logs deploy/bullmq-worker`.

**Simulated cluster.** Locally the "primary" and "replica" are the same Postgres instance behind two endpoints (`postgres` and the alias `postgres-replica` in Compose; `postgres-service` and `postgres-read-service` in Kubernetes). The code already treats them as separate targets, so pointing `DB_READ_URL` at a real replica later is a configuration-only change.

**Where routing logic lives.** Here it is explicit in application code (`write()` vs `read()`). The alternative is a DB proxy (PgBouncer, Pgpool-II, a managed reader endpoint) that makes routing transparent to the app: simpler code, but one more component to operate and one more hop of latency.

**Replication lag.** A replica can be milliseconds to seconds behind the primary. Operations that must always hit the writer: all writes; reads that must see data just written (read-your-writes, for example re-fetching a record right after creating it); reads inside a transaction that also writes; reads that drive a write decision (uniqueness checks, balance checks, locks, idempotency keys); and auth/session reads right after login or a password change. Lists, dashboards and search tolerate seconds-old data and can use replicas. Mitigations: monitor lag, fall back to the primary when lag is high, or pin a user's reads to the primary for a few seconds after they write.

## Task 6: Observability, scaling and rate limiting

```bash
./scripts/setup-observability.sh
kubectl -n monitoring port-forward svc/grafana 3000:3000        # admin / admin-dev-only (dev credentials)
./scripts/load-test.sh                                         # generate traffic for the dashboard and the HPA
kubectl -n dev get hpa -w
```

**Metrics (Prometheus + Grafana).** The backend exposes `/metrics` (default Node.js metrics, `http_requests_total`, `http_request_duration_seconds`). It is not routed by the Ingress (only `/api/*` is); Prometheus scrapes the pods in `dev` directly through the `prometheus.io/*` annotations. CPU and memory come from the kubelet's cAdvisor endpoint, and the replica count is `count(up{job="backend"} == 1)`. Grafana is provisioned with Prometheus and Loki data sources and a "Backend overview" dashboard: backend CPU, backend memory, request rate, error rate (5xx req/s and %), backend replicas over time, and p95 latency.

**Alerts I would configure** (rules in `observability/prometheus.yaml`):
- **High error rate** (5xx over 5% for 5 min): the most direct sign that users are failing, independent of load.
- **High p95 latency** (over 500 ms for 10 min): catches slow queries or a struggling dependency before errors appear.
- **High CPU / HPA at max replicas** (over 80% of the limit for 10 min): the autoscaler has no headroom left; queueing and latency follow.
- **Fewer than 2 healthy backend pods**: redundancy is lost, one failure away from an outage.
- With more time: pod restarts and OOM kills, memory near the limit, Postgres connections and replication lag, queue depth and failed jobs, disk usage on the volume.

**Logging (Fluent Bit + Loki).** Fluent Bit runs as a DaemonSet (one per node, so it sees every pod's logs on that node), tails the container logs of the `dev` namespace, adds Kubernetes metadata and ships them to Loki. The backend writes one JSON line per request, so in Grafana, Explore, Loki:

```
{job="backend"}
{namespace="dev", app="backend"} | json | status >= 500
{job="bullmq-worker"} |= "processing"
```
Check the collector with `kubectl -n monitoring logs ds/fluent-bit`.

**HPA** (`k8s/hpa-backend.yaml`): 2 to 6 replicas, scale on 70% average CPU or 80% average memory (relative to the pod requests), 120 s scale-down stabilisation. It needs metrics-server, which `setup-kind.sh` installs. It lives in `k8s/` so the pipeline deploys it with the app.

**Rate limiting** (Ingress annotations on the API route only): `limit-rps: 20` per client IP, `limit-burst-multiplier: 5` (bursts up to 100), `limit-connections: 50`. A person using the UI makes a handful of requests per second, so 20 rps per IP never affects normal use but stops a single client or script from saturating the backend; the burst allowance absorbs page loads that fire several calls at once. The static frontend is not limited. ingress-nginx answers excess requests with 503 by default (`limit-req-status-code: "429"` changes that). Limiting at the edge protects the pods before they spend any CPU. Limits should be tuned from real traffic.

## Design decisions, trade-offs, and what I would do with more time

- **Plain manifests, applied with `kubectl apply -f k8s/`**, exactly as the provided pipeline expects; the pipeline rewrites namespace, image tags and host with `sed`. Kustomize or Helm would be the next step for larger per-environment differences.
- **Plain manifests for observability** instead of Helm charts, so every piece is visible and reviewable; `kube-prometheus-stack` would be the production choice.
- **API URL baked in at build time** (as the provided frontend does): simple and fast, but one image per API URL. Runtime configuration (an `env-config.js` written at container start) would give one image for every environment.
- **One Postgres pod behind a "primary" and a "replica" endpoint**: shows the configuration and code split without the cost of real replication. A StatefulSet or operator (CloudNativePG) is the real answer.
- **hostPath PV** is simple for local clusters but not for production; use a real StorageClass there.
- **Images are loaded into kind** (`kind load docker-image`) so no registry is needed locally; CI pushes to GHCR.
- **Changes I made to the provided code:** `db.js` no longer has a default password and fails fast without credentials; `index.js` was split into `app.js` (routes) and `index.js` (start-up) so the app can be tested; added `metrics.js` (Prometheus metrics and JSON request logs), unit tests (the old test script ended in `|| true`, which hid failures) and the pipeline fixes described in Task 4.
- **With more time:** Alertmanager with real notifications, kube-state-metrics, tracing (OpenTelemetry), TLS with cert-manager, Sealed Secrets, a real Postgres replica, integration tests on kind in CI, image scanning (Trivy), and a PodDisruptionBudget plus anti-affinity for the backend.

## Evidence (`docs/`)

`docs/EVIDENCE.md` lists the screenshots to capture: `kubectl get all -n dev`, the app at http://node-react.local, Grafana dashboards, Loki log queries, and a passing GitHub Actions run.
