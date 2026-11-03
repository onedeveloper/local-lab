"use strict";
const { test, before, after, describe } = require("node:test");
const assert = require("node:assert/strict");
const { startService, request } = require("./helpers");

describe("inventory-api", () => {
  let svc;
  before(async () => { svc = await startService("inventory"); });
  after(() => svc.stop());

  test("GET /health is healthy", async () => {
    const r = await request(svc.url, "GET", "/health");
    assert.equal(r.status, 200);
    assert.deepEqual(r.body, { status: "healthy" });
  });

  test("POST /reserve reserves stock", async () => {
    const r = await request(svc.url, "POST", "/reserve", { productId: "A1", quantity: 2 });
    assert.equal(r.status, 200);
    assert.equal(r.body.status, "reserved");
    assert.equal(r.body.productId, "A1");
    assert.equal(r.body.quantity, 2);
    assert.match(r.body.reservationId, /^[0-9a-f-]{36}$/);
  });

  test("each reservation gets a unique id", async () => {
    const a = await request(svc.url, "POST", "/reserve", { productId: "A1", quantity: 1 });
    const b = await request(svc.url, "POST", "/reserve", { productId: "A1", quantity: 1 });
    assert.notEqual(a.body.reservationId, b.body.reservationId);
  });

  test("OUT-OF-STOCK returns 409", async () => {
    const r = await request(svc.url, "POST", "/reserve", { productId: "OUT-OF-STOCK", quantity: 1 });
    assert.equal(r.status, 409);
    assert.deepEqual(r.body, { error: "Insufficient inventory" });
  });

  test("invalid productId is rejected with 400", async () => {
    for (const productId of ["", null, undefined, 0]) {
      const r = await request(svc.url, "POST", "/reserve", { productId, quantity: 1 });
      assert.equal(r.status, 400, `productId ${JSON.stringify(productId)}`);
      assert.deepEqual(r.body, { error: "Invalid reservation" });
    }
  });

  test("invalid quantity is rejected with 400", async () => {
    for (const quantity of [0, -1, 1.5, "2", null, undefined, NaN]) {
      const r = await request(svc.url, "POST", "/reserve", { productId: "A1", quantity });
      assert.equal(r.status, 400, `quantity ${JSON.stringify(quantity)}`);
    }
  });

  test("malformed, empty and null bodies are a 400", async () => {
    for (const body of ["{oops", "", "null"]) {
      const r = await request(svc.url, "POST", "/reserve", body);
      assert.equal(r.status, 400, `body ${JSON.stringify(body)}`);
    }
  });

  test("unknown routes and wrong methods are 404", async () => {
    for (const [m, p] of [["GET", "/"], ["GET", "/reserve"], ["POST", "/health"], ["POST", "/charge"]]) {
      const r = await request(svc.url, m, p);
      assert.equal(r.status, 404, `${m} ${p}`);
    }
  });
});

describe("inventory-api LOG_LEVEL", () => {
  test("debug logs each request, info does not", async () => {
    const d = await startService("inventory", { LOG_LEVEL: "debug" });
    const i = await startService("inventory", { LOG_LEVEL: "info" });
    try {
      await request(d.url, "POST", "/reserve", { productId: "A1", quantity: 1 });
      await request(i.url, "POST", "/reserve", { productId: "A1", quantity: 1 });
      assert.match(d.logs(), /POST \/reserve/);
      assert.doesNotMatch(i.logs(), /POST \/reserve/);
    } finally { await d.stop(); await i.stop(); }
  });
});
