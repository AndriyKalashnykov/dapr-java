# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
make help                               # List available tasks on this project
make deps                               # Install build dependencies via mise (reads .mise.toml). mise is the single source of truth for binaries (Java, Maven, Node, kubectl, helm, kind, act, trivy, gitleaks)
make deps-check                         # Verify build dependencies are installed
make deps-maven                         # Install Maven from Apache archives (CI fallback when mise unavailable)
make deps-gjf                           # Download google-java-format jar
make env-check                          # Show installed tool versions
make build                              # Build project (skips tests)
make test                               # Run unit tests (Surefire, **/*Test.java)
make integration-test                   # Run integration tests (Failsafe, **/*IT.java)
make lint                               # Run Checkstyle static analysis
make format                             # Auto-format Java source (google-java-format)
make format-check                       # Verify formatting without modifying files
make trivy-fs                           # Scan filesystem for HIGH/CRITICAL vulns, secrets, misconfigs
make trivy-config                       # Scan k8s/ and k8s-dapr-shared/ for KSV findings
make secrets                            # Scan for leaked secrets (gitleaks)
make deps-prune                         # Analyze Maven dependencies (advisory)
make deps-prune-check                   # Fail if unused declared Maven dependencies exist
make static-check                       # Composite: format-check + lint + trivy-fs + trivy-config + secrets + diagrams-check + mermaid-lint + k8s-validate
make k8s-validate                       # Validate k8s/ + k8s-dapr-shared/ manifests via kubeconform (vendored OpenAPI, no cluster)
make diagrams                           # Render docs/diagrams/*.puml → docs/diagrams/out/*.png (PlantUML in Docker)
make diagrams-clean                     # Remove rendered PNGs
make diagrams-check                     # Verify committed PNGs match .puml sources (static-check gate)
make mermaid-lint                       # Lint Mermaid fenced blocks via minlag/mermaid-cli (static-check gate)
make image-build                        # Build all three service images via spring-boot:build-image and tag :e2e
make image-scan                         # Scan built images for HIGH/CRITICAL CVEs with fixes (closes Paketo/CNB Renovate blind spot)
make clean                              # Remove build artifacts
make run                                # Run the application
make ci                                 # Local CI: clean, deps, static-check, test, integration-test, build, coverage-check (cve-check is separate — run manually before a release tag)
make ci-run                             # Run GitHub Actions workflow locally via act (jobs serialized with --job)
make cve-check                          # OWASP dependency vulnerability scan (pre-tag release gate; omitted from `make ci`)
make coverage-generate                  # Generate merged unit + integration JaCoCo coverage (mvn verify -P integration-test)
make coverage-check                     # Verify merged coverage meets minimum threshold (80%)
make coverage-open                      # Open code coverage report
make kind-up                            # Bring full local KinD stack up (cluster + cloud-provider-kind + Dapr Helm + images + manifests)
make kind-down                          # Tear the stack down (remove manifests + stop cloud-provider-kind + delete cluster)
make e2e                                # Run e2e/e2e-test.sh against the LoadBalancer IP (after kind-up)
make kind-create                        # (granular) Create KinD cluster + start cloud-provider-kind + install Dapr
make kind-deploy                        # (granular) Build + load images, apply k8s manifests, wait for rollout + LB IP
make kind-undeploy                      # (granular) Delete application manifests from cluster
make kind-destroy                       # (granular) Stop cloud-provider-kind + delete KinD cluster
make print-deps-updates                 # Print project dependencies updates
make update-deps                        # Update project dependencies to latest releases
make renovate-validate                  # Validate Renovate configuration
make pre-release                        # Runs cve-check (advisory) + image-scan (strict). Required before `make release`
make release VERSION=x.y.z              # Create a semver release tag (auto-runs `make pre-release`)
```

### Test pyramid

| Layer | Command | Scope | Runtime |
|-------|---------|-------|---------|
| Unit | `make test` | `**/*Test.java` via Surefire, in-memory PubSub Dapr sidecars | ~30 s |
| Integration | `make integration-test` | `**/*IT.java` via Failsafe + Testcontainers. Four ITs in pizza-store: `PizzaStoreStateStoreIT` (real `kvstore` round-trip), `KitchenInvocationIT` / `DeliveryInvocationIT` (Dapr service-invocation HTTP contract, WireMock receiver), `WebSocketBroadcastIT` (STOMP `/topic/events` broadcast). Surefire + Failsafe exec files are merged by `jacoco:merge` to give accurate coverage. | ~1 min |
| E2E | `make e2e` | `e2e/e2e-test.sh` against KinD (cloud-provider-kind LoadBalancer + Dapr Helm + Redis-backed pubsub/state store). Asserts health, order placement, full cross-service fan-out to `Status.completed`, state-store round-trip, malformed-body negative case. | ~2 min |

### Single module commands

```bash
mvn -B test -Ddependency-check.skip=true -pl pizza-delivery
mvn -B test -Ddependency-check.skip=true -pl pizza-kitchen
mvn -B test -Ddependency-check.skip=true -pl pizza-store
```

## Architecture

Three Spring Boot 4 microservices communicating via Dapr building block APIs:

- **pizza-store** — Frontend + backend. Places orders via Dapr State Store, invokes kitchen/delivery via Dapr service-to-service invocation, receives event updates via Dapr PubSub, pushes to browser via WebSocket.
- **pizza-kitchen** — Receives orders on `PUT /prepare`, simulates cooking (5s + random 0-15s per pizza), publishes `ORDER_IN_PREPARATION` and `ORDER_READY` events via Dapr PubSub.
- **pizza-delivery** — Receives orders on `PUT /deliver`, simulates delivery in 3s stages, publishes `ORDER_ON_ITS_WAY` (3x) and `ORDER_COMPLETED` events via Dapr PubSub.

All services publish events using `DaprClient.publishEvent()` to a configurable PubSub component (default: `pubsub`) on topic `topic`. The PizzaStore subscribes to these events and updates order state.

### Dapr APIs used

| API | Usage | Config |
|-----|-------|--------|
| PubSub | Event-driven communication between services | `PUB_SUB_NAME` (default: `pubsub`), `PUB_SUB_TOPIC` (default: `topic`) |
| State Store | Order persistence in pizza-store | `STATE_STORE_NAME` (default: `kvstore`) |
| Service Invocation | pizza-store calls kitchen and delivery | `DAPR_HTTP_ENDPOINT` (default: `http://localhost:3500`) |

## Testing Pattern

Tests use `@ImportTestcontainers` (Spring Boot + Testcontainers 2.x) with a containerized Dapr sidecar. No Dapr installation required — just Docker.

Key pattern across all test classes:

```java
// pizza-kitchen and pizza-delivery use DEFINED_PORT with an ephemeral port
// allocated before DaprContainer initializes (no hard-coded 8080 — parallel
// test + integration-test jobs on one host would collide). pizza-store tests
// use RANDOM_PORT since nothing routes back into them.
@SpringBootTest(classes = PizzaKitchenAppTest.class, webEnvironment = DEFINED_PORT)
@ImportTestcontainers
public class PizzaKitchenTest {
    private static final int APP_PORT = TestSocketUtils.findAvailableTcpPort();

    static DaprContainer dapr = new DaprContainer(DaprContainer.getDefaultImageName())
        .withAppName("local-dapr-app")
        .withAppPort(APP_PORT)                                        // sidecar routes here
        .withAppChannelAddress("host.testcontainers.internal")
        .withExtraHost("host.testcontainers.internal", "host-gateway")
        .withComponent(new Component("pubsub", "pubsub.in-memory", "v1", ...))
        .withSubscription(new Subscription("subscription", "pubsub", "topic", "/events"));

    @DynamicPropertySource
    static void props(DynamicPropertyRegistry r) {
        r.add("server.port", () -> APP_PORT);                         // Spring binds here
        r.add("dapr.grpc.port", dapr::getGrpcPort);
        r.add("dapr.http.port", dapr::getHttpPort);
    }

    @BeforeEach
    void setRestAssuredPort() {
        io.restassured.RestAssured.port = APP_PORT;                   // RestAssured default is 8080
    }
}
```

- **Ephemeral `APP_PORT`** — `TestSocketUtils.findAvailableTcpPort()` runs at class-load time before `DaprContainer` initializes. Feeds both `.withAppPort(APP_PORT)` (so the sidecar knows where to route) and `server.port` via `@DynamicPropertySource` (so embedded Tomcat binds the same port). Required for parallel CI jobs / concurrent Surefire+Failsafe on one host. See `/makefile` skill §"Dynamic port allocation".
- **`withExtraHost("host.testcontainers.internal", "host-gateway")`** — Required for container-to-host networking in CI. Uses Docker's built-in host-gateway instead of Testcontainers' SSHD proxy.
- **In-memory PubSub** — Tests use `pubsub.in-memory` (no Kafka). Only needed for delivery/kitchen tests that verify event flow.
- **System properties** — `DaprClientBuilder` reads `dapr.grpc.port`/`dapr.http.port` from system properties (not Spring Environment), so tests set both via `@DynamicPropertySource` and `@BeforeEach`.
- **SubscriptionsRestController** — Test helper in delivery/kitchen that captures CloudEvents on `POST /events` for assertion.
- **WireMock** — pizza-store tests use WireMockContainer with `kitchen-service-stubs.json` to mock downstream services. `KitchenInvocationIT`/`DeliveryInvocationIT` also override `DAPR_HTTP_ENDPOINT` to a WireMock receiver to assert the Dapr invoke HTTP contract (single-app DaprContainer limitation — see Upgrade Backlog).

## Key Dependency Versions

Managed centrally in the parent `pom.xml` `<properties>` block. The Dapr SDK version (`dapr.version`) drives both `dapr-spring-boot-4-starter` and `testcontainers-dapr`. Dependency updates are automated via Renovate (`renovate.json`) with automerge enabled on all update types — platform automerge with squash strategy, vulnerability alerts fast-tracked with zero delay.

## Key Config

Permanent design rules and operational constraints. Each one is load-bearing — read before changing the related target / manifest.

### Release workflow

- `make ci` deliberately omits `cve-check` and `image-scan` because both are slow. They run via `make pre-release` (auto-invoked by `make release`):
  - Both gates are strict — the previous `timeout 300` + `|| true` workaround was removed when dependency-check 12.2.2 (2026-05-03) shipped the upstream fix for the NVD nanosecond-timestamp deserializer bug (PR #8427).
  - `image-scan` catches Paketo helper Go-stdlib CVEs that `trivy-fs` (workspace) and `cve-check` (Maven deps) both miss. `.trivyignore` documents currently-accepted Paketo-upstream CVEs with tracker URLs.
- `cve-check` also runs in CI on tag pushes, weekly cron (Mon 06:00 UTC), and `workflow_dispatch`.
- The `cve-check` Make recipe routes `NVD_API_KEY` through `~/.m2/settings.xml` + `-DnvdApiServerId=nvd` (written via `printf` — bash builtin, no argv). The flag form `-DnvdApiKey=$$NVD_API_KEY` would leak the value via `ps -ef` / `/proc/<pid>/cmdline` for the entire ~30-min plugin lifetime.

### Image publishing

- GHCR images publish under the **repo-namespace** `ghcr.io/<owner>/<repo>/<package>`, not the user-namespace `ghcr.io/<owner>/<package>`. `GITHUB_TOKEN` can create new packages in the repo-namespace on first push; in the user-namespace it cannot (returns `denied: permission_denied: write_package` regardless of `packages: write` scope or OCI source label) — first publish then requires a PAT.
- Touched by: `.github/workflows/ci.yml` `docker` job (`REPO` segment in image-ref construction), `k8s/pizza-*.yaml` + `k8s-dapr-shared/apps.yaml` `image:` lines, `Makefile` `kind-deploy` `sed` override.
- Repo `default_workflow_permissions` must be `read` or `write` (both work for repo-namespace packages).
- Cosign keyless OIDC (Sigstore Fulcio) signs each pushed digest. Verify with the recipe in [README §CI/CD](README.md#cicd).

### Local KinD multi-cluster constraint

Running multiple KinD clusters on the shared default `kind` Docker network causes `dapr-operator` CrashLoopBackOff with `dial tcp 10.96.0.1:443: i/o timeout` — both clusters' kube-proxies lay down DNAT rules for the same in-cluster API ClusterIP (`10.96.0.1:443`), and the rule sets collide on the host bridge.

- This is the documented constraint of multi-cluster KinD on a shared network, not a bug in Helm or Dapr (reproduces identically under Helm 3.20.2 and 4.1.4). CI runners always have a clean Docker daemon, so GitHub Actions e2e is unaffected.
- `make kind-create` warns when sibling `*-control-plane` containers are present on the `kind` network.
- Workarounds: `kind delete cluster --name <other>` before `make e2e`, or use a per-cluster network via `KIND_EXPERIMENTAL_DOCKER_NETWORK`.
- `make kind-destroy` prunes `kindccm-*` orphan Envoy sidecars left behind by `cloud-provider-kind`. Without that, a subsequent `kind-up` can land on an orphan's IP and inherit its stale Envoy config (pointed at dead pods from previous runs), producing "connection reset by peer" on the first curl.

### Image publishing (multi-arch)

- `docker` job is a per-service-per-arch matrix (6 runners): `{pizza-store, pizza-kitchen, pizza-delivery} × {amd64, arm64}`. arm64 runs on `ubuntu-24.04-arm` because Paketo CNB `spring-boot:build-image` builds only the host arch (no cross-build).
- Each runner pushes its per-arch tag `ghcr.io/<owner>/<repo>/<svc>:<version>-<arch>`.
- The downstream `docker-manifest` job assembles a multi-arch manifest list with `docker buildx imagetools create`, pushes both `:<version>` and `:latest` to GHCR, and signs the manifest digest with cosign keyless OIDC. A single signature covers both archs.

### Test coverage extras

- E2E asserts the WebSocket broadcast end-to-end via `websocat` (mise tool, `cargo:websocat 1.14.0`) — regression guard for the PUBLIC_IP-hardcoded bug retired 2026-04-26.
- `make k8s-validate` (kubeconform) validates `k8s/` and `k8s-dapr-shared/` against vendored OpenAPI on every push, so drift in the unused alternate "shared sidecar" topology surfaces immediately.
- `e2e` job runs an OWASP ZAP baseline DAST scan against the LB-exposed pizza-store after the assertion suite passes (`continue-on-error: true` while baseline budget is established).

### Documentation drift across Renovate-driven version bumps

`docs/diagrams/c4-container.puml`, `docs/diagrams/c4-deployment.puml`, and the README "Tech Stack" table hardcode framework/version strings (Spring Boot, Java, Dapr Helm chart). Renovate cannot update technology strings inside `Container(...)` PUML labels or README prose — both files drift silently after a Spring Boot or Dapr patch bump lands. After any such Renovate-driven bump, run `/architecture-diagrams` and `/readme` to re-sync these strings; do NOT rely on the diagrams-check or mermaid-lint gates to catch this — they validate parse, not content.

## Upgrade Backlog

Last reviewed: 2026-05-07 (no actionable items outside Renovate; backlog unchanged from 2026-05-05 except K8s 1.36 GA signal noted below)

- [ ] **Maven 4.0 migration** — plan when Maven 4.0 reaches GA (currently RC-5)
- [ ] **Spring Boot 4.0 → 4.1 migration** — Spring Boot 4.0 OSS support ends **2026-12-31**. 4.1 GA is expected Q4 2026 (currently 4.1.0-RC1). Project commits to staying on the Spring Boot 4.x line; start the 4.0 → 4.1 migration plan ~Q3 2026 to land before EOL.
- [ ] **Alpha dependencies** — `opentelemetry-instrumentation-bom-alpha`, `wiremock-testcontainers` 1.0-alpha-15. Track GA releases.
- [ ] **`dapr-spring-boot-4-starter` 1.17.3 GA on Maven Central** — currently `1.17.3-rc-1` only. Bump `dapr.version` (and `testcontainers-dapr.version`, since they're the same property) when GA lands. Runtime/Helm chart is already on 1.17.6 — runtime-ahead-of-SDK is normal Dapr Java cadence.
- [ ] **WireMock 4.0 GA** — currently `4.0.0-beta.10` upstream; project on stable `3.13.2`. Watch for 4.0 GA before bumping.
- [ ] **Single-app DaprContainer limitation** — upstream-blocked: `dapr/java-sdk:testcontainers-dapr/.../DaprContainer.java` exposes only single `appName/appPort/appChannelAddress` fields (no peer-app registration). Workaround in `KitchenInvocationIT` / `DeliveryInvocationIT`: override `DAPR_HTTP_ENDPOINT` to a WireMock receiver — verifies the emitted HTTP contract (verb, path, body) but bypasses the sidecar invoke hop. The full sidecar→app→sidecar path is covered by the KinD e2e via `make e2e`. Re-wire once upstream adds multi-app support.
- [ ] **kindest/node v1.36 + kubectl 1.36** — Kubernetes 1.36.0 GA'd 2026-05-07. KinD 0.31.0 (2025-12-18) currently ships node `v1.35.0` (latest patch v1.35.1); a `kindest/node:v1.36.x` typically follows the K8s GA by 2-4 weeks. Bump `kubectl` from 1.35.4 to 1.36.x only after the matching node image lands so cluster ↔ kubectl skew stays at +1 minor max.
- [ ] **`zaproxy/action-baseline` v0.16+** — pinned to `v0.15.0` (2025-10-24). Bump after the first ZAP run produces a clean baseline so reports stay comparable across runs.

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
