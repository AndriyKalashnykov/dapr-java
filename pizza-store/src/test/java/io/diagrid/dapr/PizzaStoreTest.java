package io.diagrid.dapr;

import static io.restassured.RestAssured.get;
import static io.restassured.RestAssured.with;
import static org.hamcrest.Matchers.notNullValue;

import io.dapr.testcontainers.DaprContainer;
import io.diagrid.dapr.PizzaStore.Customer;
import io.diagrid.dapr.PizzaStore.Order;
import io.diagrid.dapr.PizzaStore.OrderItem;
import io.diagrid.dapr.PizzaStore.PizzaType;
import io.restassured.RestAssured;
import io.restassured.http.ContentType;
import java.util.Arrays;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.wiremock.integrations.testcontainers.WireMockContainer;

@SpringBootTest(
    classes = PizzaStoreAppTest.class,
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ImportTestcontainers
public class PizzaStoreTest {

  static DaprContainer dapr =
      new DaprContainer(DaprContainer.getDefaultImageName())
          .withAppName("local-dapr-app")
          .withAppPort(8080)
          .withAppChannelAddress("host.testcontainers.internal")
          .withExtraHost("host.testcontainers.internal", "host-gateway");

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
  public void testPlaceOrder() throws Exception {
    with()
        .body(
            new Order(
                new Customer("Customer", "customer@example.com"),
                Arrays.asList(new OrderItem(PizzaType.pepperoni, 1))))
        .contentType(ContentType.JSON)
        .when()
        .request("POST", "/order")
        .then()
        .assertThat()
        .statusCode(200);
  }

  @Test
  public void testGetOrders() {
    get("/order").then().assertThat().statusCode(200);
  }

  @Test
  public void testReceiveEvent() {
    String cloudEvent =
        """
        {
            "specversion": "1.0",
            "type": "com.dapr.pizza.event",
            "data": {
                "type": "order-in-preparation",
                "service": "kitchen",
                "message": "Your Order is in the kitchen.",
                "order": {
                    "customer": {"name": "Customer", "email": "customer@example.com"},
                    "items": [{"type": "pepperoni", "amount": 1}],
                    "id": "test-order-1",
                    "orderDate": "2023-10-31T18:13:55.571+00:00",
                    "status": "inpreparation"
                }
            }
        }
        """;

    with()
        .body(cloudEvent)
        .contentType("application/cloudevents+json")
        .when()
        .request("POST", "/events")
        .then()
        .assertThat()
        .statusCode(200);
  }

  @Test
  public void testPlaceAndRetrieveOrder() throws Exception {
    Order order =
        new Order(
            new Customer("testuser", "test@mail.com"),
            Arrays.asList(new OrderItem(PizzaType.margherita, 2)));

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

    // Allow async thread to store the order
    Thread.sleep(2000);

    get("/order").then().assertThat().statusCode(200).body("orders", notNullValue());
  }
}
