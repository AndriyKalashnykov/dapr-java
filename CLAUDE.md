# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
make help                               # List available tasks on this project
make deps                               # Install build dependencies via mise (reads .mise.toml)
make deps-check                         # Verify build dependencies are installed
make deps-maven                         # Install Maven from Apache archives (CI fallback)
make deps-act                           # Install act for local CI testing
make deps-trivy                         # Install Trivy for security scanning
make deps-gitleaks                      # Install gitleaks for secret scanning
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
make static-check                       # Composite: format-check + lint + trivy-fs + trivy-config + secrets
make clean                              # Remove build artifacts
make run                                # Run the application
make ci                                 # Full CI: clean, deps, static-check, test, integration-test, build, cve-check, coverage-check
make ci-run                             # Run GitHub Actions workflow locally using act
make cve-check                          # OWASP dependency vulnerability scan
make coverage-generate                  # Generate code coverage report
make coverage-check                     # Verify code coverage meets minimum threshold (78%)
make coverage-open                      # Open code coverage report
make print-deps-updates                 # Print project dependencies updates
make update-deps                        # Update project dependencies to latest releases
make renovate-validate                  # Validate Renovate configuration
make release VERSION=x.y.z              # Create a semver release tag (run `make cve-check` first)
```

### Test pyramid

| Layer | Command | Scope | Runtime |
|-------|---------|-------|---------|
| Unit | `make test` | `**/*Test.java` via Surefire, in-memory PubSub Dapr sidecars | Seconds |
| Integration | `make integration-test` | `**/*IT.java` via Failsafe, real deps via Testcontainers (no tests exist yet) | Tens of seconds |
| E2E | `make e2e` | `e2e/e2e-test.sh` against KinD (cloud-provider-kind LoadBalancer + Dapr Helm + in-memory pubsub/state store). Asserts health, order placement, cross-service fan-out lifecycle (store → kitchen → delivery), state store round-trip, and a negative case. | Minutes |

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
// pizza-kitchen and pizza-delivery use DEFINED_PORT; pizza-store uses RANDOM_PORT
@SpringBootTest(classes = PizzaKitchenAppTest.class, webEnvironment = DEFINED_PORT)
@ImportTestcontainers
public class PizzaKitchenTest {
    static DaprContainer dapr = new DaprContainer(DaprContainer.getDefaultImageName())
        .withAppName("local-dapr-app")
        .withAppPort(8080)
        .withAppChannelAddress("host.testcontainers.internal")
        .withExtraHost("host.testcontainers.internal", "host-gateway")
        .withComponent(new Component("pubsub", "pubsub.in-memory", "v1", ...))
        .withSubscription(new Subscription("subscription", "pubsub", "topic", "/events"));
}
```

- **`withExtraHost("host.testcontainers.internal", "host-gateway")`** — Required for container-to-host networking in CI. Uses Docker's built-in host-gateway instead of Testcontainers' SSHD proxy.
- **In-memory PubSub** — Tests use `pubsub.in-memory` (no Kafka). Only needed for delivery/kitchen tests that verify event flow.
- **System properties** — `DaprClientBuilder` reads `dapr.grpc.port`/`dapr.http.port` from system properties (not Spring Environment), so tests set both via `@DynamicPropertySource` and `@BeforeEach`.
- **SubscriptionsRestController** — Test helper in delivery/kitchen that captures CloudEvents on `POST /events` for assertion.
- **WireMock** — pizza-store tests use WireMockContainer with `kitchen-service-stubs.json` to mock downstream services.

## Key Dependency Versions

Managed centrally in the parent `pom.xml` `<properties>` block. The Dapr SDK version (`dapr.version`) drives both `dapr-spring-boot-4-starter` and `testcontainers-dapr`. Dependency updates are automated via Renovate (`renovate.json`) with automerge enabled on all update types — platform automerge with squash strategy, vulnerability alerts fast-tracked with zero delay.

## Upgrade Backlog

Last reviewed: 2026-04-15

- [x] **Maven 3.9 EOL (2026-03-12)** — updated `MAVEN_VERSION` to 3.9.14 (2026-04-03)
- [x] **mise migration** — replaced SDKMAN + nvm with mise via `.mise.toml` and `.java-version` (2026-04-15)
- [x] **Static-check composite quality gate** — `format-check` + `lint` + `trivy-fs` + `trivy-config` + `secrets` wired into `make ci` (2026-04-15)
- [x] **CVE overrides** — pinned Tomcat 11.0.21, Jackson 3.1.2, gRPC 1.80.0 in `dependencyManagement` to address advisories (2026-04-15)
- [x] **K8s security hardening** — `runAsNonRoot`, `readOnlyRootFilesystem`, dropped capabilities, tmpfs for writable paths in all three Deployments (both `k8s/` and `k8s-dapr-shared/`) (2026-04-15)
- [x] **`cve-check` wired into CI** — runs on tag pushes, weekly schedule (Mon 06:00 UTC), and `workflow_dispatch`. Omitted from `make ci` and `make ci-run` — run `make cve-check` manually before pushing a release tag. NVD cache + HTML report upload intact. (2026-04-15)
- [x] **`MAVEN_VERSION` Renovate tracking** — covered by the generic `# renovate:` customManagers regex (2026-04-15)
- [ ] **Maven 4.0 migration** — plan when Maven 4.0 reaches GA (currently RC-5)
- [ ] **Spring Boot 4.0 EOL (2026-12-31)** — monitor 4.1 release schedule, plan upgrade before Dec 2026
- [ ] **Alpha dependencies** — `opentelemetry-instrumentation-bom-alpha`, `wiremock-testcontainers` 1.0-alpha-15. Track GA releases.
- [ ] **OWASP dependency-check NVD deserializer bug** — 12.2.1 cannot parse 9-digit nanosecond timestamps from the NVD API (`Failed to deserialize java.time.ZonedDateTime ... unparsed text found at index 23`). `cve-check` CI step is `continue-on-error: true` until a fixed release; re-enable strict failure once upstream ships. Track: dependency-check/DependencyCheck.
- [x] **MetalLB → cloud-provider-kind + kindest/node v1.35.0** — replaced in-cluster MetalLB with kind-team's cloud-provider-kind (runs as a host-side controller, no nftables interaction). Unblocks the kindest/node v1.35.0 bump. (2026-04-15)
- [ ] **Single-app DaprContainer limitation** — confirmed upstream-blocked: `dapr/java-sdk:testcontainers-dapr/.../DaprContainer.java` still exposes only single `appName/appPort/appChannelAddress` fields (no peer-app registration). Workaround in `KitchenInvocationIT` / `DeliveryInvocationIT`: override `DAPR_HTTP_ENDPOINT` to a WireMock receiver — this verifies the emitted HTTP contract (verb, path, body) but bypasses the sidecar invoke hop. The full sidecar→app→sidecar path is covered by the KinD e2e via `make e2e`. A richer approach would be two `DaprContainer` instances sharing a placement service on a common Docker network; not attempted because (a) upstream doesn't expose `withPlacementService` in a way that makes app IDs cross-routable, and (b) the e2e already gives us that coverage. Re-wire once upstream adds multi-app support.
- [x] **Raise JaCoCo threshold to 0.80** — Failsafe coverage aggregation wired via `jacoco:merge`; `coverage-generate` now runs `mvn verify -P integration-test` and reports merged unit+IT coverage (pizza-store 0.89, pizza-kitchen 0.88, pizza-delivery 0.93) (2026-04-15).
- [x] **Add integration tests (`**/*IT.java`)** — state store round-trip, kitchen invocation, delivery invocation, WebSocket broadcast (2026-04-15)
- [x] **Add `make e2e` target + KinD/cloud-provider-kind** — full KinD lifecycle, cloud-provider-kind LoadBalancer, Dapr Helm, e2e script asserting order fan-out (2026-04-15)
- [x] **Dapr 1.17.1 → 1.17.2; Jackson 3.1.1 → 3.1.2; OTel 1.60.1 → 1.61.0** — patch bumps (2026-04-15)
- [x] **Dapr Helm chart bump** — chart aligned to 1.17.4 via `DAPR_HELM_VERSION` in Makefile (2026-04-15)
- [ ] **Replace hand-drawn architecture PNGs with C4-PlantUML** — `architecture.png`, `architecture+infra.png`, `architecture+dapr.png` lack source; the `+` in filenames also complicates URL-encoding. Follow-up `/architecture-diagrams`.
- [ ] **Add C4 Context hero diagram to README** — deferred until PlantUML toolchain and `make diagrams-check` lint are introduced (mermaid-lint not wired today). Follow-up `/architecture-diagrams`.

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |
| `CLAUDE.md` | `/claude` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
