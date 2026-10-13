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
