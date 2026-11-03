"use strict";
// Real orders + payments + inventory processes talking to each other (no stubs).
const { test, before, after, describe } = require("node:test");
const assert = require("node:assert/strict");
const { startService, request } = require("./helpers");

describe("order flow (all three services)", () => {
  let inventory, payments, orders;
  before(async () => {
    inventory = await startService("inventory");
    payments = await startService("payments");
    orders = await startService("orders", { INVENTORY_URL: inventory.url, PAYMENTS_URL: payments.url });
  });
  after(async () => { await orders.stop(); await payments.stop(); await inventory.stop(); });

  test("a valid order is reserved and paid", async () => {
    const r = await request(orders.url, "POST", "/orders", { productId: "A1", quantity: 2, amount: 50 });
    assert.equal(r.status, 201);
    assert.equal(r.body.status, "completed");
    assert.equal(r.body.reservation.status, "reserved");
    assert.equal(r.body.reservation.productId, "A1");
    assert.equal(r.body.reservation.quantity, 2);
    assert.equal(r.body.payment.status, "approved");
    assert.equal(r.body.payment.amount, 50);
  });

  test("an out-of-stock product is rejected with 409", async () => {
    const r = await request(orders.url, "POST", "/orders", { productId: "OUT-OF-STOCK", quantity: 1, amount: 10 });
    assert.equal(r.status, 409);
    assert.equal(r.body.error, "Insufficient inventory");
  });

  test("an amount over 1000 is declined with 402", async () => {
    const r = await request(orders.url, "POST", "/orders", { productId: "A1", quantity: 1, amount: 5000 });
    assert.equal(r.status, 402);
    assert.equal(r.body.error, "Payment declined");
  });

  test("an invalid order is rejected with 400", async () => {
    const r = await request(orders.url, "POST", "/orders", { productId: "", quantity: 0, amount: -1 });
    assert.equal(r.status, 400);
  });

  test("concurrent orders all succeed with distinct ids", async () => {
    const results = await Promise.all(
      Array.from({ length: 20 }, (_, i) =>
        request(orders.url, "POST", "/orders", { productId: `P${i}`, quantity: 1, amount: 10 + i })));
    assert.deepEqual(results.map((r) => r.status), Array(20).fill(201));
    assert.equal(new Set(results.map((r) => r.body.orderId)).size, 20);
  });

  test("orders return 502 while payments is down and 201 once it is back", async () => {
    // own services so the shared ones above are not disturbed
    const inv = await startService("inventory");
    let pay = await startService("payments");
    const payPort = pay.port;
    const ord = await startService("orders", { INVENTORY_URL: inv.url, PAYMENTS_URL: pay.url });
    const order = { productId: "A1", quantity: 1, amount: 10 };
    try {
      assert.equal((await request(ord.url, "POST", "/orders", order)).status, 201);
      await pay.stop();
      assert.equal((await request(ord.url, "POST", "/orders", order)).status, 502);
      // bring payments back on the SAME port; orders should recover without a restart
      pay = await startService("payments", { PORT: String(payPort) });
      assert.equal(pay.port, payPort);
      assert.equal((await request(ord.url, "POST", "/orders", order)).status, 201);
    } finally { await ord.stop(); await pay.stop(); await inv.stop(); }
  });
});
