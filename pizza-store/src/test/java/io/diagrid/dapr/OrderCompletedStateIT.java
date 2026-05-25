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
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.TestSocketUtils;
import org.wiremock.integrations.testcontainers.WireMockContainer;

/**
 * Integration test covering the two state-mutating branches of {@link PizzaStore#receiveEvents}:
 *
 * <ul>
 *   <li>{@code ORDER_READY} → the store calls {@code prepareOrderForDelivery} which upserts the
 *       order with {@code Status.delivery} (and invokes the delivery service via WireMock stub).
 *   <li>{@code ORDER_COMPLETED} → the store upserts the order with {@code Status.completed}.
 * </ul>
 *
 * Event types {@code ORDER_PLACED}, {@code ORDER_IN_PREPARATION}, {@code ORDER_OUT_FOR_DELIVERY},
 * and {@code ORDER_ON_ITS_WAY} take the no-state-mutation branch (they only broadcast over the
 * WebSocket); their handling is exercised by {@link WebSocketBroadcastIT}.
 *
 * <p>The existing {@link PizzaStoreStateStoreIT} only exercises {@code POST /order} persistence;
 * this IT closes the coverage gap on the state-mutating branches of {@code receiveEvents}.
 */
@SpringBootTest(
    classes = PizzaStoreAppTest.class,
    webEnvironment = SpringBootTest.WebEnvironment.DEFINED_PORT)
@ImportTestcontainers
public class OrderCompletedStateIT {

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

  /**
   * Parameterized over the two state-mutating event types. {@code eventType} is the CloudEvent
   * data.type value the store handler dispatches on; {@code expectedStatus} is the resulting Order
   * status enum value after the upsert.
   */
  @ParameterizedTest(name = "{0} → status={1}")
  @CsvSource({"order-ready,     delivery", "order-completed, completed"})
  public void stateMutatingEventTransitionsOrderStatus(String eventType, String expectedStatus) {
    // Place a fresh order so the state store has a row keyed on an id we control downstream.
    Order placed =
        new Order(
            new Customer("frank", "frank@example.com"),
            Arrays.asList(new OrderItem(PizzaType.margherita, 1)));

    String orderId =
        with()
            .body(placed)
            .contentType(ContentType.JSON)
            .when()
            .request("POST", "/order")
            .then()
            .assertThat()
            .statusCode(200)
            .body("id", notNullValue())
            .extract()
            .path("id");

    // Confirm the order landed before posting the state-transition event.
    await()
        .atMost(Duration.ofSeconds(15))
        .pollInterval(Duration.ofMillis(500))
        .untilAsserted(
            () -> get("/order").then().statusCode(200).body("orders.id", hasItem(orderId)));

    // Post the state-transition CloudEvent. PizzaStore.receiveEvents dispatches:
    //   order-ready     → prepareOrderForDelivery() → Status.delivery + delivery-service invoke
    //   order-completed → store() with Status.completed
    String event =
        """
        {
            "specversion": "1.0",
            "type": "com.dapr.event.sent",
            "source": "test-source",
            "data": {
                "type": "%s",
                "service": "test",
                "message": "Test event for state-transition assertion.",
                "order": {
                    "customer": {"name": "frank", "email": "frank@example.com"},
                    "items": [{"type": "margherita", "amount": 1}],
                    "id": "%s",
                    "orderDate": "2026-05-01T12:00:00.000+00:00",
                    "status": "placed"
                }
            }
        }
        """
            .formatted(eventType, orderId);

    with()
        .body(event)
        .contentType("application/cloudevents+json")
        .when()
        .request("POST", "/events")
        .then()
        .assertThat()
        .statusCode(200);

    // The state store write happens synchronously inside receiveEvents, but the response
    // path serializes through Tomcat's worker pool — give it a brief poll window.
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
                    .body("orders.status", hasItem(expectedStatus)));
  }
}
