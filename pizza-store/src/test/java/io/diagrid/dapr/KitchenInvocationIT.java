package io.diagrid.dapr;

import static com.github.tomakehurst.wiremock.client.WireMock.aResponse;
import static com.github.tomakehurst.wiremock.client.WireMock.matchingJsonPath;
import static com.github.tomakehurst.wiremock.client.WireMock.postRequestedFor;
import static com.github.tomakehurst.wiremock.client.WireMock.put;
import static com.github.tomakehurst.wiremock.client.WireMock.putRequestedFor;
import static com.github.tomakehurst.wiremock.client.WireMock.urlEqualTo;
import static io.restassured.RestAssured.with;
import static org.awaitility.Awaitility.await;

import com.github.tomakehurst.wiremock.client.WireMock;
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
 * Integration test verifying the kitchen-service invocation shape. Architectural compromise: the
 * Dapr Testcontainers SDK (1.17.1) supports only a single registered app per {@link DaprContainer},
 * so we cannot stand up a real peer kitchen service behind the sidecar. Instead we override {@code
 * DAPR_HTTP_ENDPOINT} to point directly at WireMock — this still verifies the HTTP contract (path,
 * verb, body shape) that {@code PizzaStore} emits toward the sidecar, but bypasses the sidecar's
 * service-invocation hop itself. That gap is covered by e2e tests on KinD.
 */
@SpringBootTest(
    classes = PizzaStoreAppTest.class,
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ImportTestcontainers
public class KitchenInvocationIT {

  static DaprContainer dapr =
      new DaprContainer(DaprContainer.getDefaultImageName())
          .withAppName("local-dapr-app")
          .withAppPort(8080)
          .withAppChannelAddress("host.testcontainers.internal")
          .withExtraHost("host.testcontainers.internal", "host-gateway")
          .withComponent(new Component("kvstore", "state.in-memory", "v1", Collections.emptyMap()))
          .withComponent(new Component("pubsub", "pubsub.in-memory", "v1", Collections.emptyMap()))
          .withSubscription(new Subscription("subscription", "pubsub", "topic", "/events"));

  static WireMockContainer wireMock = new WireMockContainer("wiremock/wiremock:3.1.0");

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
    WireMock.configureFor(wireMock.getHost(), wireMock.getPort());
    WireMock.reset();
    // Kitchen stub
    WireMock.stubFor(put(urlEqualTo("/prepare")).willReturn(aResponse().withStatus(200)));
    // Delivery stub (not invoked by this test, but avoids connection errors if fired)
    WireMock.stubFor(put(urlEqualTo("/deliver")).willReturn(aResponse().withStatus(200)));
  }

  @Test
  public void placeOrderTriggersKitchenInvocation() {
    Order order =
        new Order(
            new Customer("eve", "eve@example.com"),
            Arrays.asList(
                new OrderItem(PizzaType.pepperoni, 2), new OrderItem(PizzaType.margherita, 1)));

    with()
        .body(order)
        .contentType(ContentType.JSON)
        .when()
        .request("POST", "/order")
        .then()
        .assertThat()
        .statusCode(200);

    // The invocation happens on a background thread.
    await()
        .atMost(Duration.ofSeconds(15))
        .pollInterval(Duration.ofMillis(500))
        .untilAsserted(
            () ->
                WireMock.verify(
                    putRequestedFor(urlEqualTo("/prepare"))
                        .withRequestBody(
                            matchingJsonPath("$.customer.name", WireMock.equalTo("eve")))
                        .withRequestBody(
                            matchingJsonPath(
                                "$.customer.email", WireMock.equalTo("eve@example.com")))
                        .withRequestBody(matchingJsonPath("$.items[0].type"))
                        .withRequestBody(matchingJsonPath("$.items[1].type"))
                        .withRequestBody(matchingJsonPath("$.id"))));

    // Sanity: verify we did NOT accidentally POST (wrong verb).
    WireMock.verify(0, postRequestedFor(urlEqualTo("/prepare")));
  }
}
