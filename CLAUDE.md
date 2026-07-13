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
make check-java-alignment               # Fail-fast precheck: Java major matches across .mise.toml, .java-version, pom.xml (java.version + maven.compiler.{source,target})
make check-env                          # STOPPER gate: fail if the committed .env.example source-of-truth is missing (wired into static-check)
make check-ports                        # Fail early naming the holder if a fixed host port in $(CHECK_PORTS) is bound (used by run + e2e)
make static-check                       # Composite: check-java-alignment + check-env + format-check + lint + trivy-fs + trivy-config + secrets + diagrams-check + mermaid-lint + k8s-validate + cve-check-selftest
make k8s-validate                       # Validate k8s/ + k8s-dapr-shared/ manifests via kubeconform (vendored OpenAPI, no cluster)
make diagrams                           # Render docs/diagrams/*.puml → docs/diagrams/out/*.png (PlantUML in Docker)
make diagrams-clean                     # Remove rendered PNGs
make diagrams-check                     # Verify committed PNGs match .puml sources (static-check gate)
make mermaid-lint                       # Lint Mermaid fenced blocks via minlag/mermaid-cli (static-check gate)
make image-build                        # Build all three service images via spring-boot:build-image and tag :e2e
make image-scan                         # Scan built images for HIGH/CRITICAL CVEs with fixes (closes Paketo/CNB Renovate blind spot)
make image-test                         # Validate Paketo CNB image contract (USER nonroot, entrypoint, layered-JAR layout) via container-structure-test against compose/structure-test/paketo.yaml
make clean                              # Remove build artifacts
make run                                # Run the application
make ci                                 # Local CI: clean, deps, static-check, coverage-generate (Surefire + Failsafe + JaCoCo merge), coverage-check, build. cve-check and image-scan run via `make pre-release`.
make ci-run                             # Run GitHub Actions workflow locally via act (jobs serialized with --job; skips e2e/cve-check/ci-pass)
make cve-check                          # OWASP dependency vulnerability scan via scripts/cve-check.sh (NVD + OSS Index; self-healing — see Key Config; pre-tag release gate; omitted from `make ci`)
make cve-check-selftest                 # Mutation-prove the cve-check log classifiers (real-CVE/corrupt/503), no network; wired into static-check
make coverage-generate                  # Generate merged unit + integration JaCoCo coverage (mvn verify -P integration-test)
make coverage-check                     # Verify merged coverage meets minimum threshold (80%)
make coverage-open                      # Open code coverage report
make kind-up                            # Bring full local KinD stack up (cluster + cloud-provider-kind + Dapr Helm + images + manifests)
make kind-down                          # Tear the stack down (remove manifests + stop cloud-provider-kind + delete cluster)
make e2e                                # Bring kind-up + run e2e/e2e-test.sh against the LoadBalancer IP (auto-creates cluster)
make kind-create                        # (granular) Create KinD cluster + start cloud-provider-kind + install Dapr
make kind-deploy                        # (granular) Build + load images, apply k8s manifests, wait for rollout + LB IP
make kind-undeploy                      # (granular) Delete application manifests from cluster
make kind-destroy                       # (granular) Stop cloud-provider-kind + delete KinD cluster
make k8s-shared-deploy                  # Deploy alternate "shared sidecar" topology (k8s-dapr-shared/) to a running cluster — app manifests + a standalone shared daprd per app-id (dapr-shared-chart Helm). Building block of make e2e-shared
make k8s-shared-undeploy                # (manual) Remove the alternate shared-sidecar topology
make e2e-shared                         # Run e2e against the alternate shared-sidecar topology (standalone shared daprd per app-id via dapr-shared-chart). Wired into CI as the weekly-scheduled + workflow_dispatch `e2e-shared` job; also runnable manually (needs :e2e images — run make image-build first)
make e2e-prod-backends                  # Run e2e against the PROD backends — Kafka + PostgreSQL (official images, k8s/{kafka,postgres}.yaml) + prod Dapr components (statestore=PostgreSQL, pubsub=Kafka) instead of redis. Runtime-verifies the withdrawn-Bitnami replacement manifests. Wired into CI as the weekly-scheduled + workflow_dispatch `e2e-prod-backends` job
make kind-deploy-prod-backends          # (granular) Deploy Kafka + PostgreSQL + prod components + apps to KinD (building block of make e2e-prod-backends)
make print-deps-updates                 # Print project dependencies updates
make update-deps                        # Update project dependencies to latest releases
make renovate-validate                  # Validate Renovate configuration
make pre-release                        # Runs cve-check + image-scan + image-test (all strict). Required before `make release`
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

### Environment configuration (.env.example + port guards)

- **`.env.example`** (repo root, committed) is the source of truth for every operator-tunable value (`SERVER_PORT`, `DAPR_HTTP_PORT`/`DAPR_GRPC_PORT`, `JAEGER_QUERY_HOST`/`JAEGER_QUERY_PORT`, `GATEWAY_PORT`, `K8S_NAMESPACE`, the OTLP endpoint). `.env` (gitignored; `!.env.example` negation in `.gitignore` keeps the example tracked) overrides it.
- **`K8S_NAMESPACE`** (default `pizza-store`, never `default`) is the namespace the app, Dapr components, and e2e backing services (redis, jaeger) deploy into. The k8s manifests are **namespace-agnostic** — no `metadata.namespace` field and **bare** service names (`redis:6379`, `postgresql`, `kafka:9092`, `jaeger`, `<appid>-dapr`), so bare DNS resolves in-namespace and the Makefile var is the single source of truth. `$(KUBECTL)` bakes in `-n $(K8S_NAMESPACE)`; `$(KUBECTL_CLUSTER)` is the un-scoped form used only to create/delete the namespace. Do NOT add a `namespace:` field to a manifest or a `.svc.cluster.local` FQDN — that reintroduces a hardcoded namespace the var can't override. The Makefile `-include .env` before its `?=` port block, so `.env` is authoritative for `make` too — not just compose/app. YAML-coupled Dapr identifiers (`PUB_SUB_NAME`/`STATE_STORE_NAME`/topic/`DAPR_HTTP_ENDPOINT`) are intentionally NOT in `.env.example` — they must match the component/manifest YAML (excluded category per `rules/common/configuration.md`).
- **`make check-env`** is a STOPPER gate wired into `static-check` — it fails RED if `.env.example` is ever deleted, so the requirement can't silently regress. Proven RED (exit 2 when the file is absent).
- **`make check-ports`** guards the two fixed host-port binds (`make run` → `SERVER_PORT`; `make e2e` → `JAEGER_QUERY_PORT`), probing via bash `/dev/tcp` and naming the docker/podman container (or non-container process) holding the port before the bind fails cryptically. Each flow passes its own `CHECK_PORTS` set. Unit/integration tests use ephemeral ports (`TestSocketUtils.findAvailableTcpPort()`) and the act runner uses a random artifact port — those are already parallel-safe, so they need no `check-ports` guard.

### CI trigger policy (minutes budget — BLOCKING, do not widen without re-measuring)

GitHub Actions minutes are a hard constraint on this repo. Jobs are gated so a merged PR pays for its work **once**, not twice. Measured cost (billed ≈ sum of per-job wall time) before/after the 2026-07-13 rework: **~18 min → ~7 min per PR run**, and a merged PR **~40 min → ~7 min**.

| job | triggers | why |
|-----|----------|-----|
| `changes` | everything **except `schedule`** | Skipping it on cron leaves `needs.changes.outputs.code` empty, which **cascades a skip** to every `code == 'true'`-gated job. A cron run tests code identical to the last push — re-running static-check/build/test/e2e there is pure spend. |
| `static-check`, `build` | PR + push to main + tags (code changes only) | Cheap, fast feedback. |
| `test` | PR + push to main + tags (code changes only) | Runs `make coverage-generate` = `mvn verify -P integration-test` → Surefire **and** Failsafe in one reactor, plus the merged JaCoCo gate. The old separate unit-test job re-ran Surefire from scratch (extra checkout + mise + compile) for zero added signal — merged 2026-07-13, ~3 billed min/run saved. |
| `e2e` | **PR** (e2e-relevant paths or `run-e2e` label) + **tags** + dispatch | NOT on merge-to-main: with squash-merge the commit landing on main is byte-identical to the PR head e2e already ran against. ~6 billed min/merge saved. |
| `cve-check` | **tags** + dispatch | See the NVD cold-cache death-loop note below. |
| `image-scan` | **tags** + dispatch | 3 matrix runners × ~2 min, was paid on every push. |
| `e2e-shared`, `e2e-prod-backends` | **weekly cron** + dispatch | The only coverage of the alternate topologies; nothing else exercises them. The cron now runs *only* these two (~10 min/week, was ~65). |
| `docker`, `docker-manifest` | **tags** | Publish path. |

`ci-pass` treats `skipped` as a pass (every job above is skipped by design on some event) and fails only on `failure`/`cancelled`. When adding a job, gate it deliberately and add it to `ci-pass`'s `needs`.

### Release workflow

- `make ci` deliberately omits `cve-check`, `image-scan`, and `image-test` because all three are slow. They run via `make pre-release` (auto-invoked by `make release`):
  - All three are strict gates — the previous `timeout 300` + `|| true` workaround was removed when dependency-check 12.2.2 (2026-05-03) shipped the upstream fix for the NVD nanosecond-timestamp deserializer bug (PR #8427).
  - `image-scan` catches Paketo helper Go-stdlib CVEs that `trivy-fs` (workspace) and `cve-check` (Maven deps) both miss. `.trivyignore` documents currently-accepted Paketo-upstream CVEs with tracker URLs.
  - `image-test` asserts the Paketo CNB image contract via `container-structure-test` against `compose/structure-test/paketo.yaml`: USER `1002:1001` nonroot, entrypoint `/cnb/process/web`, WorkingDir `/workspace`, `/cnb/lifecycle/launcher` + `/workspace/BOOT-INF` present, and the negative shape (no `/bin/sh`, `/usr/bin/apt`, `/usr/bin/curl` — distroless invariants). The UID `1002:1001` is a Paketo `builder-jammy-base`-version-specific value (NOT the canonical 1001) — when the builder bumps, the assertion fails fast and the yaml must be re-verified against `docker inspect`. All three services use the same Paketo Java builder so a single shared yaml covers `pizza-store`, `pizza-kitchen`, and `pizza-delivery`.
- `cve-check` runs in CI on **tag pushes + `workflow_dispatch` only** (`timeout-minutes: 90`). It used to also run on the weekly cron — that was removed 2026-07-13 because it could never succeed: the NVD H2 cache key is the ISO week and GitHub evicts a cache after 7 days without a hit, so a weekly-only job always restored a **cold** cache, spent its whole 45-min budget on a full ~365k-record NVD sync, was killed at `timeout-minutes` (reported as `cancelled`, not a concurrency cancel), and therefore never SAVED a cache — a self-sustaining loop that burned ~45 CI-minutes every Monday and never once completed a scan. Tag pushes keep the cache warm; the 90-min ceiling exists so a genuinely cold sync (measured ~70+ min) can finish and repopulate it.
- `cve-check` logic lives in **`scripts/cve-check.sh`** (one shellcheck-able, self-testable place instead of a fragile backslash-continued Makefile recipe). It routes `NVD_API_KEY` / `OSS_INDEX_*` via `~/.m2/settings.xml` server-ids (printf builtin, umask 077 — secrets never enter argv), uses the fully-qualified `org.owasp:dependency-check-maven:check` goal, then **classifies any failure and composes two self-healing fallbacks** for known-recurring infra failures:
  - **real CVE finding → FAIL fast** (never masked; `failOnError=false` is deliberately NOT used).
  - **corrupt H2 cache** (`MVStoreException ... length -1` → `connectionPool ... is null`) → `org.owasp:dependency-check-maven:purge` + re-download. The NVD H2 DB is cached in CI (`actions/cache`, ISO-week key, prefix `nvd-db-v2-`); `actions/cache` tars `odc.mv.db`, so an interrupted NVD update leaves a **truncated** DB that `restore-keys` re-hydrates forever — the root cause of failed scheduled run 27938409200 (2026-06-22). The `nvd-db-v2-` prefix orphaned the poisoned pre-2026-06-22 tarballs (bump to `v3-` to invalidate again).
  - **transient NVD-API 503** (`NVD Returned Status Code: 503`) **+ a cached DB present** → re-run with `-DautoUpdate=false` (scan the cached DB, emit a `::warning::`, green). NVD periodically 503s during maintenance; dependency-check has no built-in "use cached DB on update failure" flag. If **no** cached DB exists (a fresh `nvd-db-v2-` cache during an NVD outage), it FAILS — re-run once NVD recovers so the cache populates; thereafter 503s degrade gracefully.
  - The two classifier regexes are mutation-proven by `make cve-check-selftest` (wired into `make static-check`, no network), so a broken classifier goes RED in CI.
- `image-scan` runs in CI on **tag pushes + `workflow_dispatch` only** (was every push until 2026-07-13; moved for the CI-minutes budget — 3 matrix runners × ~2 min, paid twice per merged PR). Per-service matrix, single-arch amd64; gates 1–4 = Paketo build + Trivy image scan + Spring Boot boot-marker smoke test + container-structure-test contract assertions. It `docker save | gzip`s each scanned image as a per-service artifact (`image-<svc>`, `retention-days: 1`) so the tag-gated `docker` job can `docker load` + push it WITHOUT rebuilding — the published image is byte-for-byte the one that was scanned+smoke+structure-tested. Trade-off accepted: a freshly-disclosed Paketo base-layer CVE now surfaces at release time rather than on the next push; such findings are almost always upstream-owned (Paketo must rebuild), so an earlier red `main` only blocked unrelated work.
- **`image-scan` is NOT a prerequisite of `kind-deploy` / `kind-deploy-prod-backends`** (removed 2026-07-13). It used to be, which meant every `make e2e` — local and CI — paid a full Paketo rebuild + Trivy scan, and an upstream Paketo CVE failed the *functional* e2e for a non-functional reason. The image gates live on the release path only (`make pre-release` → `make release`, and the tag-gated CI `image-scan` job).
- Tag-gated jobs (`docker`, `docker-manifest`) use a block-form `if: !failure() && !cancelled() && startsWith(github.ref, 'refs/tags/v')` so an explicit job-level `if:` doesn't strip GitHub's implicit skip-on-failure cascade; without `!failure()`, a red `static-check`/`build`/`test` on a tag push would still let the publish path run.
- The `cve-check` Make recipe routes `NVD_API_KEY` AND the Sonatype OSS Index creds (`OSS_INDEX_USER` + `OSS_INDEX_TOKEN`) through `~/.m2/settings.xml` (`<server id="nvd">` + `<server id="ossindex">`) + `-DnvdApiServerId=nvd -DossIndexServerId=ossindex` (written via `printf` — bash builtin, no argv). The flag forms `-DnvdApiKey=$$NVD_API_KEY` / `-DossIndexPassword=$$OSS_INDEX_TOKEN` would leak the value via `ps -ef` / `/proc/<pid>/cmdline` for the entire ~30-min plugin lifetime. OSS Index runs as a second CVE source alongside NVD; when its creds are absent the analyzer is disabled (it mandates token auth, no anonymous access). Caveat: the OSS Index free tier can rate-limit a large dependency tree with HTTP 401 (mis-classified as bad-auth) — if `cve-check` starts failing on OSS Index 401s, slim the tree, move to a paid tier, or set `-DossindexAnalyzerEnabled=false` with a rationale.

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

### Image publishing (amd64)

- `docker` job is a per-service matrix (3 runners): `{pizza-store, pizza-kitchen, pizza-delivery}` on `ubuntu-latest`. **amd64-only** — arm64 publishing was intentionally dropped; Paketo CNB `spring-boot:build-image` builds only the host arch (no cross-build), so re-adding arm64 would require native `ubuntu-24.04-arm` runners again.
- **`docker` does NOT rebuild the image** — it `needs: [..., image-scan]`, `download-artifact`s the `image-<svc>` artifact `image-scan` produced on the tag run, `docker load`s it, and pushes. This eliminates the double Paketo build that happened when both `image-scan` and `docker` ran on the same tag. Publishing still gates on the full validation chain (`static-check, build, test, cve-check, e2e, image-scan` — `test` covers unit + integration + coverage), and the artifact-handoff (not an early registry push) means a later gate failure leaves no orphaned tag.
- Each runner pushes an amd64 staging tag `ghcr.io/<owner>/<repo>/<svc>:<version>-amd64`.
- The downstream `docker-manifest` job promotes the amd64 staging image to `:<version>` + `:latest` with `docker buildx imagetools create` (single source), pushes both to GHCR, and signs the image digest with cosign keyless OIDC. Signing lives in this job (not `docker`) so the clean published tags are always the signed ones.

### Test coverage extras

- E2E asserts the WebSocket broadcast end-to-end via `websocat` (mise tool, `aqua:vi/websocat 1.14.1`) — regression guard for the PUBLIC_IP-hardcoded bug retired 2026-04-26.
- `make k8s-validate` (kubeconform) validates `k8s/` and `k8s-dapr-shared/` against vendored OpenAPI on every push, so manifest-parse drift in the alternate "shared sidecar" topology surfaces immediately. RUNTIME drift in that topology is caught by the weekly-scheduled `e2e-shared` CI job (+ `workflow_dispatch`), which brings up KinD, installs a standalone shared daprd per app-id via the `dapr-shared-chart` Helm chart (daprd pinned to the runtime version; sentry/operator ports overridden to 443 to match Dapr 1.17+), deploys `k8s-dapr-shared/`, and runs the full e2e suite. NOTE: `k8s-dapr-shared/apps.yaml` is a parallel manifest set — keep it in sync with `k8s/` (resources, `/tmp` volume, OTLP env, probes); five such drifts were the reason the topology was non-functional until 2026-06-15.
- **Prod backends (Kafka + PostgreSQL) — official images, NOT Bitnami.** `make e2e` uses redis (`k8s/redis-e2e.yaml` + `k8s/components-e2e.yaml`) for a hermetic run. The *production* Dapr components (`k8s/statestore.yaml`=`state.postgresql`, `k8s/pubsub.yaml`=`pubsub.kafka`) are backed by **`k8s/postgres.yaml`** (`postgres:17-alpine`, uid 70) and **`k8s/kafka.yaml`** (`apache/kafka` KRaft single-node, uid 1000) — plain, hardened manifests against the OFFICIAL images. They replaced Bitnami charts, whose catalog was withdrawn Aug 2025 (`bitnami/*` pinned tags ImagePullBackOff) — see the `/makefile` skill Bitnami rule + detection grep. Both image tags auto-track via Renovate's native `kubernetes` manager (no annotation). Runtime-verified by the weekly-scheduled + `workflow_dispatch` **`e2e-prod-backends`** CI job (`make e2e-prod-backends`), which deploys them + the prod components (instead of redis) and runs the full suite. `k8s-validate` parse-checks them on every push. When editing them: keep them namespace-agnostic (bare `postgresql`/`kafka` Service names, no `metadata.namespace`) and mind Kafka's `advertised.listeners=kafka:9092` (must be the Service DNS or the sidecar can't connect).
- `e2e` job runs an OWASP ZAP baseline DAST scan against the LB-exposed pizza-store after the assertion suite passes. **Strict gate** (`fail_action: true`, no `continue-on-error`): `pizza-store` ships baseline security headers via `SecurityHeadersFilter` (CSP allowlisting the pinned CDN origins + same-origin `/ws`, X-Content-Type-Options, X-Frame-Options DENY, Referrer-Policy, Permissions-Policy, COOP, CORP) and Subresource-Integrity (`sha384`) on the jQuery/STOMP CDN `<script>` tags, so the fixable findings are closed in code. Residual accepted alerts are documented as `IGNORE` in `.zap/rules.tsv` (10017 cross-domain JS — pinned+SRI'd; 90004 COEP-omitted — COOP/CORP are set; 10049/10109 informational). A NEW/unbudgeted finding (e.g. from a ZAP `:stable` image bump) now fails the e2e job. The action is pinned at `zaproxy/action-baseline@v0.15.0` (latest release; no v0.16+ exists). COEP `require-corp` is intentionally omitted — it would force every cross-origin CDN subresource to opt in via CORP for no benefit absent cross-origin-isolation needs.
- The OpenTelemetry instrumentation BOM is consumed via the `opentelemetry-instrumentation-bom-alpha` artifact id. The `-alpha` suffix is the upstream namespace for incubating instrumentation modules — it is the production-shipped artifact name, not a stability signal, and it does not "graduate" to a non-alpha BOM. Treat as the steady-state coordinate.

### Distributed tracing (OTel)

- Each service ships `spring-boot-starter-opentelemetry` (SB 4.0.7 umbrella starter). It bundles `spring-boot-micrometer-tracing-opentelemetry` (provides `OtlpTracingAutoConfiguration` + property metadata for `management.otlp.tracing.*` and `management.opentelemetry.tracing.export.otlp.*`), `spring-boot-opentelemetry` (OTel SDK autoconfig), `micrometer-tracing-bridge-otel`, and `opentelemetry-exporter-otlp`. Pulling in only the last two does NOT bring the autoconfig modules — spans never reach the OTLP exporter even though the property metadata accepts the config keys silently. Verified against SB 4.0.6 jar contents 2026-05-24 (`spring-boot-micrometer-tracing-opentelemetry-4.0.6.jar` owns `management.otlp.tracing.*` property metadata; absent if you pull only the bridge + exporter direct).
- `management.tracing.sampling.probability: 1.0` in `application.yml` for full sampling in the demo; tests override to `0.0` via `src/test/resources/application.yml` so the unreachable default OTLP endpoint doesn't log `UNAVAILABLE` errors throughout the suite.
- `MANAGEMENT_OPENTELEMETRY_TRACING_EXPORT_OTLP_ENDPOINT` env var points each pod at `http://jaeger:4318/v1/traces` in `k8s/pizza-*.yaml`. The SB 3.x form (`management.otlp.tracing.endpoint` / `MANAGEMENT_OTLP_TRACING_ENDPOINT`) is a deprecated alias in SB 4.0 — property resolution succeeds but it does NOT wire the new `OtlpTracingConnectionDetails` bean that `OtlpTracingConfigurations$Exporters` is `@ConditionalOnBean` on, so spans silently never reach the collector. Always use the SB 4.0 canonical form `management.opentelemetry.tracing.export.otlp.endpoint`. Jaeger all-in-one (1.65.0) runs as a Deployment + Service per `k8s/jaeger-e2e.yaml` with in-memory storage (e2e-only — production should run a separate OTel Collector or vendor-managed Jaeger with persistent storage).
- The e2e script asserts all three services emit spans by port-forwarding to the Jaeger query API on `:16686`. It first verifies `/api/services` lists `pizza-store`, `pizza-kitchen`, and `pizza-delivery`, then — because `/api/services` caches a service name ~indefinitely once it has ever emitted a span — additionally fetches `/api/traces?service=<svc>&limit=1&lookback=1h` per service and requires a non-empty `data[]`, proving traces were actually DELIVERED during this run (not just that the name was once seen). Catches a regression where a pod loses its OTLP wiring after having reported once.

### Dapr state-store keyPrefix isolation

- `kvstore` is consumed exclusively by `pizza-store` — no other service reads or writes it. The `/test-coverage-analysis` skill's hazard around `keyPrefix=appid` silently isolating cross-app state-store keys is INTENTIONALLY N/A for this project.
- If a future change adds a second consumer (e.g., `pizza-delivery` reading order history from `kvstore`), revisit the keyPrefix on `k8s/components-e2e.yaml` to ensure both services land at the same key namespace. The default keyPrefix is `appid`, which silently scopes each Dapr app-id's keys; explicitly setting `keyPrefix: name` (uses the Component name as the key prefix, shared across all apps) is the canonical fix when cross-app shared state is intentional.

### Documentation drift across Renovate-driven version bumps

`docs/diagrams/c4-container.puml`, `docs/diagrams/c4-deployment.puml`, and the README "Tech Stack" table hardcode framework/version strings (Spring Boot, Java, Dapr Helm chart). Renovate cannot update technology strings inside `Container(...)` PUML labels or README prose — both files drift silently after a Spring Boot or Dapr patch bump lands. After any such Renovate-driven bump, run `/architecture-diagrams` and `/readme` to re-sync these strings; do NOT rely on the diagrams-check or mermaid-lint gates to catch this — they validate parse, not content.

## Upgrade Backlog

Last reviewed: 2026-07-07 (backlog re-verified against version-exact Maven Central metadata + upstream repos: dapr-sdk bumped `1.17.3` → `1.17.4` this session — 1.17.4 GA'd 2026-07-06, all 13 `io.dapr`/`io.dapr.spring` artifacts confirmed resolving at 1.17.4, validated build + unit 27/0 + integration 9/0 on the real 1.17.4 sidecar; kept on the 1.17 line to match the deployed 1.17.7 runtime. **Spring Boot 4.1.0 reached GA 2026-06-10** — the 4.0→4.1 migration window is now open (see item below). Maven 4.0 still RC-5 (no GA); WireMock still 3.13.2-latest-stable / 4.0 still beta; wiremock-testcontainers still alpha-15; single-app DaprContainer re-verified still single-app on master + v1.17.4 + v1.18.1.).

- [ ] **`.trivyignore` waiver `CVE-2026-39822` expires 2026-08-17** — Go stdlib `os.Root` symlink following (HIGH, fixed in Go 1.26.5 / 1.25.12), present in six Paketo/CNB `gobinary` targets (`/cnb/lifecycle/launcher`, the bellsoft-liberica / ca-certificates / spring-boot helpers, + 2 SBOM docs) that upstream compiled with Go 1.26.4. Waived time-boxed because the fix is exclusively upstream (Paketo/CNB must rebuild) and these binaries run once at container start, not on any request path. On the `exp:` date trivy re-arms the gate: re-run `make image-scan` — if Paketo has shipped a refreshed builder the CVE is simply gone and the whole block should be deleted; if not, re-date with a fresh check of the trackers. **`image-scan` is tag-gated now, so this will surface as a failed release, not a red `main`** — check it before cutting a tag after that date.
- [ ] **Warm the NVD cache before the next release tag** — `cve-check` currently has NO cached NVD DB (`gh api repos/<o>/<r>/actions/caches` shows no `nvd-db-v2-*` entry; the cron death-loop never saved one). The first tag push therefore pays a full cold NVD sync (~70+ min, inside the new 90-min ceiling but slow and NVD-outage-sensitive). A `workflow_dispatch` run populates it — but note dispatch currently fans out to EVERY job (cve-check + image-scan ×3 + e2e + both topology e2es, ~65 min). If that's too expensive, either accept the slow first tag, or add `workflow_dispatch.inputs` to select which jobs run.
- [ ] **Maven 4.0 migration** — plan when Maven 4.0 reaches GA. Re-verified 2026-07-07: still **RC-5** upstream (`apache/maven` releases), no GA.
- [ ] **Spring Boot 4.0 → 4.1 migration** — Spring Boot 4.0 OSS support ends **2026-12-31**. **4.1.0 reached GA 2026-06-10** (verified on Maven Central: `spring-boot` metadata `<release>4.1.0`) — earlier than the previously-estimated Q4 2026. The migration window is now OPEN; project is currently on the latest 4.0.x patch (**4.0.7**). This is a framework minor migration coupled with **Java 25** (see below), NOT a drop-in bump — schedule a dedicated session: spike 4.1 → build/unit/integration → `make e2e` (+ ZAP/OTel wiring re-check) before merge, targeting a land well ahead of the 2026-12-31 EOL. Project commits to staying on the Spring Boot 4.x line.
- [ ] **`wiremock-testcontainers` GA** — re-verified 2026-07-07: still `1.0-alpha-15` upstream (Maven Central `wiremock-testcontainers-module` metadata — latest = release = alpha-15). Track GA release. (Note: `opentelemetry-instrumentation-bom-alpha` is NOT a backlog item — see Key Config "Test coverage extras" for the rationale.)
- [ ] **Dapr 1.18 line move** — the SDK tracks the latest 1.17 patch (`<dapr.version>` **1.17.4**, matching the deployed 1.17.7 runtime; SDK-on-or-behind-deployed-runtime-minor cadence). Upstream is on runtime **1.18.1** (2026-06-16) + SDK **1.18.0** GA, but 1.18 is **held** until the project's *deployed* runtime (Helm chart pin) moves off 1.17.7. It's a coordinated runtime(Helm)+SDK+e2e bump — incl. the shared-chart sentry/operator 443 override — not a drop-in; schedule a deliberate session when the deployed runtime moves to the 1.18 line.
- [ ] **WireMock 4.0 GA** — re-verified 2026-07-07: still beta (`4.0.0-beta.38` upstream); project's **`3.13.2` IS the latest 3.x stable** (Maven Central confirms no 3.13.3/3.14.x). Watch for 4.0 GA before bumping.
- [ ] **Single-app DaprContainer limitation** — upstream-blocked: `dapr/java-sdk:testcontainers-dapr/.../DaprContainer.java` exposes only single `appName/appPort/appChannelAddress` fields (no peer-app registration). Re-verified 2026-07-07 against `master`, `v1.17.4`, AND `v1.18.1` — all single-app only (`withAppName`/`withAppPort`/`withAppChannelAddress`, no `withApp`/`DaprApp`/`withApps`/app-collection API), and there is **no upstream issue or PR** tracking multi-app/peer-app support, so there is no ticket to watch yet. Workaround in `KitchenInvocationIT` / `DeliveryInvocationIT`: override `DAPR_HTTP_ENDPOINT` to a WireMock receiver — verifies the emitted HTTP contract (verb, path, body) but bypasses the sidecar invoke hop. The full sidecar→app→sidecar path is covered by the KinD e2e via `make e2e`. Re-wire if/when upstream adds multi-app support (watch `dapr/java-sdk` for a `DaprApp`/`withApp` API on `DaprContainer`).- [ ] **Java 25 LTS migration** — Java 25 LTS released March 2026, supported through 2032. Java 21 LTS supported through 2031 — no urgency (5+ years runway). Plan the bump to land **alongside Spring Boot 4.1** (Q3 2026, see above) since Spring Boot 4.1 is the first GA Spring Boot line that's Java-25-aware — one migration cycle for both rather than two.
- [ ] **Restore hits.sh `today/total` visitor badge once silentsoft/hits#31 is fixed** — the README hero badge was migrated off `hits.sh` (2026-07-07, PR #111 + follow-up) because hits.sh renders as a broken image on GitHub: after a same-day Let's Encrypt renewal onto a **Gen-Y** intermediate (`YR2`), its `Apache/2.4.38 (Win64)` server serves the chain terminating at the not-yet-trusted **`ISRG Root YR`** instead of the cross-signed path to `ISRG Root X1`, so GitHub's cert-validating **Camo** proxy returns 502 (verified `openssl … → Verify return code: 20`; DOM `naturalWidth 0`). Filed upstream: **https://github.com/silentsoft/hits/issues/31** (asks the operator to serve the cross-signed `fullchain`, e.g. certbot `--preferred-chain "ISRG Root X1"`). The interim replacement — `visitor-badge.laobi.icu` (color-matched `left_color=#555555`/`right_color=#4c1` to the shields siblings) — shows only a **single total**; hits.sh's two-number `view=today-total` format is a hits.sh-exclusive feature no other counter offers. When #31 is resolved AND `echo | openssl s_client -connect hits.sh:443 -servername hits.sh 2>&1 | grep 'Verify return code'` reports `0 (ok)`, revert README line 2 to `[![Hits](https://hits.sh/github.com/AndriyKalashnykov/dapr-java.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/dapr-java/)` and confirm the badge's `naturalWidth > 0` on the live repo page.
## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
