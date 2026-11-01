import { createServer } from "node:http";
import { appendFileSync } from "node:fs";

const outputFile = process.env.DEBUGBUNDLE_SMOKE_EVENTS_FILE;
const port = Number.parseInt(process.env.DEBUGBUNDLE_SMOKE_PORT ?? "18082", 10);
const expectedService = process.env.DEBUGBUNDLE_SMOKE_SERVICE ?? "swift-spm-smoke";

if (!outputFile) {
  throw new Error("DEBUGBUNDLE_SMOKE_EVENTS_FILE is required");
}

const capabilities = { version: 1, features: ["exception_evidence_v1", "resource_observations_v1", "recovery_v1", "evidence_provenance_v1"] };
const server = createServer((request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    response.writeHead(200).end("ok");
    return;
  }

  if (request.method === "GET" && request.url === "/v1/sdk/config" && request.headers["x-debugbundle-evidence"] === "1") {
    response.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({
      probes_enabled: true, remote_probes_enabled: false, active_probes: [], poll_interval_ms: 0,
      evidence_capabilities: capabilities, capture_policy: {
        preset: "balanced", capture_logs: "warning", capture_request_events: "failures_only",
        capture_breadcrumbs: "exception_only", capture_probe_events: "buffer_only",
        capture_diagnostic_context: true, immediate_client_error_statuses: [], immediate_client_error_path_rules: []
      }
    }));
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
      if (!Array.isArray(events) || events.length !== 3) {
        throw new Error("expected exactly three events");
      }
      if (request.headers.authorization !== "Bearer dbundle_proj_swift_smoke") {
        throw new Error("missing staged consumer bearer token");
      }

      const types = new Set(events.map((event) => event.event_type));
      if (!types.has("frontend_exception") || !types.has("request_event") || !types.has("diagnostic_context")) {
        throw new Error("expected failure, request and explicit recovery");
      }
      for (const event of events) {
        if (
          event.schema_version !== "2026-03-01" ||
          typeof event.event_id !== "string" ||
          event.sdk_name !== "@debugbundle/sdk-swift" ||
          event.sdk_version !== "3.1.0" ||
          event.service?.name !== expectedService ||
          event.service?.environment !== "smoke" ||
          event.correlation?.trace_id !== "11111111111111111111111111111111"
        ) {
          throw new Error("event identity, schema, service, or correlation is invalid");
        }
      }

      const failure = events.find((event) => event.event_type === "frontend_exception");
      const recovery = events.find((event) => event.event_type === "diagnostic_context");
      const graph = failure.payload.exception_evidence;
      if (graph?.nodes?.length !== 2 || graph.nodes[0].relationships?.[0]?.kind !== "cause" ||
          recovery.payload.state !== "attempt_completed" || recovery.payload.status_code !== 200 ||
          failure.context?.evidence_reference?.failure_ref !== recovery.payload.failure_ref ||
          failure.context?.evidence_reference?.scope?.operation_id !== recovery.payload.scope?.operation_id ||
          JSON.stringify(body).includes("smoke-private-token")) {
        throw new Error(`installed evidence mismatch: graph nodes=${graph?.nodes?.length}, relationship=${graph?.nodes?.[0]?.relationships?.[0]?.kind}, recovery=${recovery.payload.state}, reference=${failure.context?.evidence_reference?.failure_ref === recovery.payload.failure_ref}`);
      }
      appendFileSync(outputFile, `${JSON.stringify({ authorization: request.headers.authorization, body })}\n`);
      const acknowledgement = JSON.stringify({
        accepted: events.length,
        rejected: 0,
        errors: [],
        evidence_capabilities: capabilities
      });
      response.writeHead(202, { "Content-Type": "application/json" }).end(acknowledgement);
    } catch (error) {
      console.error("Swift installed artifact rejected:", error instanceof Error ? error.message : "invalid request");
      response
        .writeHead(400, { "Content-Type": "application/json" })
        .end(JSON.stringify({ error: error instanceof Error ? error.message : "invalid request" }));
    }
  });
});

server.listen(port, "127.0.0.1");
