package io.diagrid.dapr;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.Testcontainers;
import org.testcontainers.junit.jupiter.Container;

import static org.junit.jupiter.api.Assertions.*;

import java.util.Arrays;
import java.util.Date;
import java.util.List;
import java.util.UUID;

import java.util.Collections;

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

import static io.restassured.RestAssured.*;

@SpringBootTest(classes = PizzaDeliveryAppTest.class, webEnvironment = SpringBootTest.WebEnvironment.DEFINED_PORT)
@org.testcontainers.junit.jupiter.Testcontainers
public class PizzaDeliveryTest {

    @Container
    static DaprContainer dapr = new DaprContainer("daprio/daprd")
            .withAppName("local-dapr-app")
            .withAppPort(8080)
            .withAppChannelAddress("host.testcontainers.internal")
            .withComponent(new Component("pubsub", "pubsub.in-memory", "v1", Collections.emptyMap()))
            .withSubscription(new Subscription("subscription", "pubsub", "topic", "/events"));

    @DynamicPropertySource
    static void daprProperties(DynamicPropertyRegistry registry) {
        Testcontainers.exposeHostPorts(8080);
        registry.add("dapr.grpc.port", dapr::getGrpcPort);
        registry.add("dapr.http.port", dapr::getHttpPort);
    }

    @BeforeAll
    static void setSystemProperties() {
        System.setProperty("dapr.grpc.port", String.valueOf(dapr.getGrpcPort()));
        System.setProperty("dapr.http.port", String.valueOf(dapr.getHttpPort()));
    }

    @Autowired
    private SubscriptionsRestController subscriptionsRestController;

    @Test
    public void testDelivery() throws Exception {
        with().body(new Order(UUID.randomUUID().toString(),
                                Arrays.asList(new OrderItem(PizzaType.pepperoni, 1)),
                                new Date()))
                                .contentType(ContentType.JSON)
        .when()
        .request("PUT", "/deliver")
        .then().assertThat().statusCode(200);

        // Wait for the event to arrive
        Thread.sleep(10000);

        List<CloudEvent<Event>> events = subscriptionsRestController.getAllEvents();
        assertEquals(4, events.size(), "Four published event are expected");
        assertEquals(EventType.ORDER_ON_ITS_WAY, events.get(0).getData().type(), "The content of the cloud event should be the order-out-on-its-way event");
        assertEquals(EventType.ORDER_ON_ITS_WAY, events.get(1).getData().type(), "The content of the cloud event should be the order-out-on-its-way event");
        assertEquals(EventType.ORDER_ON_ITS_WAY, events.get(2).getData().type(), "The content of the cloud event should be the order-out-on-its-way event");
        assertEquals(EventType.ORDER_COMPLETED, events.get(3).getData().type(), "The content of the cloud event should be the order-completed event");
    }
}
