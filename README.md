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
