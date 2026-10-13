# Evidence checklist

Screenshots must come from your real run. Save them in this folder with these names.

| File | How to capture |
|---|---|
| `kubectl-get-all-dev.png` | `kubectl get all -n dev` |
| `app-node-react-local.png` | Browser at http://node-react.local with an item added |
| `grafana-dashboard.png` | `kubectl -n monitoring port-forward svc/grafana 3000:3000`, then Dashboards, Backend overview (run `scripts/load-test.sh` first so the panels have data) |
| `loki-query.png` | Grafana, Explore, Loki: `{job="backend"}` |
| `github-actions-pass.png` | Actions tab, a green `CI/CD` run |
| `hpa.png` (optional) | `kubectl -n dev get hpa -w` while running `scripts/load-test.sh` |
