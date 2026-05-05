# `k8s-dapr-shared/` — alternate "shared sidecar" deployment topology

This directory holds an **alternate Kubernetes deployment topology** that runs the three pizza services against centralized Dapr sidecars rather than the per-pod injector model used by [`k8s/`](../k8s/).

## How it differs from `k8s/`

| Aspect | `k8s/` (default) | `k8s-dapr-shared/` (alternate) |
|---|---|---|
| Dapr sidecar | One per pod, injected via `dapr.io/enabled: "true"` annotation | Standalone `Deployment`s — one per app-id (`pizza-store-dapr`, `kitchen-service-dapr`, `delivery-service-dapr`) — each fronted by its own ClusterIP `Service` |
| Sidecar count for 3 replicas of all 3 services | 9 sidecars (one per pod) | 3 sidecars total (one per app-id) |
| App → Dapr endpoint | `localhost:3500` (in-pod) | `http://<app-id>-dapr.default.svc.cluster.local:3500` (cross-pod via Service VIP) |
| Pod-level Dapr annotations | `dapr.io/app-id`, `dapr.io/app-port`, `dapr.io/enabled` | All commented out — apps reach Dapr via `DAPR_HTTP_ENDPOINT` / `DAPR_GRPC_ENDPOINT` env vars instead |
| mTLS between app and sidecar | In-pod loopback (no TLS needed) | Cross-pod — depends on cluster network policies + Dapr mTLS config |

The shared-sidecar topology trades isolation (a misbehaving sidecar affects every replica that talks to it) for lower memory overhead at scale (saves ~50MB per "extra" sidecar that would otherwise have been injected). It is most useful when a workload has many small replicas of the same app-id and the sidecar's resource footprint dominates the pod's footprint.

## Operational status

- **CI coverage**: `make k8s-validate` (kubeconform) parses these manifests on every push, so YAML / schema drift is caught immediately.
- **E2E coverage**: `make e2e` exercises the **default** `k8s/` topology only. The shared-sidecar topology is **not** asserted end-to-end in CI — wall-clock cost of running both topologies on every push isn't justified for a reference-implementation project.
- **Manual validation**: use `make k8s-shared-deploy` (defined in the root [`Makefile`](../Makefile)) to deploy this topology against a running KinD cluster created via `make kind-create`. The application URL surfaces via the same `pizza-store` LoadBalancer Service the default topology uses, so the existing `e2e/e2e-test.sh` script works against it too.

## When to choose this topology

| Pick | Topology |
|---|---|
| You want simplicity, one sidecar per pod, full app↔sidecar isolation, and the lowest blast radius per failure | `k8s/` (default) |
| You want fewer total Dapr processes, are comfortable with the cross-pod hop, and your mTLS / network policy story is mature | `k8s-dapr-shared/` |

For new deployments, the default `k8s/` topology is the recommended starting point.
