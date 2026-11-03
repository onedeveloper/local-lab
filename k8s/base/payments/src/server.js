const http = require("node:http");
const crypto = require("node:crypto");

const PORT = Number(process.env.PORT) || 3000;
const LOG_LEVEL = process.env.LOG_LEVEL || "info";

function respond(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

http
  .createServer((req, res) => {
    if (LOG_LEVEL === "debug") console.log(`${req.method} ${req.url}`);

    if (req.url === "/health" && req.method === "GET") {
      return respond(res, 200, { status: "healthy" });
    }

    if (req.url === "/charge" && req.method === "POST") {
      let body = "";

      req.on("data", (chunk) => (body += chunk));
      req.on("end", async () => {
        try {
          const { amount } = JSON.parse(body);

          if (
            typeof amount !== "number" ||
            !Number.isFinite(amount) ||
            amount <= 0
          ) {
            return respond(res, 400, { error: "Invalid amount" });
          }

          if (amount > 1000) {
            return respond(res, 402, {
              error: "Payment declined",
            });
          }

          if (amount === 999) {
            await new Promise((resolve) => setTimeout(resolve, 5000));
          }
          return respond(res, 200, {
            paymentId: crypto.randomUUID(),
            amount,
            status: "approved",
          });
        } catch {
          return respond(res, 400, { error: "Invalid JSON" });
        }
      });

      return;
    }

    respond(res, 404, { error: "Not found" });
  })
  .listen(PORT, "0.0.0.0", () => {
    console.log(`Payments API listening on ${PORT}`);
  });
