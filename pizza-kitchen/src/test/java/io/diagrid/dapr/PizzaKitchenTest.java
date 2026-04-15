package io.diagrid.dapr;

import static io.restassured.RestAssured.*;
import static org.awaitility.Awaitility.await;
import static org.junit.jupiter.api.Assertions.*;

import io.dapr.client.domain.CloudEvent;
import io.dapr.testcontainers.Component;
import io.dapr.testcontainers.DaprContainer;
import io.dapr.testcontainers.Subscription;
import io.diagrid.dapr.PizzaKitchen.Event;
import io.diagrid.dapr.PizzaKitchen.EventType;
import io.diagrid.dapr.PizzaKitchen.Order;
import io.diagrid.dapr.PizzaKitchen.OrderItem;
import io.diagrid.dapr.PizzaKitchen.PizzaType;
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

@SpringBootTest(
    classes = PizzaKitchenAppTest.class,
    webEnvironment = SpringBootTest.WebEnvironment.DEFINED_PORT)
@ImportTestcontainers
public class PizzaKitchenTest {

  static DaprContainer dapr =
      new DaprContainer(DaprContainer.getDefaultImageName())
          .withAppName("local-dapr-app")
          .withAppPort(8080)
          .withAppChannelAddress("host.testcontainers.internal")
          .withExtraHost("host.testcontainers.internal", "host-gateway")
          .withComponent(new Component("pubsub", "pubsub.in-memory", "v1", Collections.emptyMap()))
          .withSubscription(new Subscription("subscription", "pubsub", "topic", "/events"));

  @DynamicPropertySource
  static void daprProperties(DynamicPropertyRegistry registry) {
    registry.add("dapr.grpc.port", dapr::getGrpcPort);
    registry.add("dapr.http.port", dapr::getHttpPort);
  }

  @BeforeEach
  void setSystemProperties() {
    System.setProperty("dapr.grpc.port", String.valueOf(dapr.getGrpcPort()));
    System.setProperty("dapr.http.port", String.valueOf(dapr.getHttpPort()));
  }

  @Autowired private SubscriptionsRestController subscriptionsRestController;

  @Test
  public void testPrepareOrderRequest() throws Exception {
    String orderId = UUID.randomUUID().toString();
    Order order =
        new Order(orderId, Arrays.asList(new OrderItem(PizzaType.pepperoni, 1)), new Date());

    with()
        .body(order)
        .contentType(ContentType.JSON)
        .when()
        .request("PUT", "/prepare")
        .then()
        .assertThat()
        .statusCode(200);

    // Wait for events: 5s initial delay + up to 15s random prep + margin.
    await()
        .atMost(Duration.ofSeconds(30))
        .pollInterval(Duration.ofMillis(500))
        .untilAsserted(() -> assertEquals(2, subscriptionsRestController.getAllEvents().size()));

    List<CloudEvent<Event>> events = subscriptionsRestController.getAllEvents();
    assertEquals(2, events.size(), "Two published events are expected");

    CloudEvent<Event> inPreparation = events.get(0);
    assertEquals(
        EventType.ORDER_IN_PREPARATION,
        inPreparation.getData().type(),
        "First event should be ORDER_IN_PREPARATION");
    assertEquals(
        orderId,
        inPreparation.getData().order().id(),
        "Event payload should preserve the submitted order id");
    assertEquals(
        "kitchen",
        inPreparation.getData().service(),
        "Event should be attributed to the kitchen service");

    CloudEvent<Event> ready = events.get(1);
    assertEquals(
        EventType.ORDER_READY, ready.getData().type(), "Second event should be ORDER_READY");
    assertEquals(
        orderId,
        ready.getData().order().id(),
        "Ready event payload should preserve the submitted order id");
  }
}
