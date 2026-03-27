# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
make deps                               # Install Java + Maven via SDKMAN
make deps-check                         # Verify java and mvn are available
make env-check                          # Show installed tool versions
make build                              # Build all modules (skips tests)
make test                               # Run all integration tests (requires Docker)
make lint                               # Run Checkstyle static analysis
make clean                              # Clean build artifacts
make ci                                 # Full CI pipeline: clean, build, lint, test
make ci-run                             # Run GitHub Actions workflow locally via act
make cve-check                          # OWASP dependency vulnerability scan
make coverage-generate                  # Run tests + generate JaCoCo reports
make coverage-check                     # Verify coverage meets 70% threshold
make print-deps-updates                 # Show available dependency updates
make update-deps                        # Update dependencies to latest releases
make renovate-validate                  # Validate Renovate configuration
make release VERSION=x.y.z             # Create a semver release tag
```

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
@SpringBootTest(classes = AppTest.class, webEnvironment = DEFINED_PORT)
@ImportTestcontainers
public class ServiceTest {
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
