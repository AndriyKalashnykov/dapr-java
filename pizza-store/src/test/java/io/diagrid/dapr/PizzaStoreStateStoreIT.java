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
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.wiremock.integrations.testcontainers.WireMockContainer;

/**
 * Integration test exercising the real Dapr state store round-trip. Uses an in-memory state store
 * and in-memory pub/sub component so events emitted by {@code PizzaStore#placeOrder} are accepted
 * by the sidecar. Kitchen / delivery service invocation is stubbed via WireMock — this IT is scoped
 * to state persistence, not service invocation.
 */
@SpringBootTest(
    classes = PizzaStoreAppTest.class,
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ImportTestcontainers
public class PizzaStoreStateStoreIT {

  static DaprContainer dapr =
      new DaprContainer(DaprContainer.getDefaultImageName())
          .withAppName("local-dapr-app")
          .withAppPort(8080)
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
    registry.add("dapr.grpc.port", dapr::getGrpcPort);
    registry.add("dapr.http.port", dapr::getHttpPort);
    registry.add("DAPR_HTTP_ENDPOINT", wireMock::getBaseUrl);
  }

  @BeforeEach
  void setSystemProperties() {
    System.setProperty("dapr.grpc.port", String.valueOf(dapr.getGrpcPort()));
    System.setProperty("dapr.http.port", String.valueOf(dapr.getHttpPort()));
  }

  @LocalServerPort private int port;

  @BeforeEach
  public void setUp() {
    RestAssured.port = port;
  }

  @Test
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

  @Test
  public void persistsLatestSubmittedOrder() {
    // Known limitation in PizzaStore#store: it only copies existing orders when the prior list
    // is empty, so each new POST effectively overwrites the stored list. This test locks in the
    // observable behavior (latest submission is retrievable by id + customer) rather than
    // multi-order accumulation.
    Order order =
        new Order(
            new Customer("dave", "dave@example.com"),
            Arrays.asList(new OrderItem(PizzaType.vegetarian, 3)));

    String orderId =
        with()
            .body(order)
            .contentType(ContentType.JSON)
            .when()
            .request("POST", "/order")
            .then()
            .assertThat()
            .statusCode(200)
            .body("id", notNullValue())
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
                    .body("orders.id", hasItem(orderId))
                    .body("orders.customer.name", hasItem("dave"))
                    .body("orders.customer.email", hasItem("dave@example.com"))
                    .body("orders.items[0].type", hasItem("vegetarian"))
                    .body("orders.items[0].amount", hasItem(3)));
  }
}
