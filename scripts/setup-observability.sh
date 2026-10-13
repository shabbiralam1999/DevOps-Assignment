#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
kubectl apply -f observability/namespace-monitoring.yaml
kubectl apply -f observability/
for d in prometheus loki grafana; do
  kubectl -n monitoring rollout status deployment/$d --timeout=180s
done
kubectl -n monitoring rollout status daemonset/fluent-bit --timeout=180s
echo "Grafana:    kubectl -n monitoring port-forward svc/grafana 3000:3000   (admin / admin-dev-only)"
echo "Prometheus: kubectl -n monitoring port-forward svc/prometheus 9090:9090"
