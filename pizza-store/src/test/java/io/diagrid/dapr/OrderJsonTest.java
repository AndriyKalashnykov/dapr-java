package io.diagrid.dapr;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.diagrid.dapr.PizzaStore.Customer;
import io.diagrid.dapr.PizzaStore.Order;
import io.diagrid.dapr.PizzaStore.OrderItem;
import io.diagrid.dapr.PizzaStore.PizzaType;
import io.diagrid.dapr.PizzaStore.Status;
import java.util.Date;
import java.util.List;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.ObjectMapper;

/**
 * Pure-Jackson round-trip tests for the Order record.
 *
 * <p>Defaulting lives inside the {@code @JsonCreator} constructor — null id triggers a UUID, null
 * orderDate triggers `new Date()`, null status defaults to {@code Status.created}. These branches
 * are otherwise only exercised end-to-end through the controller, which makes a regression in the
 * default values invisible to the existing tests. This test class has no Dapr / Spring container —
 * runs in milliseconds, no Docker required.
 */
public class OrderJsonTest {

  // Jackson 3 ObjectMapper. Default StdDateFormat handles ISO-8601 strings on
  // read, defaults to epoch ms on write — both fine for the round-trip test
  // since assertions compare Date.getTime() rather than the wire format.
  private final ObjectMapper mapper = new ObjectMapper();

  @Test
  public void deserializesOrderWithAllFieldsExplicit() throws Exception {
    String json =
        """
        {
            "id": "explicit-1",
            "customer": {"name": "alice", "email": "alice@example.com"},
            "items": [{"type": "pepperoni", "amount": 2}],
            "orderDate": "2024-01-15T10:30:00.000+00:00",
            "status": "completed"
        }
        """;

    Order order = mapper.readValue(json, Order.class);

    assertEquals("explicit-1", order.id(), "Explicit id must be preserved");
    assertEquals("alice", order.customer().name());
    assertEquals(1, order.items().size());
    assertEquals(PizzaType.pepperoni, order.items().get(0).type());
    assertEquals(2, order.items().get(0).amount());
    assertNotNull(order.orderDate(), "Explicit orderDate must be preserved");
    assertEquals(Status.completed, order.status(), "Explicit status must be preserved");
  }

  @Test
  public void appliesIdDefaultWhenMissing() throws Exception {
    String json =
        """
        {
            "customer": {"name": "bob", "email": "bob@example.com"},
            "items": [{"type": "margherita", "amount": 1}],
            "orderDate": "2024-01-15T10:30:00.000+00:00",
            "status": "created"
        }
        """;

    Order order = mapper.readValue(json, Order.class);

    assertNotNull(order.id(), "Missing id must be defaulted to a fresh UUID");
    // UUIDs are 36 chars (8-4-4-4-12 hex with dashes).
    assertEquals(36, order.id().length(), "Defaulted id must look like a UUID");
    assertTrue(order.id().contains("-"), "Defaulted id must look like a UUID");
  }

  @Test
  public void appliesOrderDateDefaultWhenMissing() throws Exception {
    String json =
        """
        {
            "id": "no-date-1",
            "customer": {"name": "c", "email": "c@c"},
            "items": [{"type": "margherita", "amount": 1}],
            "status": "created"
        }
        """;

    long before = System.currentTimeMillis();
    Order order = mapper.readValue(json, Order.class);
    long after = System.currentTimeMillis();

    assertNotNull(order.orderDate(), "Missing orderDate must be defaulted to now");
    long ts = order.orderDate().getTime();
    assertTrue(
        ts >= before && ts <= after,
        "Defaulted orderDate must fall within the deserialization window (was " + ts + ")");
  }

  @Test
  public void appliesStatusDefaultWhenMissing() throws Exception {
    String json =
        """
        {
            "id": "no-status-1",
            "customer": {"name": "d", "email": "d@d"},
            "items": [{"type": "vegetarian", "amount": 1}],
            "orderDate": "2024-01-15T10:30:00.000+00:00"
        }
        """;

    Order order = mapper.readValue(json, Order.class);

    assertEquals(Status.created, order.status(), "Missing status must default to created");
  }

  @Test
  public void serializesAndDeserializesRoundTrip() throws Exception {
    Order original =
        new Order(
            new Customer("eve", "eve@example.com"),
            List.of(new OrderItem(PizzaType.hawaiian, 3)),
            new Date(1_700_000_000_000L),
            Status.delivery);

    String json = mapper.writeValueAsString(original);
    Order roundTripped = mapper.readValue(json, Order.class);

    assertEquals(original.id(), roundTripped.id());
    assertEquals(original.customer(), roundTripped.customer());
    assertEquals(original.items(), roundTripped.items());
    assertEquals(original.status(), roundTripped.status());
    assertEquals(
        original.orderDate().getTime(),
        roundTripped.orderDate().getTime(),
        "Round-trip must preserve orderDate to millisecond precision");
  }

  @Test
  public void copyConstructorPreservesAllFields() {
    Order original =
        new Order(
            new Customer("frank", "frank@example.com"),
            List.of(new OrderItem(PizzaType.pepperoni, 2)),
            new Date(1_700_000_000_000L),
            Status.delivery);

    Order copy = new Order(original);

    assertEquals(original.id(), copy.id(), "Copy must preserve id (NOT generate a new one)");
    assertEquals(original.customer(), copy.customer());
    assertEquals(original.items(), copy.items());
    assertEquals(original.orderDate(), copy.orderDate());
    assertEquals(original.status(), copy.status());
  }

  @Test
  public void twoOrdersWithoutExplicitIdsGetDifferentDefaults() throws Exception {
    String json =
        """
        {
            "customer": {"name": "g", "email": "g@g"},
            "items": [{"type": "margherita", "amount": 1}],
            "orderDate": "2024-01-15T10:30:00.000+00:00",
            "status": "created"
        }
        """;

    Order a = mapper.readValue(json, Order.class);
    Order b = mapper.readValue(json, Order.class);

    assertNotEquals(a.id(), b.id(), "Each defaulted id must be a fresh UUID");
  }
}
