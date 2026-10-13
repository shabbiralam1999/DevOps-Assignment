#!/usr/bin/env bash
# One command: kind cluster + ingress-nginx + metrics-server + local images + app in namespace "dev"
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=platform
BACKEND_IMAGE=ghcr.io/shabbiralam1999/node-react-postgres-platform-assessment-backend:dev
FRONTEND_IMAGE=ghcr.io/shabbiralam1999/node-react-postgres-platform-assessment-frontend:dev

if ! kind get clusters | grep -qx "$CLUSTER"; then
  cat <<YAML | kind create cluster --name "$CLUSTER" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - { containerPort: 80, hostPort: 80, protocol: TCP }
      - { containerPort: 443, hostPort: 443, protocol: TCP }
      - { containerPort: 30080, hostPort: 30080, protocol: TCP }   # frontend NodePort
YAML
fi

echo ">> ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s

echo ">> metrics-server (needed by the HPA)"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

echo ">> build and load images (API base URL defaults to /api: same origin through the Ingress)"
docker build -f Dockerfile.backend  -t "$BACKEND_IMAGE" .
docker build -f Dockerfile.frontend -t "$FRONTEND_IMAGE" .
kind load docker-image "$BACKEND_IMAGE" "$FRONTEND_IMAGE" --name "$CLUSTER"

echo ">> deploy app (namespace dev)"
kubectl apply -f k8s/namespace-dev.yaml
kubectl apply -n dev -f k8s/
for d in postgres redis search backend frontend bullmq-worker; do
  kubectl -n dev rollout status deployment/$d --timeout=300s
done

echo
echo "Add this line to your hosts file (Linux/macOS: /etc/hosts, Windows: C:\\Windows\\System32\\drivers\\etc\\hosts):"
echo "127.0.0.1 node-react.local"
echo "Then open http://node-react.local  (or http://localhost:30080 through the NodePort)"
