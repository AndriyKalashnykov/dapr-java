package io.diagrid.dapr;

import static com.github.tomakehurst.wiremock.client.WireMock.aResponse;
import static com.github.tomakehurst.wiremock.client.WireMock.matchingJsonPath;
import static com.github.tomakehurst.wiremock.client.WireMock.put;
import static com.github.tomakehurst.wiremock.client.WireMock.putRequestedFor;
import static com.github.tomakehurst.wiremock.client.WireMock.urlEqualTo;
import static io.restassured.RestAssured.with;
import static org.awaitility.Awaitility.await;

import com.github.tomakehurst.wiremock.client.WireMock;
import io.dapr.testcontainers.Component;
import io.dapr.testcontainers.DaprContainer;
import io.dapr.testcontainers.Subscription;
import io.restassured.RestAssured;
import java.time.Duration;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.wiremock.integrations.testcontainers.WireMockContainer;

/**
 * Integration test verifying the delivery-service invocation is triggered when an ORDER_READY
 * CloudEvent arrives on the store's pub/sub subscriber endpoint. Same architectural compromise as
 * {@link KitchenInvocationIT}: {@code DAPR_HTTP_ENDPOINT} is aimed at WireMock to capture the
 * outbound call shape.
 */
@SpringBootTest(
    classes = PizzaStoreAppTest.class,
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ImportTestcontainers
public class DeliveryInvocationIT {

  private static final String ORDER_ID = "it-delivery-order-1";

  static DaprContainer dapr =
      new DaprContainer(DaprContainer.getDefaultImageName())
          .withAppName("local-dapr-app")
          .withAppPort(8080)
          .withAppChannelAddress("host.testcontainers.internal")
          .withExtraHost("host.testcontainers.internal", "host-gateway")
          .withComponent(
              new Component("kvstore", "state.in-memory", "v1", java.util.Collections.emptyMap()))
          .withComponent(
              new Component("pubsub", "pubsub.in-memory", "v1", java.util.Collections.emptyMap()))
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
    WireMock.stubFor(put(urlEqualTo("/prepare")).willReturn(aResponse().withStatus(200)));
    WireMock.stubFor(put(urlEqualTo("/deliver")).willReturn(aResponse().withStatus(200)));
  }

  @Test
  public void orderReadyEventTriggersDeliveryInvocation() {
    String cloudEvent =
        """
        {
            "specversion": "1.0",
            "type": "com.dapr.event.sent",
            "source": "kitchen-service",
            "id": "evt-1",
            "datacontenttype": "application/json",
            "data": {
                "type": "order-ready",
                "service": "kitchen",
                "message": "Your pizza is ready.",
                "order": {
                    "customer": {"name": "frank", "email": "frank@example.com"},
                    "items": [{"type": "pepperoni", "amount": 1}],
                    "id": "%s",
                    "orderDate": "2026-01-01T00:00:00.000+00:00",
                    "status": "inpreparation"
                }
            }
        }
        """
            .formatted(ORDER_ID);

    with()
        .body(cloudEvent)
        .contentType("application/cloudevents+json")
        .when()
        .request("POST", "/events")
        .then()
        .assertThat()
        .statusCode(200);

    await()
        .atMost(Duration.ofSeconds(15))
        .pollInterval(Duration.ofMillis(500))
        .untilAsserted(
            () ->
                WireMock.verify(
                    putRequestedFor(urlEqualTo("/deliver"))
                        .withRequestBody(matchingJsonPath("$.id", WireMock.equalTo(ORDER_ID)))
                        .withRequestBody(
                            matchingJsonPath("$.customer.name", WireMock.equalTo("frank")))
                        .withRequestBody(matchingJsonPath("$.items[0].type"))));
  }
}
