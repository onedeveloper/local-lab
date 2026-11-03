const http = require("node:http");
const crypto = require("node:crypto");

const PORT = Number(process.env.PORT) || 3000;
const LOG_LEVEL = process.env.LOG_LEVEL || "info";

function respond(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

const server = http.createServer((req, res) => {
    if (LOG_LEVEL === "debug") console.log(`${req.method} ${req.url}`);

  if (req.url === "/health" && req.method === "GET") {
    return respond(res, 200, { status: "healthy" });
  }

  if (req.url === "/reserve" && req.method === "POST") {
    let body = "";

    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      try {
        const { productId, quantity } = JSON.parse(body);

        if (!productId || !Number.isInteger(quantity) || quantity < 1) {
          return respond(res, 400, { error: "Invalid reservation" });
        }

        if (productId === "OUT-OF-STOCK") {
          return respond(res, 409, {
            error: "Insufficient inventory",
          });
        }

        return respond(res, 200, {
          reservationId: crypto.randomUUID(),
          productId,
          quantity,
          status: "reserved",
        });
      } catch {
        return respond(res, 400, { error: "Invalid JSON" });
      }
    });

    return;
  }

  respond(res, 404, { error: "Not found" });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Inventory API listening on ${PORT}`);
});
