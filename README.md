# Node.js + React + PostgreSQL: Production-Style Local Platform

A full-stack application built with **React, Node.js/Express, and PostgreSQL**, progressively developed across six stages: containerization, Kubernetes orchestration, Ingress routing, CI/CD, platform services, and observability with autoscaling.

The platform runs locally using Docker Compose and Kubernetes in `kind`. It includes Redis, a BullMQ background worker, OpenSearch, simulated database read/write endpoints, Prometheus, Grafana, Loki, Fluent Bit, and Horizontal Pod Autoscaling (HPA).

**Application URL:** [http://node-react.local](http://node-react.local)

> **Scope:** This project demonstrates production-oriented architecture and operational practices in a local development environment. Some components, including database replication, use simulated configurations rather than fully distributed production infrastructure.

## Table of Contents

- [Architecture and Repository Structure](#architecture-and-repository-structure)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Task 1: Docker Compose and Containerization](#task-1-docker-compose-and-containerization)
- [Task 2: Kubernetes Deployment](#task-2-kubernetes-deployment)
- [Task 3: Ingress and API Gateway](#task-3-ingress-and-api-gateway)
- [Task 4: CI/CD and Multi-Environment Deployment](#task-4-cicd-and-multi-environment-deployment)
- [Task 5: Platform Services](#task-5-platform-services)
- [Task 6: Observability, Scaling, and Rate Limiting](#task-6-observability-scaling-and-rate-limiting)
- [Troubleshooting](#troubleshooting)
- [Architecture Decisions and Trade-offs](#architecture-decisions-and-trade-offs)
- [Evidence and Screenshots](#evidence-and-screenshots)

## Architecture and Repository Structure

```text
.
├── backend/                    # Express API, BullMQ worker, metrics, tests
├── frontend/                   # React application built with Vite
├── Dockerfile.backend          # Multi-stage backend image
├── Dockerfile.frontend         # Multi-stage frontend image
├── .dockerignore
├── docker-compose.yml          # Local application and platform services
├── k8s/                        # Kubernetes resources and configuration
├── observability/              # Prometheus, Grafana, Loki, Fluent Bit
├── scripts/
│   ├── setup-kind.sh
│   ├── setup-observability.sh
│   └── load-test.sh
├── docs/
│   └── screenshots/            # Assessment evidence
└── .github/
    └── workflows/
        └── ci-cd.yml            # GitHub Actions pipeline
```

### Technology Stack

| Area | Technologies |
|---|---|
| Frontend | React, Vite, NGINX |
| Backend | Node.js, Express |
| Database | PostgreSQL, persistent volumes |
| Containerization | Docker, Docker Compose |
| Orchestration | Kubernetes, kind |
| Traffic routing | ingress-nginx |
| Caching and queues | Redis, BullMQ |
| Search | OpenSearch |
| CI/CD | GitHub Actions, GitHub Container Registry (GHCR) |
| Infrastructure | Kubernetes manifests, shell scripts |
| Metrics and dashboards | Prometheus, Grafana |
| Logging | Fluent Bit, Loki |
| Autoscaling | Kubernetes HPA |

## Prerequisites

Install the following tools before starting:

- Docker with Docker Compose v2
- `kind`
- `kubectl`
- `curl`
- Git

Allow approximately 4 GB of free RAM for the complete stack. OpenSearch is the most resource-intensive component and may require additional memory.

**Windows users:** Use WSL2 with Docker Desktop and WSL integration enabled so the Linux shell scripts can run.

## Quick Start

### Option 1: Run with Docker Compose

Start the application and platform services:

```bash
docker compose up --build
```

Access the application and API:

- Frontend: [http://localhost:8080](http://localhost:8080)
- Backend health: [http://localhost:4000/api/health](http://localhost:4000/api/health)

### Option 2: Run with Kubernetes

Create the local `kind` cluster, build and load the application images, and deploy the Kubernetes resources:

```bash
chmod +x scripts/*.sh
./scripts/setup-kind.sh
```

Add the following entry to your hosts file:

```text
127.0.0.1 node-react.local
```

Linux: `/etc/hosts`

Windows: `C:\Windows\System32\drivers\etc\hosts`

Then open [http://node-react.local](http://node-react.local).

### Enable Observability and Autoscaling

After deploying the application to Kubernetes, run:

```bash
./scripts/setup-observability.sh
```

Start a Grafana port-forward:

```bash
kubectl -n monitoring port-forward svc/grafana 3000:3000
```

Open [http://localhost:3000](http://localhost:3000).

The configured development credentials are `admin` / `admin-dev-only`. These credentials are for local development only and must not be used in production.

## Task 1: Docker Compose and Containerization

The first stage containerizes the frontend and backend and runs the application with its supporting services.

### Start the stack

```bash
docker compose up --build
```

Verify the running containers:

```bash
docker compose ps
```

### Multi-stage Docker builds

**Backend — `Dockerfile.backend`**

- Uses a dependency stage to install production dependencies with `npm ci --omit=dev`.
- Copies only the required runtime dependencies and application source into the final image.
- Runs the application as the unprivileged `node` user.

**Frontend — `Dockerfile.frontend`**

- Uses Node.js to build the Vite application.
- Serves the compiled static assets using `nginx:alpine`.
- Excludes Node.js and source files from the final runtime image.

The `.dockerignore` file excludes unnecessary files, including `node_modules`, `.git`, documentation, manifests, and environment files, from the Docker build context.

### Configuration and secrets

The backend receives database configuration through environment variables:

```text
DB_HOST
DB_PORT
DB_USER
DB_PASSWORD
DB_NAME
```

The frontend uses `VITE_API_BASE_URL`, which Vite embeds into the application during the build. Docker Compose supplies this value through the `API_BASE_URL` build argument. Its default is `http://localhost:4000/api`, because browser requests originate from the host machine.

In Kubernetes, the frontend uses `/api` so requests pass through the same-origin Ingress.

No database password is hardcoded in the backend. `backend/src/db.js` requires explicit credentials and fails fast when they are missing.

For local development, copy `.env.example` to `.env` and override the default values as needed. Ensure `.env` remains excluded from version control.

### Networking and persistence

Services communicate over the Docker Compose network using service names, including `postgres`, `redis`, and `search`.

Database persistence uses the named volume `postgres_data`. To verify persistence:

1. Create an item through the application.
2. Stop the stack without removing volumes.
3. Start it again.
4. Confirm that the item remains available.

```bash
docker compose down
docker compose up --build
```

Do not use `docker compose down -v` during this test because that removes the named volumes.

**Evidence:** `01-compose-up.png` and `02-compose-persistence.png`.

## Task 2: Kubernetes Deployment

The second stage deploys the application to a local Kubernetes cluster using `kind`.

### Deploy the application

The recommended approach is to use the setup script:

```bash
./scripts/setup-kind.sh
```

The script creates the cluster, builds and loads the application images, installs the required Ingress controller and metrics server, and applies the application manifests.

Inspect the deployed resources:

```bash
kubectl get all -n dev
kubectl get pvc -n dev
kubectl get ingress -n dev
```

### Resource organization

Application resources are deployed in the `dev` namespace.

- `backend-service` and `postgres-service` use ClusterIP for internal communication.
- `frontend-service` exposes NodePort `30080` for direct local access.
- PostgreSQL uses a PersistentVolumeClaim backed by a hostPath PersistentVolume.
- The backend uses readiness and liveness probes.
- Application settings are stored in a ConfigMap.
- Database credentials are stored in a Kubernetes Secret.

The PostgreSQL Deployment uses the `Recreate` strategy because the volume uses `ReadWriteOnce`. `PGDATA` points to a subdirectory to avoid initialization problems with the `lost+found` directory on some filesystems.

### Health checks

The backend provides separate endpoints for different health checks:

- `/api/health/ready` — verifies that the database is reachable.
- `/api/health/live` — checks whether the application process is alive.

Readiness checks prevent traffic from reaching an unready pod, while liveness checks help Kubernetes detect an unhealthy process.

### Container images

The image naming convention is:

```text
ghcr.io/<owner>/<repository>-backend
ghcr.io/<owner>/<repository>-frontend
```

For local development, the setup script loads the images directly into `kind`. The CI/CD pipeline publishes images to GHCR and updates the deployed image tags.

**Direct frontend access:** [http://localhost:30080](http://localhost:30080)

**Evidence:** `03-kubectl-get-all-dev.png` and `04-k8s-nodeport.png`.

## Task 3: Ingress and API Gateway

The third stage introduces `ingress-nginx` to route HTTP traffic to the frontend and backend through a common hostname.

### Configure the hostname

Add the following entry to `/etc/hosts` on Linux:

```bash
echo "127.0.0.1 node-react.local" | sudo tee -a /etc/hosts
```

Apply the Ingress manifest if it has not already been deployed:

```bash
kubectl apply -n dev -f k8s/ingress-dev.yaml
```

Test the application and API:

```bash
curl http://node-react.local/api/health
```

Alternatively, test without modifying the hosts file:

```bash
curl -H "Host: node-react.local" \
  http://localhost/api/health
```

### Routing rules

The Ingress configuration routes:

- `/` to `frontend-service`.
- `/api` and `/api/*` to `backend-service`.

Two Ingress resources share the hostname: `web-ingress` and `api-ingress`. Separating them allows API-specific rate limiting without applying those limits to static frontend traffic.

### Request flow

```text
Browser
   |
   v
Ingress Controller
   |
   +---- / ----------> frontend-service
   |
   +---- /api/* -----> backend-service
                            |
                            v
                      PostgreSQL Service
                            |
                            v
                       PostgreSQL Pod
                            |
                            v
                    Persistent Volume
```

The browser resolves `node-react.local` to `127.0.0.1`. The `kind` cluster maps host ports 80 and 443 to the node running the Ingress controller.

The Ingress controller evaluates the hostname and path and forwards the request to the appropriate Kubernetes Service. The Service provides a stable network endpoint and routes traffic to eligible pod endpoints.

Within Kubernetes, CoreDNS provides service discovery. For example:

```text
backend-service.dev.svc.cluster.local
```

Pods in the same namespace can use the shorter name `backend-service`.

### Service versus Ingress versus Pod

- **Pod:** Runs the application containers and has an IP address that can change when recreated.
- **Service:** Provides a stable endpoint for a group of pods.
- **Ingress:** Defines HTTP routing rules.
- **Ingress controller:** Implements those rules and handles incoming traffic.

### Debugging Ingress failures

If the Ingress returns `502`, `503`, or `404` for API requests, check the backend endpoints and pod status:

```bash
kubectl -n dev get endpoints backend-service
kubectl -n dev get pods -l app=backend
kubectl -n dev logs deploy/backend
kubectl -n dev describe ingress api-ingress
```

Test the backend independently of the Ingress:

```bash
kubectl -n dev port-forward svc/backend-service 4000:4000
curl http://localhost:4000/api/health
```

Inspect the controller logs when necessary:

```bash
kubectl -n ingress-nginx logs \
  deploy/ingress-nginx-controller
```

Typical causes include failing readiness probes, incorrect Service selectors, incorrect target ports, unavailable database connections, and incorrect Ingress paths.

### Frontend-to-backend connectivity

The frontend must call `/api` when served through Kubernetes Ingress. It must not call `http://backend-service:4000` directly because that hostname is only resolvable inside the cluster.

Because `VITE_API_BASE_URL` is embedded at build time, rebuild the frontend with the correct value if the browser still calls the Compose API URL.

### Future microservice expansion

The current path-based routing pattern can be extended to services such as `users-service` and `orders-service`.

Potential next steps include:

- A dedicated gateway such as Kong or Envoy Gateway.
- Authentication and authorization policies.
- Per-route rate limiting and distributed tracing.
- Separate databases where appropriate.
- Asynchronous messaging through RabbitMQ or Kafka.
- A service mesh for mutual TLS and service-to-service traffic management.

**Evidence:** `05-app-node-react-local.png` and `06-api-through-ingress.png`.

## Task 4: CI/CD and Multi-Environment Deployment

The GitHub Actions workflow is defined in `.github/workflows/ci-cd.yml`.

It automates application validation, image builds, container publishing, and Kubernetes deployments across multiple environments.

### Branch-to-environment mapping

| Branch pattern | Kubernetes namespace | Ingress hostname |
|---|---|---|
| `master` | `dev` | `node-react.local` |
| `pre-release/v*` | `preprod` | `preprod.node-react.local` |
| `release/v*` | `release` | `release.node-react.local` |

### Pipeline stages

**1. Build and test**

- Install frontend and backend dependencies.
- Validate Node.js source syntax.
- Run backend unit tests with `npm test`.
- Build the frontend.

**2. Build and publish images**

- Build the backend and frontend container images.
- Tag images using the branch name and short commit SHA.
- Publish the images to GHCR on supported branch pushes.
- Run validation and build stages for pull requests without publishing images.

Example tag format:

```text
<branch>-<short-sha>
<namespace>-latest
```

Branch slashes are normalized when generating image tags.

**3. Deploy**

- Determine the target namespace and Ingress hostname.
- Update the Kubernetes manifests with the appropriate image tags.
- Adjust environment-specific PersistentVolume names and configuration.
- Apply the resources and wait for deployment rollout status.

The pipeline creates or prepares the target namespace before deploying application resources. Development-only placeholder Secrets, namespace manifests, and the fixed NodePort configuration are not applied indiscriminately to other environments.

PersistentVolumes are cluster-scoped, so the pipeline generates environment-specific names. Ingress hostnames also differ between environments to avoid conflicting host/path rules.

### Secrets and credentials

**Container registry:** The workflow uses GitHub's short-lived `GITHUB_TOKEN` to authenticate with GHCR.

**Kubernetes access:** The kubeconfig is supplied through the `KUBECONFIG_B64` GitHub Actions secret. The workflow writes the decoded configuration to `~/.kube/config` with restrictive file permissions and does not print it.

The assessment supports local-only execution: when cluster credentials are unavailable, deployment steps are skipped with a notice because a hosted GitHub Actions runner cannot ordinarily access a cluster running on a developer's laptop.

**Application credentials:** The development environment uses placeholder credentials in `k8s/app-secrets.yaml`. Pre-production and release credentials are sourced from their corresponding GitHub Environments using `DB_USER` and `DB_PASSWORD`.

In a production deployment, use an appropriate secrets-management solution, such as External Secrets or Sealed Secrets, rather than relying on development placeholders.

### GitHub configuration

Configure the following environments under **Settings → Environments**:

- `dev`
- `preprod`
- `release`

Add `KUBECONFIG_B64` where required, and configure `DB_USER` and `DB_PASSWORD` for pre-production and release. Consider requiring reviewers for release deployments.

A Kubernetes cluster pulling private images from GHCR must have suitable registry authentication. Alternatively, the packages must be publicly accessible.

### Rollback strategy

**Automatic rollback:** If a deployment rollout fails, the workflow attempts to undo the affected Deployment rollout.

**Manual rollback:**

```bash
kubectl -n <namespace> rollout history deployment/backend
kubectl -n <namespace> rollout undo deployment/backend
```

To return to a particular revision:

```bash
kubectl -n <namespace> rollout undo \
  deployment/backend --to-revision=<revision>
```

**Immutable image tags:** Commit-specific image tags make it possible to redeploy a known-good version without relying exclusively on an old ReplicaSet remaining available. Re-running a workflow for a previous commit is useful only if the workflow and registry still retain the corresponding artifacts and configuration.

**Evidence:** `07-github-actions-run.png`.

## Task 5: Platform Services

The fifth stage adds Redis, a background job queue, OpenSearch, and separate database read/write endpoints to both the Compose and Kubernetes environments.

### Service overview

| Component | Purpose | Configuration |
|---|---|---|
| Redis | Queue backend and supporting in-memory operations | `REDIS_URL` |
| BullMQ worker | Asynchronous job processing | `bullmq-worker-deployment.yaml` |
| OpenSearch | Search infrastructure | `SEARCH_URL` |
| PostgreSQL write endpoint | Handles write operations | `DB_WRITE_URL` |
| PostgreSQL read endpoint | Handles read operations | `DB_READ_URL` |

In Kubernetes, these supporting services use internal ClusterIP Services rather than publicly exposed ports. Network policies are defined in `k8s/network-policies.yaml` to restrict permitted traffic.

**Network policy note:** Enforcement depends on the cluster networking implementation. The default networking setup in `kind` does not enforce NetworkPolicy rules; a compatible CNI, such as Calico or Cilium, is required.

### Redis and background processing

The backend uses BullMQ over Redis to process jobs asynchronously.

When a client creates an item through `POST /api/items`, the backend enqueues an `item-created` job in `backend/src/queue.js`. A separate worker process, implemented in `backend/src/worker.js`, consumes the queue.

The worker runs from the same application image but uses a different command. This separation allows the API and background-processing workloads to be scaled and restarted independently.

Redis is configured with `maxmemory-policy noeviction`, as required for reliable BullMQ operation.

Check Redis health:

```bash
curl http://localhost:4000/api/health/redis
```

Inspect the worker:

```bash
docker compose logs worker
```

In Kubernetes:

```bash
kubectl -n dev logs deploy/bullmq-worker
```

### OpenSearch

OpenSearch runs as a single-node development service with its security plugin disabled. It is intended for local demonstration, not production exposure.

Check its application health endpoint:

```bash
curl http://localhost:4000/api/health/search
```

The current health check verifies connectivity. Full search indexing would require adding indexing logic to the queue consumer or another appropriate application component.

### Database read/write separation

The backend maintains separate connection pools in `backend/src/db.js`:

- `write()` routes write operations to `DB_WRITE_URL`.
- `read()` routes read operations to `DB_READ_URL`.

The local setup uses one PostgreSQL instance behind two endpoints: `postgres` and `postgres-replica` in Compose, and `postgres-service` and `postgres-read-service` in Kubernetes.

**Important limitation:** This is simulated read/write separation, not actual PostgreSQL replication. The read and write endpoints do not represent independently replicated database instances in this local configuration.

The application code is structured so that a real read replica can be introduced later through configuration and infrastructure changes, provided the target database and deployment setup are configured appropriately.

### Replication lag and consistency

With a real asynchronous PostgreSQL replica, data may take milliseconds or seconds to become visible on the reader.

Operations that require strong read-after-write consistency should use the writer, including:

- Reads immediately following a write.
- Reads within transactions that also perform writes.
- Uniqueness and balance checks that influence subsequent writes.
- Locking and idempotency operations.
- Authentication or session reads immediately following sensitive changes.

Read-heavy dashboards and other workloads that tolerate slightly stale data may use a replica.

Possible mitigations include monitoring replication lag, routing reads to the primary when lag exceeds a threshold, and temporarily directing a user's reads to the primary after a write.

**Evidence:** `08-compose-platform-services.png` and `09-k8s-worker-es-logs.png`.

## Task 6: Observability, Scaling, and Rate Limiting

The final stage adds metrics collection, dashboards, centralized logging, autoscaling, and API request limits.

### Prometheus metrics

The backend exposes a `/metrics` endpoint containing default Node.js metrics and application metrics, including:

- `http_requests_total`
- `http_request_duration_seconds`

Prometheus scrapes the backend pods in the `dev` namespace using the configured `prometheus.io/*` annotations.

The Ingress does not expose `/metrics` as a public application route. CPU and memory metrics are obtained from the Kubernetes metrics infrastructure and kubelet/cAdvisor sources.

### Grafana dashboard

Grafana is provisioned automatically using the configuration in `observability/grafana.yaml`.

The **Backend overview** dashboard includes:

- Backend CPU utilization.
- Backend memory usage.
- HTTP request rate.
- HTTP 5xx error rate.
- Request latency at the 95th percentile (p95).
- Healthy backend replica count over time.

Start port-forwarding:

```bash
kubectl -n monitoring port-forward svc/grafana 3000:3000
```

Open [http://localhost:3000](http://localhost:3000) and log in with the local development credentials configured in the manifests.

Open the dashboard under **Dashboards**.

### Alerting strategy

The following alerts are recommended for production monitoring:

| Alert | Suggested threshold | Purpose |
|---|---|---|
| High HTTP error rate | 5xx responses exceed 5% for 5 minutes | Detect user-facing failures |
| High p95 latency | p95 exceeds 500 ms for 10 minutes | Detect slow requests and dependencies |
| High CPU utilization | CPU remains above 80% of the relevant limit for 10 minutes | Detect resource pressure |
| HPA at maximum replicas | Maximum replica count reached with sustained load | Identify limited scaling headroom |
| Insufficient healthy replicas | Fewer than two healthy backend pods | Detect reduced redundancy |

Additional useful alerts include pod restarts, OOM kills, high memory usage, PostgreSQL connection saturation, replication lag, queue depth, failed jobs, and persistent-volume capacity.

The thresholds above are proposed starting points and should be tuned against real traffic and service-level objectives.

### Centralized logging with Fluent Bit and Loki

Fluent Bit runs as a DaemonSet, collecting container logs from the development namespace, enriching them with Kubernetes metadata, and forwarding them to Loki.

The backend emits JSON-formatted request logs. These can be filtered in Grafana under **Explore → Loki**.

Example queries:

```logql
{job="backend", namespace="dev", app="backend"}
  | json
  | status >= 500
```

```logql
{job="bullmq-worker"} |= "processing"
```

Check the log collector:

```bash
kubectl -n monitoring logs ds/fluent-bit
```

**Evidence:** `10-loki-log-query.png`.

### Horizontal Pod Autoscaling

The backend HPA is defined in `k8s/hpa-backend.yaml`.

Configured behavior:

- Minimum replicas: 2.
- Maximum replicas: 6.
- CPU target: 70% average utilization.
- Memory target: 80% average utilization.
- Scale-down stabilization window: 120 seconds.

The HPA relies on resource requests and the metrics server. The setup script installs the metrics server for the local cluster.

Monitor scaling:

```bash
kubectl -n dev get hpa -w
```

Generate test traffic:

```bash
./scripts/load-test.sh
```

Observe the replica count and resource utilization in Kubernetes and Grafana.

**Evidence:** `11-hpa-scaling.png`.

### API rate limiting

Rate limiting is configured on the API Ingress, rather than the frontend route.

Configured limits:

- `limit-rps: 20` requests per second per client IP.
- `limit-burst-multiplier: 5`, allowing a configured burst capacity of up to 100 requests.
- `limit-connections: 50` concurrent connections per client IP.

These values are intended to absorb short bursts while limiting excessive API traffic. They should be validated against real workloads before production use.

The frontend's static content is not subject to these API limits. Depending on the ingress-nginx configuration, excess requests may return HTTP 503 by default; `limit-req-status-code: "429"` can be used to configure HTTP 429 responses for request-rate limiting.

**Evidence:** Rate limiting is configured in the API Ingress manifest.

## Troubleshooting

### OpenSearch fails to start

OpenSearch may be terminated by the operating system if insufficient memory is available. Allow approximately 1.5 GB or more for the service, depending on the configuration.

The configuration sets `node.store.allow_mmap=false`, so changing the host's `vm.max_map_count` is not normally required. If an explicit virtual-memory mapping error persists, check the OpenSearch logs and, where appropriate, run:

```bash
sudo sysctl -w vm.max_map_count=262144
```

To start a reduced Compose stack without search:

```bash
docker compose up --build \
  postgres backend frontend redis worker
```

### Port conflicts

The Compose configuration publishes ports `8080` and `4000`. The local `kind` setup uses host ports including `80`, `443`, and `30080`.

Stop the conflicting service or adjust the port mappings before restarting.

### `node-react.local` does not resolve

Ensure the hosts file contains:

```text
127.0.0.1 node-react.local
```

Alternatively, bypass hostname resolution:

```bash
curl -H "Host: node-react.local" \
  http://localhost/api/health
```

### Kubernetes pods show `ImagePullBackOff`

The local images must be loaded into the `kind` cluster before applying the application manifests.

The setup script performs this operation. If necessary, rebuild the images and load them again:

```bash
kind load docker-image <image-name> --name <cluster-name>
```

Check pod events and image names:

```bash
kubectl -n dev describe pod <pod-name>
kubectl -n dev get pods
```

### Frontend API requests fail

Open the browser's developer tools and inspect the Network tab. Confirm that the frontend uses `/api` when running behind the Kubernetes Ingress.

If it calls `http://localhost:4000/api`, the frontend image may have been built with the Compose API URL. Rebuild it with the correct `VITE_API_BASE_URL`.

### Rate-limit responses

Repeated requests may trigger the configured Ingress rate limits. A 503 or 429 response during load testing may therefore be expected, depending on the controller configuration.

## Architecture Decisions and Trade-offs

| Decision | Reason | Production improvement |
|---|---|---|
| Plain Kubernetes manifests | Transparent and easy to review | Adopt Helm or Kustomize as environment complexity grows |
| Local `kind` cluster | Reproducible development and assessment environment | Deploy to a managed Kubernetes platform |
| hostPath persistent volume | Simple local persistence | Use a production StorageClass and suitable storage backend |
| Simulated PostgreSQL read/write endpoints | Demonstrates application-level routing | Deploy a real primary and replica with replication monitoring |
| Build-time frontend API URL | Simple Vite configuration | Use runtime configuration to reuse one image across environments |
| Manually provisioned observability manifests | Makes individual components visible | Consider kube-prometheus-stack and a managed logging platform |
| GHCR images and commit-specific tags | Traceable, repeatable image deployments | Add signing, provenance, policy enforcement, and registry retention |
| Local development credentials | Convenient for local testing | Use managed secrets and least-privilege identities |

### Code improvements

The following changes improve reliability and testability:

- Removed the default database password from `backend/src/db.js` and made database credentials mandatory.
- Separated application routes into `app.js` and process startup into `index.js`.
- Added `metrics.js` for Prometheus metrics and structured JSON request logs.
- Added backend unit tests.
- Corrected CI workflow behavior so test failures are not hidden by a command such as `npm test || true`.
- Added environment-specific deployment configuration and image-tag handling to the CI/CD pipeline.

### Future improvements

Further production hardening could include:

- Alertmanager with real notification channels.
- `kube-state-metrics` and broader Kubernetes health dashboards.
- OpenTelemetry distributed tracing.
- TLS certificates managed through cert-manager.
- External Secrets or Sealed Secrets.
- Real PostgreSQL replication with lag monitoring.
- Integration tests against `kind` in CI.
- Container image scanning with Trivy.
- PodDisruptionBudgets and pod anti-affinity for backend availability.
- Dedicated production storage and tested backup restoration procedures.
- Authentication, authorization, and more comprehensive security policies.

## Evidence and Screenshots

Screenshots documenting the six assessment stages are stored in `docs/screenshots/`.

| Screenshot | Evidence | Task |
|---|---|---|
| `01-compose-up.png` | Compose services and application running | 1 |
| `02-compose-persistence.png` | Database data retained after restart | 1 |
| `03-kubectl-get-all-dev.png` | Kubernetes application resources | 2 |
| `04-k8s-nodeport.png` | Application accessed through NodePort 30080 | 2 |
| `05-app-node-react-local.png` | Application served through Ingress | 3 |
| `06-api-through-ingress.png` | API request routed through Ingress | 3 |
| `07-github-actions-run.png` | Successful GitHub Actions run | 4 |
| `08-compose-platform-services.png` | Redis, queue worker, and search services | 5 |
| `09-k8s-worker-es-logs.png` | Kubernetes worker logs and platform connectivity | 5 |
| `10-loki-log-query.png` | Log filtering in Grafana Explore | 6 |
| `11-hpa-scaling.png` | HPA scaling under load | 6 |

The Grafana dashboard is provisioned automatically through `observability/grafana.yaml`. It can be opened using the port-forward command documented in Task 6.

### Verify screenshot references before submission

Run the following commands from the repository root:

```bash
grep -oE 'docs/screenshots/[a-z0-9-]+\.png' README.md \
  | sort -u > /tmp/needed.txt

find docs/screenshots -maxdepth 1 -type f -name '*.png' \
  | sort > /tmp/have.txt

diff -u /tmp/needed.txt /tmp/have.txt
```


## Final Submission Checklist

- [ ] Docker Compose starts successfully.
- [ ] Database persistence is verified.
- [ ] Kubernetes pods and services are healthy.
- [ ] The application and API work through Ingress.
- [ ] CI/CD tests and image builds pass.
- [ ] Environment-specific deployment configuration is verified.
- [ ] Redis, BullMQ, and OpenSearch health checks pass.
- [ ] Grafana dashboards and Loki queries work.
- [ ] HPA behavior is demonstrated under load.
- [ ] All referenced screenshots exist and show the expected results.
- [ ] No real credentials or sensitive configuration are committed.
- [ ] The final branch, repository visibility, and reviewer access are correct.

---

**Project goal:** Demonstrate the complete local delivery lifecycle of a full-stack application—from containerization and Kubernetes deployment to CI/CD, supporting platform services, observability, and autoscaling—using reproducible configuration and documented operational practices.
