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
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.TestSocketUtils;
import org.wiremock.integrations.testcontainers.WireMockContainer;

/**
 * Integration test covering the ORDER_COMPLETED branch of {@link PizzaStore#receiveEvents}: when a
 * CloudEvent of type {@code order-completed} arrives, the store must upsert the order with {@code
 * Status.completed} so the subsequent {@code GET /order} reflects the terminal state.
 *
 * <p>The existing {@link PizzaStoreStateStoreIT} only exercises {@code POST /order} persistence;
 * this IT closes the coverage gap on the second branch of {@code receiveEvents} (the first branch,
 * ORDER_READY, is covered by {@link DeliveryInvocationIT}).
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

  @Test
  public void orderCompletedEventTransitionsStatusToCompleted() {
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

    // Confirm the order landed before posting the completion event.
    await()
        .atMost(Duration.ofSeconds(15))
        .pollInterval(Duration.ofMillis(500))
        .untilAsserted(
            () -> get("/order").then().statusCode(200).body("orders.id", hasItem(orderId)));

    // Post an ORDER_COMPLETED CloudEvent referencing the same order id. PizzaStore's
    // receiveEvents handler should upsert the row with status=completed.
    String completedEvent =
        """
        {
            "specversion": "1.0",
            "type": "com.dapr.event.sent",
            "source": "delivery-service",
            "data": {
                "type": "order-completed",
                "service": "delivery",
                "message": "Your Order has been delivered.",
                "order": {
                    "customer": {"name": "frank", "email": "frank@example.com"},
                    "items": [{"type": "margherita", "amount": 1}],
                    "id": "%s",
                    "orderDate": "2026-05-01T12:00:00.000+00:00",
                    "status": "delivery"
                }
            }
        }
        """
            .formatted(orderId);

    with()
        .body(completedEvent)
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
                    .body("orders.status", hasItem("completed")));
  }
}
