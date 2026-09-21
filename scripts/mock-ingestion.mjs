import { createServer } from "node:http";
import { appendFileSync } from "node:fs";

const outputFile = process.env.DEBUGBUNDLE_SMOKE_EVENTS_FILE;
const port = Number.parseInt(process.env.DEBUGBUNDLE_SMOKE_PORT ?? "18082", 10);
const expectedService = process.env.DEBUGBUNDLE_SMOKE_SERVICE ?? "swift-spm-smoke";

if (!outputFile) {
  throw new Error("DEBUGBUNDLE_SMOKE_EVENTS_FILE is required");
}

const server = createServer((request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    response.writeHead(200).end("ok");
    return;
  }

  if (request.method !== "POST" || request.url !== "/v1/events") {
    response.writeHead(404).end();
    return;
  }

  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    try {
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      const events = body.events;
      if (!Array.isArray(events) || events.length !== 2) {
        throw new Error("expected exactly two events");
      }
      if (request.headers.authorization !== "Bearer dbundle_proj_swift_smoke") {
        throw new Error("missing staged consumer bearer token");
      }

      const types = new Set(events.map((event) => event.event_type));
      if (!types.has("frontend_exception") || !types.has("request_event")) {
        throw new Error("expected frontend_exception and request_event");
      }
      for (const event of events) {
        if (
          event.schema_version !== "2026-03-01" ||
          typeof event.event_id !== "string" ||
          event.sdk_name !== "@debugbundle/sdk-swift" ||
          event.sdk_version !== "2.0.0" ||
          event.service?.name !== expectedService ||
          event.service?.environment !== "smoke" ||
          event.correlation?.trace_id !== "11111111111111111111111111111111"
        ) {
          throw new Error("event identity, schema, service, or correlation is invalid");
        }
      }

      appendFileSync(outputFile, `${JSON.stringify({ authorization: request.headers.authorization, body })}\n`);
      const acknowledgement = JSON.stringify({
        accepted: events.length,
        rejected: 0,
        errors: []
      });
      response.writeHead(202, { "Content-Type": "application/json" }).end(acknowledgement);
    } catch (error) {
      response
        .writeHead(400, { "Content-Type": "application/json" })
        .end(JSON.stringify({ error: error instanceof Error ? error.message : "invalid request" }));
    }
  });
});

server.listen(port, "127.0.0.1");
