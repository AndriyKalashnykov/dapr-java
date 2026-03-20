package io.diagrid.dapr;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.context.ImportTestcontainers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.Testcontainers;
import org.testcontainers.containers.Network;

import static org.junit.jupiter.api.Assertions.*;

import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.UUID;

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

import static io.restassured.RestAssured.*;

@SpringBootTest(classes = PizzaKitchenAppTest.class, webEnvironment = SpringBootTest.WebEnvironment.DEFINED_PORT)
@ImportTestcontainers
public class PizzaKitchenTest {

    static {
        Testcontainers.exposeHostPorts(8080);
    }

    static DaprContainer dapr = new DaprContainer(DaprContainer.getDefaultImageName())
            .withNetwork(Network.SHARED)
            .withAppName("local-dapr-app")
            .withAppPort(8080)
            .withAppChannelAddress("host.testcontainers.internal")
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

    @Autowired
    private SubscriptionsRestController subscriptionsRestController;

    @Test
    public void testPrepareOrderRequest() throws Exception {
        with().body(new Order(UUID.randomUUID().toString(),
                                Arrays.asList(new OrderItem(PizzaType.pepperoni, 1)),
                                new Date()))
                                .contentType(ContentType.JSON)
        .when()
        .request("PUT", "/prepare")
        .then().assertThat().statusCode(200);

        // Wait for events: 5s initial delay + up to 15s random prep + delivery margin
        Thread.sleep(25000);

        List<CloudEvent<Event>> events = subscriptionsRestController.getAllEvents();
        assertEquals(2, events.size(), "Two published event are expected");
        assertEquals(EventType.ORDER_IN_PREPARATION, events.get(0).getData().type(), "The content of the cloud event should be the in preparation event");
        assertEquals(EventType.ORDER_READY, events.get(1).getData().type(), "The content of the cloud event should be the ready event");
    }
}
