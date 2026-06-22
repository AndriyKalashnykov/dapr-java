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
make static-check                       # Composite: check-java-alignment + format-check + lint + trivy-fs + trivy-config + secrets + diagrams-check + mermaid-lint + k8s-validate
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

### Release workflow

- `make ci` deliberately omits `cve-check`, `image-scan`, and `image-test` because all three are slow. They run via `make pre-release` (auto-invoked by `make release`):
  - All three are strict gates — the previous `timeout 300` + `|| true` workaround was removed when dependency-check 12.2.2 (2026-05-03) shipped the upstream fix for the NVD nanosecond-timestamp deserializer bug (PR #8427).
  - `image-scan` catches Paketo helper Go-stdlib CVEs that `trivy-fs` (workspace) and `cve-check` (Maven deps) both miss. `.trivyignore` documents currently-accepted Paketo-upstream CVEs with tracker URLs.
  - `image-test` asserts the Paketo CNB image contract via `container-structure-test` against `compose/structure-test/paketo.yaml`: USER `1002:1001` nonroot, entrypoint `/cnb/process/web`, WorkingDir `/workspace`, `/cnb/lifecycle/launcher` + `/workspace/BOOT-INF` present, and the negative shape (no `/bin/sh`, `/usr/bin/apt`, `/usr/bin/curl` — distroless invariants). The UID `1002:1001` is a Paketo `builder-jammy-base`-version-specific value (NOT the canonical 1001) — when the builder bumps, the assertion fails fast and the yaml must be re-verified against `docker inspect`. All three services use the same Paketo Java builder so a single shared yaml covers `pizza-store`, `pizza-kitchen`, and `pizza-delivery`.
- `cve-check` also runs in CI on tag pushes, weekly cron (Mon 06:00 UTC), and `workflow_dispatch`.
- `cve-check` logic lives in **`scripts/cve-check.sh`** (one shellcheck-able, self-testable place instead of a fragile backslash-continued Makefile recipe). It routes `NVD_API_KEY` / `OSS_INDEX_*` via `~/.m2/settings.xml` server-ids (printf builtin, umask 077 — secrets never enter argv), uses the fully-qualified `org.owasp:dependency-check-maven:check` goal, then **classifies any failure and composes two self-healing fallbacks** for known-recurring infra failures:
  - **real CVE finding → FAIL fast** (never masked; `failOnError=false` is deliberately NOT used).
  - **corrupt H2 cache** (`MVStoreException ... length -1` → `connectionPool ... is null`) → `org.owasp:dependency-check-maven:purge` + re-download. The NVD H2 DB is cached in CI (`actions/cache`, ISO-week key, prefix `nvd-db-v2-`); `actions/cache` tars `odc.mv.db`, so an interrupted NVD update leaves a **truncated** DB that `restore-keys` re-hydrates forever — the root cause of failed scheduled run 27938409200 (2026-06-22). The `nvd-db-v2-` prefix orphaned the poisoned pre-2026-06-22 tarballs (bump to `v3-` to invalidate again).
  - **transient NVD-API 503** (`NVD Returned Status Code: 503`) **+ a cached DB present** → re-run with `-DautoUpdate=false` (scan the cached DB, emit a `::warning::`, green). NVD periodically 503s during maintenance; dependency-check has no built-in "use cached DB on update failure" flag. If **no** cached DB exists (a fresh `nvd-db-v2-` cache during an NVD outage), it FAILS — re-run once NVD recovers so the cache populates; thereafter 503s degrade gracefully.
  - The two classifier regexes are mutation-proven by `make cve-check-selftest` (wired into `make static-check`, no network), so a broken classifier goes RED in CI.
- `image-scan` ALSO runs in CI on every push (PR + main) as a per-service matrix sibling job (single-arch amd64; gates 1–4 = Paketo build + Trivy image scan + Spring Boot boot-marker smoke test + container-structure-test contract assertions). This catches Paketo base-layer CVE regressions AND CNB contract drift between release tags — the tag-gated `docker` matrix would otherwise only surface them on release day.
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

### Image publishing (multi-arch)

- `docker` job is a per-service-per-arch matrix (6 runners): `{pizza-store, pizza-kitchen, pizza-delivery} × {amd64, arm64}`. arm64 runs on `ubuntu-24.04-arm` because Paketo CNB `spring-boot:build-image` builds only the host arch (no cross-build).
- Each runner pushes its per-arch tag `ghcr.io/<owner>/<repo>/<svc>:<version>-<arch>`.
- The downstream `docker-manifest` job assembles a multi-arch manifest list with `docker buildx imagetools create`, pushes both `:<version>` and `:latest` to GHCR, and signs the manifest digest with cosign keyless OIDC. A single signature covers both archs.

### Test coverage extras

- E2E asserts the WebSocket broadcast end-to-end via `websocat` (mise tool, `cargo:websocat 1.14.0`) — regression guard for the PUBLIC_IP-hardcoded bug retired 2026-04-26.
- `make k8s-validate` (kubeconform) validates `k8s/` and `k8s-dapr-shared/` against vendored OpenAPI on every push, so manifest-parse drift in the alternate "shared sidecar" topology surfaces immediately. RUNTIME drift in that topology is caught by the weekly-scheduled `e2e-shared` CI job (+ `workflow_dispatch`), which brings up KinD, installs a standalone shared daprd per app-id via the `dapr-shared-chart` Helm chart (daprd pinned to the runtime version; sentry/operator ports overridden to 443 to match Dapr 1.17+), deploys `k8s-dapr-shared/`, and runs the full e2e suite. NOTE: `k8s-dapr-shared/apps.yaml` is a parallel manifest set — keep it in sync with `k8s/` (resources, `/tmp` volume, OTLP env, probes); five such drifts were the reason the topology was non-functional until 2026-06-15.
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

Last reviewed: 2026-06-15 (re-verified against Maven Central + Docker Hub: dapr-sdk bumped `1.17.2` → `1.17.3` this session — 1.17.3 AND 1.18.0 are GA on Maven Central per direct `repo1.maven.org` `.pom` checks, kept on the 1.17 line to match the 1.17.7 runtime; the K8s 1.36 bump LANDED this session — KinD 0.32.0 + kindest/node v1.36.1 + kubectl 1.36.2, see the checked-off backlog item below).

- [ ] **Maven 4.0 migration** — plan when Maven 4.0 reaches GA (currently RC-5)
- [ ] **Spring Boot 4.0 → 4.1 migration** — Spring Boot 4.0 OSS support ends **2026-12-31**. 4.1 GA is expected Q4 2026 (currently 4.1.0-RC1). Project commits to staying on the Spring Boot 4.x line; start the 4.0 → 4.1 migration plan ~Q3 2026 to land before EOL.
- [ ] **`wiremock-testcontainers` GA** — currently `1.0-alpha-15` upstream. Track GA release. (Note: `opentelemetry-instrumentation-bom-alpha` is NOT a backlog item — see Key Config "Test coverage extras" for the rationale.)
- [x] **`dapr-spring-boot-4-starter` 1.17.3** — DONE 2026-06-15. Bumped `<dapr.version>` 1.17.2 → **1.17.3** (drives both `dapr-spring-boot-4-starter` and `testcontainers-dapr`). 1.17.3 reached GA on Maven Central (verified by direct `repo1.maven.org` `.pom` HEAD — an earlier WebSearch this session wrongly reported it still RC-only; the direct artifact check is authoritative). Validated: build + unit + integration tests green on 1.17.3. **Note: 1.18.0 is ALSO GA**, but held — the runtime/Helm chart is on 1.17.7 and the project's cadence is SDK-on-or-behind-runtime-minor (runtime-ahead-of-SDK is normal Dapr Java cadence); bump the SDK to 1.18.x when the runtime moves to the 1.18 line.
- [ ] **WireMock 4.0 GA** — currently `4.0.0-beta.10` upstream; project on stable `3.13.2`. Watch for 4.0 GA before bumping.
- [ ] **Single-app DaprContainer limitation** — upstream-blocked: `dapr/java-sdk:testcontainers-dapr/.../DaprContainer.java` exposes only single `appName/appPort/appChannelAddress` fields (no peer-app registration). Re-verified 2026-06-15 against `v1.17.2` (pinned), latest GA `v1.18.0`, AND `master` — all three are single-app only (no `withApp`/`DaprApp`/app-collection API), and there is **no upstream issue or PR** tracking multi-app/peer-app support, so there is no ticket to watch yet. Workaround in `KitchenInvocationIT` / `DeliveryInvocationIT`: override `DAPR_HTTP_ENDPOINT` to a WireMock receiver — verifies the emitted HTTP contract (verb, path, body) but bypasses the sidecar invoke hop. The full sidecar→app→sidecar path is covered by the KinD e2e via `make e2e`. Re-wire if/when upstream adds multi-app support (watch `dapr/java-sdk` for a `DaprApp`/`withApp` API on `DaprContainer`).
- [x] **kindest/node v1.36 + kubectl 1.36** — DONE 2026-06-15. Bumped as a coupled set: KinD `0.31.0 → 0.32.0` (the release that ships the v1.36.1 node image — KinD requires the `@sha256` digest matched to its own release), `KIND_NODE_VERSION v1.35.1 → v1.36.1` + matching digest in the Makefile, and `kubectl 1.35.4 → 1.36.2` in `.mise.toml` (cluster ↔ kubectl skew stays at +1 minor). Validated with `make e2e`.
- [ ] **Java 25 LTS migration** — Java 25 LTS released March 2026, supported through 2032. Java 21 LTS supported through 2031 — no urgency (5+ years runway). Plan the bump to land **alongside Spring Boot 4.1** (Q3 2026, see above) since Spring Boot 4.1 is the first GA Spring Boot line that's Java-25-aware — one migration cycle for both rather than two.
- [x] **ZAP baseline `continue-on-error: true` → strict** — DONE 2026-06-15. `pizza-store` now ships baseline security headers (`SecurityHeadersFilter`) + Subresource-Integrity, closing the fixable ZAP findings in code; residual accepted alerts are budgeted in `.zap/rules.tsv`. Flipped to strict (`fail_action: true`, `continue-on-error` removed). `zaproxy/action-baseline@v0.15.0` is the latest release (no v0.16+ exists), so no action bump was needed. All CI behavioral gates are now strict.

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
