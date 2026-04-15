package io.diagrid.dapr;

import static io.restassured.RestAssured.*;
import static org.awaitility.Awaitility.await;
import static org.junit.jupiter.api.Assertions.*;

import io.dapr.client.domain.CloudEvent;
import io.dapr.testcontainers.Component;
import io.dapr.testcontainers.DaprContainer;
import io.dapr.testcontainers.Subscription;
import io.diagrid.dapr.PizzaDelivery.Event;
import io.diagrid.dapr.PizzaDelivery.EventType;
import io.diagrid.dapr.PizzaDelivery.Order;
import io.diagrid.dapr.PizzaDelivery.OrderItem;
import io.diagrid.dapr.PizzaDelivery.PizzaType;
import io.restassured.http.ContentType;
import java.time.Duration;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.TestSocketUtils;

@SpringBootTest(
    classes = PizzaDeliveryAppTest.class,
    webEnvironment = SpringBootTest.WebEnvironment.DEFINED_PORT)
@ImportTestcontainers
public class PizzaDeliveryTest {

  // Allocate a free port at class-load time so this test can run in parallel
  // with other DEFINED_PORT tests (e.g. on the same host when act runs the
  // `test` and `integration-test` workflow jobs concurrently). Both
  // DaprContainer's app channel and Spring's embedded Tomcat bind to
  // APP_PORT.
  private static final int APP_PORT = TestSocketUtils.findAvailableTcpPort();

  static DaprContainer dapr =
      new DaprContainer(DaprContainer.getDefaultImageName())
          .withAppName("local-dapr-app")
          .withAppPort(APP_PORT)
          .withAppChannelAddress("host.testcontainers.internal")
          .withExtraHost("host.testcontainers.internal", "host-gateway")
          .withComponent(new Component("pubsub", "pubsub.in-memory", "v1", Collections.emptyMap()))
          .withSubscription(new Subscription("subscription", "pubsub", "topic", "/events"));

  @DynamicPropertySource
  static void daprProperties(DynamicPropertyRegistry registry) {
    registry.add("server.port", () -> APP_PORT);
    registry.add("dapr.grpc.port", dapr::getGrpcPort);
    registry.add("dapr.http.port", dapr::getHttpPort);
  }

  @BeforeEach
  void setSystemProperties() {
    System.setProperty("dapr.grpc.port", String.valueOf(dapr.getGrpcPort()));
    System.setProperty("dapr.http.port", String.valueOf(dapr.getHttpPort()));
    io.restassured.RestAssured.port = APP_PORT;
  }

  @Autowired private SubscriptionsRestController subscriptionsRestController;

  @Test
  public void testDelivery() throws Exception {
    String orderId = UUID.randomUUID().toString();
    Order order =
        new Order(orderId, Arrays.asList(new OrderItem(PizzaType.pepperoni, 1)), new Date());

    with()
        .body(order)
        .contentType(ContentType.JSON)
        .when()
        .request("PUT", "/deliver")
        .then()
        .assertThat()
        .statusCode(200);

    // Wait for 4 events (3 stages of 3s delay + margin).
    await()
        .atMost(Duration.ofSeconds(20))
        .pollInterval(Duration.ofMillis(500))
        .untilAsserted(() -> assertEquals(4, subscriptionsRestController.getAllEvents().size()));

    List<CloudEvent<Event>> events = subscriptionsRestController.getAllEvents();
    assertEquals(4, events.size(), "Four published events are expected");

    for (int i = 0; i < 3; i++) {
      CloudEvent<Event> stage = events.get(i);
      assertEquals(
          EventType.ORDER_ON_ITS_WAY,
          stage.getData().type(),
          "Event " + i + " should be ORDER_ON_ITS_WAY");
      assertEquals(
          orderId,
          stage.getData().order().id(),
          "Event " + i + " payload should preserve the submitted order id");
      assertEquals(
          "delivery",
          stage.getData().service(),
          "Event " + i + " should be attributed to the delivery service");
    }

    CloudEvent<Event> completed = events.get(3);
    assertEquals(
        EventType.ORDER_COMPLETED,
        completed.getData().type(),
        "Fourth event should be ORDER_COMPLETED");
    assertEquals(
        orderId,
        completed.getData().order().id(),
        "Completed event payload should preserve the submitted order id");
    assertEquals(
        "delivery",
        completed.getData().service(),
        "Completed event should be attributed to the delivery service");
  }
}
