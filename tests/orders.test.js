"use strict";
const { test, before, after, beforeEach, describe } = require("node:test");
const assert = require("node:assert/strict");
const { startService, startStub, request, json, freePort } = require("./helpers");

const validOrder = { productId: "A1", quantity: 2, amount: 50 };

describe("orders-api", () => {
  let orders, inventory, payments;
  // Behaviour of the stubbed dependencies, reset before every test.
  let inventoryHandler, paymentsHandler;

  before(async () => {
    inventory = await startStub((req, body, res) => inventoryHandler(req, body, res));
    payments = await startStub((req, body, res) => paymentsHandler(req, body, res));
    orders = await startService("orders", { INVENTORY_URL: inventory.url, PAYMENTS_URL: payments.url });
  });
  after(async () => { await orders.stop(); await inventory.stop(); await payments.stop(); });
  beforeEach(() => {
    inventory.calls.length = 0;
    payments.calls.length = 0;
    inventoryHandler = (req, b, res) => json(res, 200, { reservationId: "r-1", status: "reserved" });
    paymentsHandler = (req, b, res) => json(res, 200, { paymentId: "p-1", status: "approved" });
  });

  describe("routes", () => {
    test("GET /health is healthy", async () => {
      const r = await request(orders.url, "GET", "/health");
      assert.equal(r.status, 200);
      assert.deepEqual(r.body, { status: "healthy" });
    });

    test("GET / describes the endpoints", async () => {
      const r = await request(orders.url, "GET", "/");
      assert.equal(r.status, 200);
      assert.equal(r.body.service, "orders-api");
      const keys = r.body.endpoints.map((e) => `${e.method} ${e.path}`);
      assert.deepEqual(keys.sort(), ["GET /", "GET /health", "POST /orders"].sort());
      const post = r.body.endpoints.find((e) => e.method === "POST");
      assert.deepEqual(Object.keys(post.responses).sort(), ["201", "400", "402", "409", "502"]);
    });

    test("unknown routes and wrong methods are 404", async () => {
      for (const [m, p] of [["GET", "/orders"], ["POST", "/"], ["POST", "/health"], ["GET", "/nope"], ["PUT", "/orders"]]) {
        const r = await request(orders.url, m, p);
        assert.equal(r.status, 404, `${m} ${p}`);
        assert.deepEqual(r.body, { error: "Not found" });
      }
    });
  });

  describe("POST /orders: happy path", () => {
    test("completes an order and returns both dependency results", async () => {
      const r = await request(orders.url, "POST", "/orders", validOrder);
      assert.equal(r.status, 201);
      assert.equal(r.body.status, "completed");
      assert.match(r.body.orderId, /^[0-9a-f-]{36}$/);
      assert.deepEqual(r.body.reservation, { reservationId: "r-1", status: "reserved" });
      assert.deepEqual(r.body.payment, { paymentId: "p-1", status: "approved" });
    });

    test("forwards only the relevant fields, to the right endpoints", async () => {
      await request(orders.url, "POST", "/orders", { ...validOrder, extra: "ignored" });
      assert.deepEqual(inventory.calls, [{ method: "POST", url: "/reserve", body: { productId: "A1", quantity: 2 } }]);
      assert.deepEqual(payments.calls, [{ method: "POST", url: "/charge", body: { amount: 50 } }]);
    });

    test("reserves inventory before charging payment", async () => {
      const order = [];
      inventoryHandler = (req, b, res) => { order.push("inventory"); json(res, 200, {}); };
      paymentsHandler = (req, b, res) => { order.push("payments"); json(res, 200, {}); };
      await request(orders.url, "POST", "/orders", validOrder);
      assert.deepEqual(order, ["inventory", "payments"]);
    });

    test("each order gets a unique orderId", async () => {
      const a = await request(orders.url, "POST", "/orders", validOrder);
      const b = await request(orders.url, "POST", "/orders", validOrder);
      assert.notEqual(a.body.orderId, b.body.orderId);
    });
  });

  describe("POST /orders: validation (400, no dependency called)", () => {
    const cases = {
      "missing productId": { quantity: 1, amount: 10 },
      "blank productId": { productId: "   ", quantity: 1, amount: 10 },
      "numeric productId": { productId: 5, quantity: 1, amount: 10 },
      "quantity 0": { productId: "A1", quantity: 0, amount: 10 },
      "negative quantity": { productId: "A1", quantity: -2, amount: 10 },
      "fractional quantity": { productId: "A1", quantity: 1.5, amount: 10 },
      "string quantity": { productId: "A1", quantity: "2", amount: 10 },
      "missing quantity": { productId: "A1", amount: 10 },
      "amount 0": { productId: "A1", quantity: 1, amount: 0 },
      "negative amount": { productId: "A1", quantity: 1, amount: -5 },
      "string amount": { productId: "A1", quantity: 1, amount: "10" },
      "missing amount": { productId: "A1", quantity: 1 },
      "empty object": {},
      "array body": [],
    };
    for (const [name, body] of Object.entries(cases)) {
      test(name, async () => {
        const r = await request(orders.url, "POST", "/orders", body);
        assert.equal(r.status, 400);
        assert.deepEqual(r.body, { error: "Invalid order" });
        assert.equal(inventory.calls.length + payments.calls.length, 0);
      });
    }

    test("malformed JSON, empty body and null are a 400", async () => {
      for (const [body, error] of [["{oops", "Invalid JSON"], ["", "Invalid JSON"], ["null", "Invalid order"]]) {
        const r = await request(orders.url, "POST", "/orders", body);
        assert.equal(r.status, 400, `body ${JSON.stringify(body)}`);
        assert.equal(r.body.error, error);
      }
      assert.equal(inventory.calls.length + payments.calls.length, 0);
    });
  });

  describe("POST /orders: dependency failures", () => {
    test("inventory 409 is passed through and payment is never attempted", async () => {
      inventoryHandler = (req, b, res) => json(res, 409, { error: "Insufficient inventory" });
      const r = await request(orders.url, "POST", "/orders", validOrder);
      assert.equal(r.status, 409);
      assert.deepEqual(r.body, { error: "Insufficient inventory" });
      assert.equal(payments.calls.length, 0);
    });

    test("payment 402 is passed through", async () => {
      paymentsHandler = (req, b, res) => json(res, 402, { error: "Payment declined" });
      const r = await request(orders.url, "POST", "/orders", validOrder);
      assert.equal(r.status, 402);
      assert.deepEqual(r.body, { error: "Payment declined" });
      assert.equal(inventory.calls.length, 1);
    });

    test("dependency 5xx becomes 502", async () => {
      inventoryHandler = (req, b, res) => json(res, 500, { error: "boom" });
      const r = await request(orders.url, "POST", "/orders", validOrder);
      assert.equal(r.status, 502);
      assert.equal(payments.calls.length, 0);
    });

    test("non-JSON dependency response becomes 502", async () => {
      paymentsHandler = (req, b, res) => { res.writeHead(200); res.end("<html>not json</html>"); };
      const r = await request(orders.url, "POST", "/orders", validOrder);
      assert.equal(r.status, 502);
    });

    test("dependency that closes the connection becomes 502", async () => {
      inventoryHandler = (req) => req.socket.destroy();
      const r = await request(orders.url, "POST", "/orders", validOrder);
      assert.equal(r.status, 502);
    });

    test("unreachable dependency becomes 502", async () => {
      const dead = `http://127.0.0.1:${await freePort()}`;
      const o = await startService("orders", { INVENTORY_URL: dead, PAYMENTS_URL: payments.url });
      try {
        const r = await request(o.url, "POST", "/orders", validOrder);
        assert.equal(r.status, 502);
        assert.equal(payments.calls.length, 0);
      } finally { await o.stop(); }
    });

    test("a dependency that never answers times out as 502 (about 3s)", { timeout: 10000 }, async () => {
      inventoryHandler = () => {}; // never respond
      const started = Date.now();
      const r = await request(orders.url, "POST", "/orders", validOrder);
      const elapsed = Date.now() - started;
      assert.equal(r.status, 502);
      assert.ok(elapsed >= 2500 && elapsed < 6000, `expected ~3s timeout, took ${elapsed}ms`);
    });

    test("the service keeps working after a failed order", async () => {
      inventoryHandler = (req, b, res) => json(res, 500, {});
      await request(orders.url, "POST", "/orders", validOrder);
      inventoryHandler = (req, b, res) => json(res, 200, {});
      const r = await request(orders.url, "POST", "/orders", validOrder);
      assert.equal(r.status, 201);
    });
  });

  describe("configuration", () => {
    test("dependency URLs default to the in-cluster service names", () => {
      const src = require("node:fs").readFileSync(
        require("node:path").join(__dirname, "..", "k8s", "base", "orders", "src", "server.js"), "utf8");
      assert.match(src, /INVENTORY_URL \|\| "http:\/\/inventory-api"/);
      assert.match(src, /PAYMENTS_URL \|\| "http:\/\/payments-api"/);
    });

    test("LOG_LEVEL=debug logs requests", async () => {
      const o = await startService("orders", { LOG_LEVEL: "debug" });
      try {
        await request(o.url, "GET", "/");
        assert.match(o.logs(), /GET \//);
      } finally { await o.stop(); }
    });
  });
});
