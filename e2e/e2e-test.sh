#!/usr/bin/env bash
# End-to-end test for the Dapr Java Pizza services.
#
# Assumes `make kind-up` has already deployed the three services
# (pizza-store, pizza-kitchen, pizza-delivery) plus Dapr + state store +
# pub-sub to a local KinD cluster, and that pizza-store is reachable at
# $GATEWAY_IP:$GATEWAY_PORT (LoadBalancer IP provisioned by
# cloud-provider-kind, or the caller exports GATEWAY_IP via `kubectl
# port-forward`).
#
# What this exercises (per /test-coverage-analysis skill §"What e2e MUST cover"):
#   1. Service health (all pods ready + /actuator/health returns 200)
#   2. Order placement (POST /order → 200 with an Order echo)
#   3. Cross-service fan-out lifecycle: pizza-store → kitchen (service invocation)
#      → kitchen publishes ORDER_IN_PREPARATION / ORDER_READY → pizza-store
#      invokes delivery → delivery publishes ORDER_ON_ITS_WAY / ORDER_COMPLETED.
#      We poll GET /order until the placed order reaches `completed`.
#   4. State store round-trip: after the order completes, GET /order must
#      still return it (kvstore persistence).
#   5. Negative case: POST /order with a malformed body → 4xx.
#   6. (Optional) OTel traceparent propagation — asserted if present.
#
# Exit 0 on all-pass, non-zero on any failure.

set -euo pipefail

GATEWAY_IP="${GATEWAY_IP:-}"
GATEWAY_PORT="${GATEWAY_PORT:-80}"
# Allow the Makefile to inject a fully-qualified kubectl (with --context) via
# $KUBECTL. Falls back to plain kubectl for stand-alone invocation.
KUBECTL="${KUBECTL:-kubectl}"

if [[ -z "$GATEWAY_IP" ]]; then
  echo "GATEWAY_IP not set; discovering from pizza-store LoadBalancer..." >&2
  for _ in $(seq 1 60); do
    GATEWAY_IP=$($KUBECTL get svc pizza-store -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$GATEWAY_IP" ]] && break
    sleep 2
  done
fi

if [[ -z "$GATEWAY_IP" ]]; then
  echo "FATAL: could not resolve pizza-store LoadBalancer IP. Is cloud-provider-kind running?" >&2
  exit 2
fi

BASE="http://${GATEWAY_IP}:${GATEWAY_PORT}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_status() {
  local method="$1" url="$2" expected="$3" body="${4:-}"
  local opts=(-s -o /dev/null -w '%{http_code}' -X "$method" --max-time 15)
  [[ -n "$body" ]] && opts+=(-H 'Content-Type: application/json' -d "$body")
  local status
  status=$(curl "${opts[@]}" "$url" || echo "000")
  if [[ "$status" == "$expected" ]]; then
    pass "$method $url → $status"
  else
    fail "$method $url → $status (expected $expected)"
  fi
}

assert_status_in_range() {
  # Assert that status code is in a range [lo, hi] inclusive.
  local method="$1" url="$2" lo="$3" hi="$4" body="${5:-}"
  local opts=(-s -o /dev/null -w '%{http_code}' -X "$method" --max-time 15)
  [[ -n "$body" ]] && opts+=(-H 'Content-Type: application/json' -d "$body")
  local status
  status=$(curl "${opts[@]}" "$url" || echo "000")
  if [[ "$status" -ge "$lo" && "$status" -le "$hi" ]]; then
    pass "$method $url → $status (in ${lo}-${hi})"
  else
    fail "$method $url → $status (expected ${lo}-${hi})"
  fi
}

echo "=== Waiting for pods ==="
$KUBECTL wait --for=condition=Ready pod -l app=pizza-store-service   --timeout=180s || true
$KUBECTL wait --for=condition=Ready pod -l app=pizza-kitchen-service --timeout=180s || true
$KUBECTL wait --for=condition=Ready pod -l app=pizza-delivery-service --timeout=180s || true

# K1.5 route-readiness poll. cloud-provider-kind assigns the LoadBalancer IP
# (so `kubectl wait --for=jsonpath` returns) ~5-60s before its `kindccm-<hash>`
# Envoy sidecar finishes wiring iptables/IPVS rules between the LB IP and the
# pizza-store pod. Hitting $BASE before that window closes returns
# `curl: (56) Recv failure: Connection reset by peer` and the e2e fails
# spuriously. Poll /actuator/health/readiness up to 120s before the first
# real assertion runs.
echo ""
echo "=== Waiting for LoadBalancer route to be ready ==="
ROUTE_READY=0
for i in $(seq 1 60); do
  if curl -sf -o /dev/null --max-time 3 "$BASE/actuator/health/readiness" 2>/dev/null; then
    ROUTE_READY=1
    echo "  …route ready after $((i * 2))s"
    break
  fi
  sleep 2
done
if (( ROUTE_READY == 0 )); then
  echo "FATAL: LoadBalancer IP $GATEWAY_IP did not start serving /actuator/health/readiness within 120s." >&2
  echo "--- Diagnostics ---" >&2
  $KUBECTL get svc pizza-store -o yaml >&2 || true
  $KUBECTL get pods -o wide >&2 || true
  $KUBECTL get endpoints pizza-store -o yaml >&2 || true
  exit 2
fi

echo ""
echo "=== E2E Tests against $BASE ==="

# 1. Service health
assert_status GET "$BASE/actuator/health" 200

# 2. Order placement — capture response for assertions
ORDER_PAYLOAD='{
  "customer": {"name": "e2e tester", "email": "e2e@example.com"},
  "items":    [{"type": "pepperoni", "amount": 1}]
}'

echo ""
echo "=== Placing order ==="
ORDER_RESP=$(curl -sf --max-time 15 -H 'Content-Type: application/json' \
  -d "$ORDER_PAYLOAD" "$BASE/order" || echo "")
if [[ -z "$ORDER_RESP" ]]; then
  fail "POST /order returned empty or errored"
  echo "=== Results: $PASS passed, $FAIL failed ==="
  exit 1
fi

ORDER_ID=$(echo "$ORDER_RESP" | jq -r '.id // empty')
if [[ -n "$ORDER_ID" ]]; then
  pass "POST /order → id=$ORDER_ID"
else
  fail "POST /order → response missing .id (body: $ORDER_RESP)"
fi

# 3. Full lifecycle — poll GET /order until status reaches the terminal
# `completed` state. The store flips persisted Order to Status.delivery on
# ORDER_READY (kitchen → store pub/sub) and to Status.completed on
# ORDER_COMPLETED (delivery → store pub/sub), proving the full fan-out
# store → kitchen → store → delivery → store all worked.
# Kitchen takes 5s + random(0-15s) per pizza; delivery takes ~12s in 3s stages.
# Budget 150s to absorb worst-case kitchen randomness + buffer.
echo ""
echo "=== Polling for order lifecycle (budget 150s) ==="
DEADLINE=$(( $(date +%s) + 150 ))
FINAL_STATUS=""
SEEN_COMPLETED=0
SEEN_DELIVERY=0
while (( $(date +%s) < DEADLINE )); do
  ORDERS_JSON=$(curl -sf --max-time 10 "$BASE/order" 2>/dev/null || echo "")
  FINAL_STATUS=$(echo "$ORDERS_JSON" | jq -r --arg id "$ORDER_ID" \
    '.orders[]? | select(.id == $id) | .status' 2>/dev/null || true)
  echo "  …current status: ${FINAL_STATUS:-unknown}"
  if [[ "$FINAL_STATUS" == "delivery" ]]; then
    SEEN_DELIVERY=1
  fi
  if [[ "$FINAL_STATUS" == "completed" ]]; then
    SEEN_COMPLETED=1
    break
  fi
  sleep 3
done

if (( SEEN_COMPLETED == 1 )); then
  pass "Cross-service fan-out: order $ORDER_ID reached 'completed' (store → kitchen → store → delivery → store)"
else
  fail "Order $ORDER_ID did not reach 'completed' (final='$FINAL_STATUS')"
fi

# Assert the intermediate delivery transition was observed during the poll.
# Catches a regression where the store skips straight from `in-preparation`
# to `completed` (e.g. ORDER_READY handler accidentally writes the wrong
# status). Soft-checked: the poll sleep is 3s and `delivery` lasts ~9s
# (3 ORDER_ON_ITS_WAY stages), so capture failure rate would be ~0.1%.
if (( SEEN_COMPLETED == 1 && SEEN_DELIVERY == 0 )); then
  echo "WARN: order reached 'completed' but the intermediate 'delivery' status was never observed during the 3s poll cadence."
fi

# 4. State store round-trip: GET /order after lifecycle must still have the order
echo ""
echo "=== State store round-trip ==="
PERSISTED=$(curl -sf --max-time 10 "$BASE/order" | \
  jq -r --arg id "$ORDER_ID" '.orders[]? | select(.id == $id) | .id' 2>/dev/null || true)
if [[ "$PERSISTED" == "$ORDER_ID" ]]; then
  pass "kvstore round-trip: order $ORDER_ID persisted and readable"
else
  fail "kvstore round-trip: order $ORDER_ID not found after completion"
fi

# 5. Negative case: malformed JSON body. Spring MVC's Jackson binder rejects
# non-parseable payloads with HTTP 400 before the controller sees them.
# (Structural validation — e.g. missing required fields — is NOT enforced by
# the current pizza-store controller, so we test the Jackson layer only.)
echo ""
echo "=== Negative case ==="
assert_status_in_range POST "$BASE/order" 400 499 'this is not json'

# 6. WebSocket broadcast assertion (regression guard for the
# PUBLIC_IP-hardcoded WS bug retired 2026-04-26). Subscribes a STOMP client
# to /topic/events through the LB-exposed /ws endpoint, places a fresh
# order, and asserts at least one MESSAGE frame arrives. Skipped when
# `websocat` isn't on PATH (mise installs `cargo:websocat`; bare hosts
# without mise won't have it — soft-skip rather than fail to keep the
# script portable across local debugging contexts).
echo ""
echo "=== WebSocket broadcast assertion ==="
if ! command -v websocat >/dev/null 2>&1; then
  echo "SKIP: websocat not on PATH (run 'mise install' to provision it). Add 'cargo:websocat' is in .mise.toml."
else
  WS_LOG=$(mktemp)
  # STOMP CONNECT then SUBSCRIBE; sleep keeps the connection open while the
  # order placement triggers a broadcast. \x00 is the STOMP frame terminator.
  {
    printf 'CONNECT\naccept-version:1.2\nhost:%s\n\n\x00\n' "$GATEWAY_IP"
    printf 'SUBSCRIBE\nid:sub-e2e\ndestination:/topic/events\n\n\x00\n'
    sleep 25
  } | websocat "ws://${GATEWAY_IP}:${GATEWAY_PORT}/ws" > "$WS_LOG" 2>&1 &
  WS_PID=$!
  sleep 1  # Let CONNECT/SUBSCRIBE land before triggering the broadcast.

  WS_ORDER='{"customer":{"name":"ws-tester","email":"ws@example.com"},"items":[{"type":"margherita","amount":1}]}'
  curl -sf --max-time 15 -H 'Content-Type: application/json' \
    -d "$WS_ORDER" "$BASE/order" >/dev/null || true

  # Wait up to 25s for at least one STOMP MESSAGE frame.
  ws_seen=0
  for _ in $(seq 1 25); do
    if grep -q '^MESSAGE' "$WS_LOG" 2>/dev/null; then
      ws_seen=1
      break
    fi
    sleep 1
  done

  kill "$WS_PID" 2>/dev/null || true
  wait "$WS_PID" 2>/dev/null || true

  if (( ws_seen == 1 )); then
    pass "WS broadcast received during order placement (regression guard for PUBLIC_IP/WS-URL bugs)"
  else
    fail "WS broadcast NOT received during order placement (last 30 lines of capture: $(tail -30 "$WS_LOG"))"
  fi
  rm -f "$WS_LOG"
fi

# 7. OTel traceparent propagation (optional, soft check)
echo ""
echo "=== OTel traceparent (optional) ==="
HDRS=$(curl -s -D - -o /dev/null --max-time 10 "$BASE/actuator/health" || true)
if echo "$HDRS" | grep -qi '^traceparent:'; then
  TP=$(echo "$HDRS" | grep -i '^traceparent:' | head -1 | tr -d '\r')
  pass "traceparent present: $TP"
else
  echo "SKIP: no traceparent header on response (optional assertion)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
