package io.diagrid.dapr;

import static java.util.Collections.singletonMap;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonValue;
import io.dapr.client.DaprClient;
import io.dapr.client.DaprClientBuilder;
import io.dapr.client.domain.Metadata;
import java.util.Date;
import java.util.List;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

@SpringBootApplication
@RestController
public class PizzaDelivery {

  private static final String MESSAGE_TTL_IN_SECONDS = "1000";
  private static final int DELIVERY_STAGE_DELAY_MS = 3000;

  @Value("${PUB_SUB_NAME:pubsub}")
  private String pubSubName;

  @Value("${PUB_SUB_TOPIC:topic}")
  private String pubSubTopic;

  public static void main(String[] args) {
    SpringApplication.run(PizzaDelivery.class, args);
  }

  @PutMapping("/deliver")
  public ResponseEntity deliverOrder(@RequestBody(required = true) Order order) {
    new Thread(
            new Runnable() {
              @Override
              public void run() {
                Event event =
                    new Event(
                        EventType.ORDER_ON_ITS_WAY,
                        order,
                        "delivery",
                        "The order is on its way to your address.");
                emitEvent(event);

                try {
                  Thread.sleep(DELIVERY_STAGE_DELAY_MS);
                } catch (InterruptedException e) {
                  e.printStackTrace();
                }

                event =
                    new Event(
                        EventType.ORDER_ON_ITS_WAY, order, "delivery", "The order is 1 mile away.");
                emitEvent(event);

                try {
                  Thread.sleep(DELIVERY_STAGE_DELAY_MS);
                } catch (InterruptedException e) {
                  e.printStackTrace();
                }

                event =
                    new Event(
                        EventType.ORDER_ON_ITS_WAY,
                        order,
                        "delivery",
                        "The order is 0.5 miles away.");
                emitEvent(event);

                try {
                  Thread.sleep(DELIVERY_STAGE_DELAY_MS);
                } catch (InterruptedException e) {
                  e.printStackTrace();
                }

                event =
                    new Event(
                        EventType.ORDER_COMPLETED,
                        order,
                        "delivery",
                        "Your order has been delivered.");
                emitEvent(event);
              }
            })
        .start();

    return ResponseEntity.ok().build();
  }

  public record Event(EventType type, Order order, String service, String message) {}

  public enum EventType {
    ORDER_PLACED("order-placed"),
    ITEMS_IN_STOCK("items-in-stock"),
    ITEMS_NOT_IN_STOCK("items-not-in-stock"),
    ORDER_IN_PREPARATION("order-in-preparation"),
    ORDER_READY("order-ready"),
    ORDER_OUT_FOR_DELIVERY("order-out-for-delivery"),
    ORDER_ON_ITS_WAY("order-on-its-way"),
    ORDER_COMPLETED("order-completed");

    private String type;

    EventType(String type) {
      this.type = type;
    }

    @JsonValue
    public String getType() {
      return type;
    }
  }

  public record Order(
      @JsonProperty String id, @JsonProperty List<OrderItem> items, @JsonProperty Date orderDate) {}

  public record OrderItem(@JsonProperty PizzaType type, @JsonProperty int amount) {}

  public enum PizzaType {
    pepperoni,
    margherita,
    hawaiian,
    vegetarian
  }

  private void emitEvent(Event event) {
    System.out.println("> Emitting Delivery Event: " + event.toString());
    try (DaprClient client = (new DaprClientBuilder()).build()) {
      client
          .publishEvent(
              pubSubName,
              pubSubTopic,
              event,
              singletonMap(Metadata.TTL_IN_SECONDS, MESSAGE_TTL_IN_SECONDS))
          .block();
    } catch (Exception ex) {
      ex.printStackTrace();
    }
  }
}
