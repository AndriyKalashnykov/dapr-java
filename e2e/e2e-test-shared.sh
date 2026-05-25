#!/usr/bin/env bash
# End-to-end test for the alternate "shared sidecar" Dapr topology
# (k8s-dapr-shared/). The runtime contract is identical to the default
# topology — pizza-store is reachable via a LoadBalancer Service, the three
# services communicate over Dapr building blocks — so this script wraps
# the canonical e2e-test.sh after `make k8s-shared-deploy` has applied
# the shared-sidecar manifests.
#
# Assumes `make k8s-shared-deploy` has already deployed the three services
# in their shared-sidecar topology to a local KinD cluster and that
# pizza-store is reachable at $GATEWAY_IP:$GATEWAY_PORT.
#
# See k8s-dapr-shared/README.md for the topology rationale.
#
# Exit 0 on all-pass, non-zero on any failure.

set -euo pipefail

# Delegate to the canonical e2e harness — the contract is identical.
# This wrapper exists so the alternate topology has a named entry point
# in the Makefile (`make e2e-shared`) and for future test divergence if
# the shared-sidecar topology ever grows topology-specific assertions
# (e.g., asserting a single dapr-shared deployment instead of N sidecars).
exec "$(dirname "$0")/e2e-test.sh" "$@"
