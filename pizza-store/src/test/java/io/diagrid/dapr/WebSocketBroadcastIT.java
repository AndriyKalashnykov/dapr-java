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
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.messaging.converter.JacksonJsonMessageConverter;
import org.springframework.messaging.simp.stomp.StompFrameHandler;
import org.springframework.messaging.simp.stomp.StompHeaders;
import org.springframework.messaging.simp.stomp.StompSession;
import org.springframework.messaging.simp.stomp.StompSessionHandlerAdapter;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.TestSocketUtils;
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
    webEnvironment = SpringBootTest.WebEnvironment.DEFINED_PORT)
@ImportTestcontainers
public class WebSocketBroadcastIT {

  // Allocate a free port at class-load time so DaprContainer's app channel
  // and Spring's embedded Tomcat agree on the port. The WebSocket STOMP
  // client also needs to know the port — connects via ws://localhost:APP_PORT/ws.
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
  public void broadcastsOrderPlacedEventOverWebSocket() throws Exception {
    WebSocketStompClient stompClient = new WebSocketStompClient(new StandardWebSocketClient());
    stompClient.setMessageConverter(new JacksonJsonMessageConverter());

    BlockingQueue<Map<String, Object>> received = new LinkedBlockingQueue<>();

    String url = "ws://localhost:" + APP_PORT + "/ws";
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

  // Posting a CloudEvent with an EventType that PizzaStore.receiveEvents has
  // no branch for (e.g., ORDER_PLACED arriving back from the bus) MUST still
  // (a) succeed (no 500) and (b) broadcast the inbound event over the WS so
  // browsers see every state transition — even ones the store doesn't act
  // on. Regression guard: if a future refactor adds an early-return for
  // unknown types, this test fails and surfaces the broken WS contract.
  @Test
  public void broadcastsUnknownEventTypeOverWebSocket() throws Exception {
    WebSocketStompClient stompClient = new WebSocketStompClient(new StandardWebSocketClient());
    stompClient.setMessageConverter(new JacksonJsonMessageConverter());

    BlockingQueue<Map<String, Object>> received = new LinkedBlockingQueue<>();

    String url = "ws://localhost:" + APP_PORT + "/ws";
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

    Thread.sleep(500);

    String unknownTypeEvent =
        """
        {
            "specversion": "1.0",
            "type": "com.dapr.pizza.event",
            "data": {
                "type": "order-placed",
                "service": "store",
                "message": "echo from bus",
                "order": {
                    "customer": {"name": "carol", "email": "carol@example.com"},
                    "items": [{"type": "margherita", "amount": 1}],
                    "id": "echo-1",
                    "orderDate": "2026-05-05T12:00:00.000+00:00",
                    "status": "created"
                }
            }
        }
        """;

    with()
        .body(unknownTypeEvent)
        .contentType("application/cloudevents+json")
        .when()
        .request("POST", "/events")
        .then()
        .assertThat()
        .statusCode(200);

    await()
        .atMost(Duration.ofSeconds(15))
        .pollInterval(Duration.ofMillis(250))
        .until(() -> !received.isEmpty());

    Map<String, Object> event = received.peek();
    assertNotNull(event, "WS broadcast must fire even for EventTypes the store has no branch for");
    assertEquals("order-placed", event.get("type"), "Inbound event type must propagate");
    assertEquals("store", event.get("service"), "Inbound event service must propagate");

    session.disconnect();
    stompClient.stop();
  }
}
