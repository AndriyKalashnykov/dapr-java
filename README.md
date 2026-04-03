[![CI](https://github.com/AndriyKalashnykov/dapr-java/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AndriyKalashnykov/dapr-java/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/dapr-java.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/dapr-java/)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-brightgreen.svg)](https://opensource.org/licenses/Apache-2.0)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/dapr-java)

# Cloud-Native Pizza Store

A sample Pizza Store application built with Java 21, [Spring Boot 4](https://spring.io/projects/spring-boot), [Dapr](https://dapr.io), and [Testcontainers](https://testcontainers.com). Three microservices communicate via Dapr PubSub and State Store APIs, deployable on any Kubernetes cluster or locally with just Maven and Docker.

[Quarkus implementation available here (Thanks to @mcruzdev1!)](https://github.com/mcruzdev/pizza-quarkus)

![Pizza Store](imgs/pizza-store.png)

## Quick Start

```bash
make deps          # install build dependencies via SDKMAN
make build         # build project
make test          # run project tests (requires Docker)
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [GNU Make](https://www.gnu.org/software/make/) | 3.81+ | Build orchestration |
| [JDK](https://adoptium.net/) | 21+ | Java runtime and compiler |
| [Maven](https://maven.apache.org/) | 3.9+ | Build and dependency management |
| [Docker](https://www.docker.com/) | latest | Integration tests via Testcontainers |
| [SDKMAN](https://sdkman.io/) | latest | Java/Maven version management (optional) |

Install all required dependencies:

```bash
make deps
```

Verify installed tools:

```bash
make env-check
```

## Available Make Targets

Run `make help` to see all available targets.

### Build & Run

| Target | Description |
|--------|-------------|
| `make build` | Build project |
| `make test` | Run project tests |
| `make lint` | Run static analysis checks |
| `make clean` | Remove build artifacts |
| `make run` | Run the application |

### Code Quality

| Target | Description |
|--------|-------------|
| `make coverage-generate` | Generate code coverage report |
| `make coverage-check` | Verify code coverage meets minimum threshold (>70%) |
| `make coverage-open` | Open code coverage report |
| `make cve-check` | OWASP dependency vulnerability scan |

### CI

| Target | Description |
|--------|-------------|
| `make ci` | Run full CI pipeline (clean, lint, build, test, coverage) |
| `make ci-run` | Run GitHub Actions workflow locally using [act](https://github.com/nektos/act) |

### Utilities

| Target | Description |
|--------|-------------|
| `make deps` | Install build dependencies via SDKMAN |
| `make deps-check` | Verify build dependencies are installed |
| `make deps-act` | Install act for local CI testing |
| `make env-check` | Check installed tools and versions |
| `make print-deps-updates` | Print project dependencies updates |
| `make update-deps` | Update project dependencies to latest releases |
| `make renovate-bootstrap` | Install nvm and npm for Renovate |
| `make renovate-validate` | Validate Renovate configuration |
| `make release VERSION=x.y.z` | Create a release tag with semver validation |

## Architecture

The Pizza Store application simulates placing a Pizza Order that is processed by different services. The Pizza Store Service serves as the frontend and backend to place orders. Orders are sent to the Kitchen Service for preparation and once ready, the Delivery Service takes the order to your door.

![Architecture](imgs/architecture.png)

These services need a persistent store (PostgreSQL) and a message broker (Kafka) for event-driven communication.

![Architecture with Infra](imgs/architecture+infra.png)

Adding [Dapr](https://dapr.io) decouples services from infrastructure. Dapr provides [building block APIs](https://docs.dapr.io/concepts/building-blocks-concept/) (StateStore, PubSub) so developers don't need to choose or configure specific drivers and clients. Infrastructure teams can swap components without impacting application code.

![Architecture with Dapr](imgs/architecture+dapr.png)

## Testing

Tests use [Testcontainers](https://testcontainers.com) with [`io.dapr:testcontainers-dapr`](https://central.sonatype.com/artifact/io.dapr/testcontainers-dapr) to automatically start Dapr sidecars and placement services. Integration tests run outside of Kubernetes without any manual Dapr setup — just Docker.

```bash
make test
```

Once the service is up, you can place orders and simulate events from the Kitchen and Delivery services by sending HTTP requests to the `/events` endpoint. Using [`httpie`](https://httpie.io/):

```bash
http :8080/events Content-Type:application/cloudevents+json < pizza-store/event-in-prep.json
```

## Kubernetes Deployment

### Create a Cluster

If you don't have a Kubernetes cluster, [install KinD](https://kind.sigs.k8s.io/docs/user/quick-start/) and create a local cluster:

```bash
kind create cluster
```

### Install Dapr

```bash
helm repo add dapr https://dapr.github.io/helm-charts/
helm repo update
helm upgrade --install dapr dapr/dapr \
  --version=1.15.3 \
  --namespace dapr-system \
  --create-namespace \
  --wait
```

### Install Infrastructure

Kafka for messaging between services:

```bash
helm install kafka oci://registry-1.docker.io/bitnamicharts/kafka --version 22.1.5 \
  --set "provisioning.topics[0].name=events-topic" \
  --set "provisioning.topics[0].partitions=1" \
  --set "persistence.size=1Gi"
```

PostgreSQL for persistent storage:

```bash
kubectl apply -f k8s/pizza-init-sql-cm.yaml

helm install postgresql oci://registry-1.docker.io/bitnamicharts/postgresql --version 12.5.7 \
  --set "image.debug=true" \
  --set "primary.initdb.user=postgres" \
  --set "primary.initdb.password=postgres" \
  --set "primary.initdb.scriptsConfigMap=pizza-init-sql" \
  --set "global.postgresql.auth.postgresPassword=postgres" \
  --set "primary.persistence.size=1Gi"
```

### Deploy the Application

```bash
kubectl apply -f k8s/
```

Access the application via port-forward:

```bash
kubectl port-forward svc/pizza-store 8080:80
```

Open [`http://localhost:8080`](http://localhost:8080).

## CI/CD

GitHub Actions runs on every push to `main`, tags `v*`, and pull requests.

| Job | Triggers | Steps |
|-----|----------|-------|
| **static-check** | push, PR, tags | Lint |
| **build** | after static-check | Build |
| **test** | after static-check | Test |

[Renovate](https://docs.renovatebot.com/) keeps dependencies up to date with platform automerge enabled.

## Resources and References

- [Dapr For Java Developers](https://dzone.com/articles/dapr-for-java-developers)
- [Platform Engineering on Kubernetes Book](http://mng.bz/jjKP?ref=salaboy.com)
- [Cloud Native Local Development with Dapr and Testcontainers](https://www.diagrid.io/blog/cloud-native-local-development)

## Contributing

Feel free to [create issues](https://github.com/AndriyKalashnykov/dapr-java/issues) or submit pull requests.
