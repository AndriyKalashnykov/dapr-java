package io.diagrid.dapr;

import static io.restassured.RestAssured.get;
import static io.restassured.RestAssured.with;
import static org.awaitility.Awaitility.await;
import static org.hamcrest.Matchers.hasItem;
import static org.hamcrest.Matchers.notNullValue;

import io.dapr.testcontainers.Component;
import io.dapr.testcontainers.DaprContainer;
import io.dapr.testcontainers.Subscription;
import io.diagrid.dapr.PizzaStore.Customer;
import io.diagrid.dapr.PizzaStore.Order;
import io.diagrid.dapr.PizzaStore.OrderItem;
import io.diagrid.dapr.PizzaStore.PizzaType;
import io.restassured.RestAssured;
import io.restassured.http.ContentType;
import java.time.Duration;
import java.util.Arrays;
import java.util.Collections;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.TestSocketUtils;
import org.wiremock.integrations.testcontainers.WireMockContainer;

/**
 * Integration test exercising the real Dapr state store round-trip. Uses an in-memory state store
 * and in-memory pub/sub component so events emitted by {@code PizzaStore#placeOrder} are accepted
 * by the sidecar. Kitchen / delivery service invocation is stubbed via WireMock — this IT is scoped
 * to state persistence, not service invocation.
 */
@SpringBootTest(
    classes = PizzaStoreAppTest.class,
    webEnvironment = SpringBootTest.WebEnvironment.DEFINED_PORT)
@ImportTestcontainers
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
public class PizzaStoreStateStoreIT {

  // Allocate a free port at class-load time so DaprContainer's app channel
  // and Spring's embedded Tomcat agree on the port.
  private static final int APP_PORT = TestSocketUtils.findAvailableTcpPort();

  static DaprContainer dapr =
      new DaprContainer(DaprContainer.getDefaultImageName())
          .withAppName("local-dapr-app")
          .withAppPort(APP_PORT)
          .withAppChannelAddress("host.testcontainers.internal")
          .withExtraHost("host.testcontainers.internal", "host-gateway")
          .withComponent(new Component("kvstore", "state.in-memory", "v1", Collections.emptyMap()))
          .withComponent(new Component("pubsub", "pubsub.in-memory", "v1", Collections.emptyMap()))
          .withSubscription(new Subscription("subscription", "pubsub", "topic", "/events"));

  static WireMockContainer wireMock =
      new WireMockContainer("wiremock/wiremock:3.1.0")
          .withMappingFromResource("kitchen", "kitchen-service-stubs.json")
          .withMappingFromResource("delivery", "delivery-service-stubs.json");

  @DynamicPropertySource
  static void daprProperties(DynamicPropertyRegistry registry) {
    registry.add("server.port", () -> APP_PORT);
    registry.add("dapr.grpc.port", dapr::getGrpcPort);
    registry.add("dapr.http.port", dapr::getHttpPort);
    registry.add("DAPR_HTTP_ENDPOINT", wireMock::getBaseUrl);
  }

  @BeforeEach
  void setSystemProperties() {
    System.setProperty("dapr.grpc.port", String.valueOf(dapr.getGrpcPort()));
    System.setProperty("dapr.http.port", String.valueOf(dapr.getHttpPort()));
    RestAssured.port = APP_PORT;
  }

  @Test
  @org.junit.jupiter.api.Order(3)
  public void storesAndRetrievesOrder() {
    Order submitted =
        new Order(
            new Customer("alice", "alice@example.com"),
            Arrays.asList(new OrderItem(PizzaType.margherita, 2)));

    String orderId =
        with()
            .body(submitted)
            .contentType(ContentType.JSON)
            .when()
            .request("POST", "/order")
            .then()
            .assertThat()
            .statusCode(200)
            .body("id", notNullValue())
            .extract()
            .path("id");

    // placeOrder persists asynchronously on a background thread; poll the state store.
    await()
        .atMost(Duration.ofSeconds(15))
        .pollInterval(Duration.ofMillis(500))
        .untilAsserted(
            () ->
                get("/order")
                    .then()
                    .assertThat()
                    .statusCode(200)
                    .body("orders.id", hasItem(orderId))
                    .body("orders.customer.name", hasItem("alice"))
                    .body("orders.customer.email", hasItem("alice@example.com")));
  }

  // GET /order against a fresh kvstore (no orders persisted yet) must return
  // 200 — the controller relies on the State response carrying a null value
  // being passed through to the JSON serializer. Regressions where an NPE
  // leaks through (e.g., `state.getValue().orders.size()` unguarded) would
  // surface here. @Order(1) guarantees this runs before any place-order test
  // mutates the state store; without it, JUnit 5's default deterministic-but-
  // unspecified ordering would let other tests slip ahead and pollute state.
  @Test
  @org.junit.jupiter.api.Order(1)
  public void getOrderReturnsOkOnEmptyState() {
    get("/order").then().assertThat().statusCode(200);
  }

  @Test
  @org.junit.jupiter.api.Order(2)
  public void persistsMultipleOrders() {
    Order order1 =
        new Order(
            new Customer("dave", "dave@example.com"),
            Arrays.asList(new OrderItem(PizzaType.vegetarian, 3)));
    Order order2 =
        new Order(
            new Customer("erin", "erin@example.com"),
            Arrays.asList(new OrderItem(PizzaType.margherita, 2)));

    String firstId =
        with()
            .body(order1)
            .contentType(ContentType.JSON)
            .when()
            .request("POST", "/order")
            .then()
            .assertThat()
            .statusCode(200)
            .extract()
            .path("id");
    String secondId =
        with()
            .body(order2)
            .contentType(ContentType.JSON)
            .when()
            .request("POST", "/order")
            .then()
            .assertThat()
            .statusCode(200)
            .extract()
            .path("id");

    await()
        .atMost(Duration.ofSeconds(15))
        .pollInterval(Duration.ofMillis(500))
        .untilAsserted(
            () ->
                get("/order")
                    .then()
                    .assertThat()
                    .statusCode(200)
                    .body("orders.id", hasItem(firstId))
                    .body("orders.id", hasItem(secondId))
                    .body("orders.customer.name", hasItem("dave"))
                    .body("orders.customer.name", hasItem("erin")));
  }
}
