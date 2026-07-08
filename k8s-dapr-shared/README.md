# `k8s-dapr-shared/` — alternate "shared sidecar" deployment topology

This directory holds an **alternate Kubernetes deployment topology** that runs the three pizza services against centralized Dapr sidecars rather than the per-pod injector model used by [`k8s/`](../k8s/).

## How it differs from `k8s/`

| Aspect | `k8s/` (default) | `k8s-dapr-shared/` (alternate) |
|---|---|---|
| Dapr sidecar | One per pod, injected via `dapr.io/enabled: "true"` annotation | Standalone `Deployment`s — one per app-id (`pizza-store-dapr`, `kitchen-service-dapr`, `delivery-service-dapr`) — each fronted by its own ClusterIP `Service` |
| Sidecar count for 3 replicas of all 3 services | 9 sidecars (one per pod) | 3 sidecars total (one per app-id) |
| App → Dapr endpoint | `localhost:3500` (in-pod) | `http://<app-id>-dapr:3500` (cross-pod via Service VIP, in-namespace) |
| Pod-level Dapr annotations | `dapr.io/app-id`, `dapr.io/app-port`, `dapr.io/enabled` | All commented out — apps reach Dapr via `DAPR_HTTP_ENDPOINT` / `DAPR_GRPC_ENDPOINT` env vars instead |
| mTLS between app and sidecar | In-pod loopback (no TLS needed) | Cross-pod — depends on cluster network policies + Dapr mTLS config |

The shared-sidecar topology trades isolation (a misbehaving sidecar affects every replica that talks to it) for lower memory overhead at scale (saves ~50MB per "extra" sidecar that would otherwise have been injected). It is most useful when a workload has many small replicas of the same app-id and the sidecar's resource footprint dominates the pod's footprint.

## Operational status

- **CI coverage (parse)**: `make k8s-validate` (kubeconform) parses these manifests on every push, so YAML / schema drift is caught immediately.
- **CI coverage (runtime)**: the weekly-scheduled `e2e-shared` job (+ `workflow_dispatch`) in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) actually RUNS this topology — `make e2e-shared` brings up KinD, installs a standalone shared daprd per app-id via the [`dapr-shared-chart`](https://github.com/dapr/dapr-shared) Helm chart, deploys these manifests, and runs the full `e2e/e2e-test.sh` suite (fan-out, state round-trip, WebSocket, OTel traces, negatives). It's off the per-PR critical path (a second full KinD e2e) but catches the runtime regressions parse-validation can't.
- **The standalone shared daprd Deployments are NOT in `apps.yaml`** — they are created at deploy time by `make k8s-shared-deploy`, which `helm install`s `dapr-shared-chart` once per app-id (`pizza-store`, `kitchen-service`, `delivery-service`). The chart's Service is named `<app-id>-dapr`, matching each app's `DAPR_HTTP_ENDPOINT`/`DAPR_GRPC_ENDPOINT`. `apps.yaml` contains only the application Deployments + Services.
- **Manual validation**: `make image-build && make e2e-shared` (or `make k8s-shared-deploy` against a cluster from `make kind-create`). The application URL surfaces via the same `pizza-store` LoadBalancer Service the default topology uses.
- **Keep `apps.yaml` in sync with `k8s/`**: it is a parallel manifest set, so changes to the default app Deployments (env vars like the OTLP tracing endpoint, the `/tmp` writable volume, resource requests, probes) must be mirrored here. Drift in any of these silently breaks the topology — five such drifts kept it non-functional until 2026-06-15.

## When to choose this topology

| Pick | Topology |
|---|---|
| You want simplicity, one sidecar per pod, full app↔sidecar isolation, and the lowest blast radius per failure | `k8s/` (default) |
| You want fewer total Dapr processes, are comfortable with the cross-pod hop, and your mTLS / network policy story is mature | `k8s-dapr-shared/` |

For new deployments, the default `k8s/` topology is the recommended starting point.
