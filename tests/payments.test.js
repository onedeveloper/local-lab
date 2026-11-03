"use strict";
const { test, before, after, describe } = require("node:test");
const assert = require("node:assert/strict");
const { startService, request } = require("./helpers");

describe("payments-api", () => {
  let svc;
  before(async () => { svc = await startService("payments"); });
  after(() => svc.stop());

  test("GET /health is healthy", async () => {
    const r = await request(svc.url, "GET", "/health");
    assert.equal(r.status, 200);
    assert.deepEqual(r.body, { status: "healthy" });
    assert.match(r.headers.get("content-type"), /application\/json/);
  });

  test("POST /charge approves a valid amount", async () => {
    const r = await request(svc.url, "POST", "/charge", { amount: 50 });
    assert.equal(r.status, 200);
    assert.equal(r.body.status, "approved");
    assert.equal(r.body.amount, 50);
    assert.match(r.body.paymentId, /^[0-9a-f-]{36}$/);
  });

  test("accepts decimal amounts", async () => {
    const r = await request(svc.url, "POST", "/charge", { amount: 0.01 });
    assert.equal(r.status, 200);
    assert.equal(r.body.amount, 0.01);
  });

  test("each charge gets a unique paymentId", async () => {
    const a = await request(svc.url, "POST", "/charge", { amount: 1 });
    const b = await request(svc.url, "POST", "/charge", { amount: 1 });
    assert.notEqual(a.body.paymentId, b.body.paymentId);
  });

  test("amount 1000 is approved (boundary)", async () => {
    const r = await request(svc.url, "POST", "/charge", { amount: 1000 });
    assert.equal(r.status, 200);
  });

  test("amount above 1000 is declined with 402", async () => {
    for (const amount of [1000.01, 1001, 5000]) {
      const r = await request(svc.url, "POST", "/charge", { amount });
      assert.equal(r.status, 402, `amount ${amount}`);
      assert.deepEqual(r.body, { error: "Payment declined" });
    }
  });

  test("invalid amounts are rejected with 400", async () => {
    const bad = [0, -1, "50", null, true, [], {}, undefined];
    for (const amount of bad) {
      const r = await request(svc.url, "POST", "/charge", { amount });
      assert.equal(r.status, 400, `amount ${JSON.stringify(amount)}`);
      assert.deepEqual(r.body, { error: "Invalid amount" });
    }
  });

  test("missing amount field is a 400", async () => {
    const r = await request(svc.url, "POST", "/charge", {});
    assert.equal(r.status, 400);
  });

  test("malformed, empty and null bodies are a 400", async () => {
    for (const body of ["{oops", "", "null"]) {
      const r = await request(svc.url, "POST", "/charge", body);
      assert.equal(r.status, 400, `body ${JSON.stringify(body)}`);
    }
  });

  test("unknown routes and wrong methods are 404", async () => {
    for (const [m, p] of [["GET", "/"], ["GET", "/charge"], ["POST", "/health"], ["POST", "/nope"], ["DELETE", "/charge"]]) {
      const r = await request(svc.url, m, p);
      assert.equal(r.status, 404, `${m} ${p}`);
      assert.deepEqual(r.body, { error: "Not found" });
    }
  });
});

describe("payments-api LOG_LEVEL", () => {
  test("debug logs each request", async () => {
    const s = await startService("payments", { LOG_LEVEL: "debug" });
    try {
      await request(s.url, "POST", "/charge", { amount: 5 });
      assert.match(s.logs(), /POST \/charge/);
    } finally { await s.stop(); }
  });

  test("info does not log requests", async () => {
    const s = await startService("payments", { LOG_LEVEL: "info" });
    try {
      await request(s.url, "POST", "/charge", { amount: 5 });
      assert.doesNotMatch(s.logs(), /POST \/charge/);
    } finally { await s.stop(); }
  });
});
