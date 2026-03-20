package io.diagrid.dapr;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.Testcontainers;
import org.testcontainers.containers.Network;
import org.wiremock.integrations.testcontainers.WireMockContainer;

import io.dapr.testcontainers.DaprContainer;
import io.diagrid.dapr.PizzaStore.Customer;
import io.diagrid.dapr.PizzaStore.Order;
import io.diagrid.dapr.PizzaStore.OrderItem;
import io.diagrid.dapr.PizzaStore.PizzaType;
import io.restassured.RestAssured;
import io.restassured.http.ContentType;
import static io.restassured.RestAssured.with;
import java.util.Arrays;

@SpringBootTest(classes = PizzaStoreAppTest.class, webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ImportTestcontainers
public class PizzaStoreTest {

    static {
        Testcontainers.exposeHostPorts(8080);
    }

    static DaprContainer dapr = new DaprContainer(DaprContainer.getDefaultImageName())
            .withNetwork(Network.SHARED)
            .withAppName("local-dapr-app")
            .withAppPort(8080)
            .withAppChannelAddress("host.testcontainers.internal");

    static WireMockContainer wireMock = new WireMockContainer("wiremock/wiremock:3.1.0")
            .withMappingFromResource("kitchen", "kitchen-service-stubs.json");

    @DynamicPropertySource
    static void daprProperties(DynamicPropertyRegistry registry) {
        registry.add("dapr.grpc.port", dapr::getGrpcPort);
        registry.add("dapr.http.port", dapr::getHttpPort);
        registry.add("dapr-http.base-url", wireMock::getBaseUrl);
    }

    @BeforeEach
    void setSystemProperties() {
        System.setProperty("dapr.grpc.port", String.valueOf(dapr.getGrpcPort()));
        System.setProperty("dapr.http.port", String.valueOf(dapr.getHttpPort()));
    }

    @LocalServerPort
    private int port;

    @BeforeEach
    public void setUp() {
        RestAssured.port = port;
    }

    @Test
    public void testPlaceOrder() throws Exception {
       with().body(new Order(new Customer("salaboy", "salaboy@mail.com"),
                                Arrays.asList(new OrderItem(PizzaType.pepperoni, 1))))
                                .contentType(ContentType.JSON)
        .when()
        .request("POST", "/order")
        .then().assertThat().statusCode(200);
    }
}
