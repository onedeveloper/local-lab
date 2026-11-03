"use strict";
const { spawn } = require("node:child_process");
const http = require("node:http");
const net = require("node:net");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const serviceDir = (name) => path.join(ROOT, "k8s", "base", name);

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

async function waitFor(url, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const res = await fetch(url);
      if (res.ok) return;
    } catch {}
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${url}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

// Start one of the real services (orders | payments | inventory) on a free port.
async function startService(name, env = {}) {
  const port = env.PORT ? Number(env.PORT) : await freePort();
  const child = spawn(process.execPath, ["src/server.js"], {
    cwd: serviceDir(name),
    env: { ...process.env, ...env, PORT: String(port) },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let logs = "";
  child.stdout.on("data", (d) => (logs += d));
  child.stderr.on("data", (d) => (logs += d));
  const url = `http://127.0.0.1:${port}`;
  try {
    await waitFor(`${url}/health`);
  } catch (e) {
    child.kill();
    throw new Error(`${name} failed to start: ${e.message}\n${logs}`);
  }
  return {
    url,
    port,
    logs: () => logs,
    stop: () =>
      new Promise((resolve) => {
        if (child.exitCode !== null) return resolve();
        child.once("exit", resolve);
        child.kill();
      }),
  };
}

// Tiny controllable HTTP server used to stand in for a dependency.
// handler(req, body, res) decides the response; calls are recorded.
async function startStub(handler) {
  const calls = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      let json;
      try { json = JSON.parse(body); } catch { json = undefined; }
      calls.push({ method: req.method, url: req.url, body: json });
      handler(req, json, res);
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const sockets = new Set();
  server.on("connection", (s) => { sockets.add(s); s.on("close", () => sockets.delete(s)); });
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    calls,
    stop: () => new Promise((r) => { sockets.forEach((s) => s.destroy()); server.close(r); }),
  };
}

const json = (res, status, data) => {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
};

// Returns { status, body (parsed JSON or raw text), headers }.
async function request(base, method, p, body) {
  const res = await fetch(base + p, {
    method,
    headers: body === undefined ? {} : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
  const text = await res.text();
  let parsed = text;
  try { parsed = JSON.parse(text); } catch {}
  return { status: res.status, body: parsed, headers: res.headers };
}

module.exports = { ROOT, startService, startStub, request, json, freePort };
