package io.diagrid.dapr;

import static io.restassured.RestAssured.with;
import static org.awaitility.Awaitility.await;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import io.dapr.testcontainers.Component;
import io.dapr.testcontainers.DaprContainer;
import io.dapr.testcontainers.Subscription;
import io.diagrid.dapr.PizzaStore.Customer;
import io.diagrid.dapr.PizzaStore.Order;
import io.diagrid.dapr.PizzaStore.OrderItem;
import io.diagrid.dapr.PizzaStore.PizzaType;
import io.restassured.RestAssured;
import io.restassured.http.ContentType;
import java.lang.reflect.Type;
import java.time.Duration;
import java.util.Arrays;
import java.util.Collections;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.messaging.converter.JacksonJsonMessageConverter;
import org.springframework.messaging.simp.stomp.StompFrameHandler;
import org.springframework.messaging.simp.stomp.StompHeaders;
import org.springframework.messaging.simp.stomp.StompSession;
import org.springframework.messaging.simp.stomp.StompSessionHandlerAdapter;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.web.socket.client.standard.StandardWebSocketClient;
import org.springframework.web.socket.messaging.WebSocketStompClient;
import org.wiremock.integrations.testcontainers.WireMockContainer;

/**
 * Integration test verifying WebSocket broadcast of ORDER_PLACED events. Connects a STOMP client to
 * the {@code /ws} endpoint configured in {@code WebSocketConfig}, subscribes to {@code
 * /topic/events}, places an order and asserts the broadcast payload.
 */
@SpringBootTest(
    classes = PizzaStoreAppTest.class,
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ImportTestcontainers
public class WebSocketBroadcastIT {

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
  public void broadcastsOrderPlacedEventOverWebSocket() throws Exception {
    WebSocketStompClient stompClient = new WebSocketStompClient(new StandardWebSocketClient());
    stompClient.setMessageConverter(new JacksonJsonMessageConverter());

    BlockingQueue<Map<String, Object>> received = new LinkedBlockingQueue<>();

    String url = "ws://localhost:" + port + "/ws";
    StompSession session =
        stompClient
            .connectAsync(url, new StompSessionHandlerAdapter() {})
            .get(10, java.util.concurrent.TimeUnit.SECONDS);

    session.subscribe(
        "/topic/events",
        new StompFrameHandler() {
          @Override
          public Type getPayloadType(StompHeaders headers) {
            return Map.class;
          }

          @SuppressWarnings("unchecked")
          @Override
          public void handleFrame(StompHeaders headers, Object payload) {
            received.add((Map<String, Object>) payload);
          }
        });

    // Give the subscription a moment to register before publishing.
    Thread.sleep(500);

    Order order =
        new Order(
            new Customer("grace", "grace@example.com"),
            Arrays.asList(new OrderItem(PizzaType.hawaiian, 1)));

    with()
        .body(order)
        .contentType(ContentType.JSON)
        .when()
        .request("POST", "/order")
        .then()
        .assertThat()
        .statusCode(200);

    await()
        .atMost(Duration.ofSeconds(15))
        .pollInterval(Duration.ofMillis(250))
        .until(() -> !received.isEmpty());

    Map<String, Object> event = received.peek();
    assertNotNull(event, "An ORDER_PLACED event should have been broadcast");
    assertEquals("order-placed", event.get("type"), "Event type should be order-placed");
    assertEquals("store", event.get("service"), "Event service should be store");

    @SuppressWarnings("unchecked")
    Map<String, Object> broadcastOrder = (Map<String, Object>) event.get("order");
    assertNotNull(broadcastOrder, "Event should carry the order payload");
    @SuppressWarnings("unchecked")
    Map<String, Object> broadcastCustomer = (Map<String, Object>) broadcastOrder.get("customer");
    assertEquals("grace", broadcastCustomer.get("name"), "Broadcast should preserve customer name");

    session.disconnect();
    stompClient.stop();
  }
}
