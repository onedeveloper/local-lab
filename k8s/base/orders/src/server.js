const http = require("node:http");
const crypto = require("node:crypto");

const PORT = Number(process.env.PORT) || 3000;
const LOG_LEVEL = process.env.LOG_LEVEL || "info";

const INVENTORY_URL = process.env.INVENTORY_URL || "http://inventory-api";

const PAYMENTS_URL = process.env.PAYMENTS_URL || "http://payments-api";

function respond(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

async function callService(url, payload) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(3000),
  });

  const result = await response.json();

  if (!response.ok) {
    const error = new Error(result.error || "Dependency failed");
    error.status = response.status;
    throw error;
  }

  return result;
}

http
  .createServer(async (req, res) => {
    if (LOG_LEVEL === "debug") console.log(`${req.method} ${req.url}`);

    if (req.url === "/" && req.method === "GET") {
      return respond(res, 200, {
        service: "orders-api",
        endpoints: [
          { method: "GET", path: "/", description: "This description: V2" },
          { method: "GET", path: "/health", description: "Health check" },
          {
            method: "POST",
            path: "/orders",
            description:
              "Create an order: reserves stock in inventory-api, then charges payments-api",
            body: {
              productId: "string",
              quantity: "integer >= 1",
              amount: "number > 0",
            },
            example: { productId: "A1", quantity: 2, amount: 50 },
            responses: {
              201: "order completed",
              400: "invalid order or JSON",
              402: "payment declined (amount > 1000)",
              409: "insufficient inventory (productId OUT-OF-STOCK)",
              502: "a dependency is unreachable",
            },
          },
        ],
      });
    }

    if (req.url === "/health" && req.method === "GET") {
      return respond(res, 200, { status: "healthy" });
    }

    if (req.url === "/orders" && req.method === "POST") {
      let body = "";

      req.on("data", (chunk) => (body += chunk));

      req.on("end", async () => {
        try {
          let order;
          try {
            order = JSON.parse(body);
          } catch {
            return respond(res, 400, { error: "Invalid JSON" });
          }
          const { productId, quantity, amount } = order || {};

          if (
            typeof productId !== "string" ||
            !productId.trim() ||
            !Number.isInteger(quantity) ||
            quantity < 1 ||
            typeof amount !== "number" ||
            !Number.isFinite(amount) ||
            amount <= 0
          ) {
            return respond(res, 400, { error: "Invalid order" });
          }

          const reservation = await callService(`${INVENTORY_URL}/reserve`, {
            productId,
            quantity,
          });

          const payment = await callService(`${PAYMENTS_URL}/charge`, {
            amount,
          });

          respond(res, 201, {
            orderId: crypto.randomUUID(),
            status: "completed",
            reservation,
            payment,
          });
        } catch (error) {
          console.error("Order processing failed:", error.message);

          const status =
            error.status >= 400 && error.status < 500 ? error.status : 502;

          respond(res, status, {
            error: error.message,
          });
        }
      });

      return;
    }

    respond(res, 404, { error: "Not found" });
  })
  .listen(PORT, "0.0.0.0", () => {
    console.log(`Orders API listening on ${PORT}`);
  });
