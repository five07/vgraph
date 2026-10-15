# service-otel

The [`service`](../service) example, traced with OpenTelemetry through
[`five07.otel`](https://github.com/five07/otel). The API, the models and the
data are the same; this one records a span for each GraphQL operation, the
spans of each model's telemetry level under it, and one for each database
statement, and sends them to a collector, to stdout, or both.

Built and tested with V master, like vgraph (see the root README). It imports
vgraph as `five07.vgraph` and otel as `five07.otel`, so run `v run ../setup.vsh`
once per checkout first.

## Running

```sh
docker compose up -d                       # a collector on :4318, Jaeger on :16686
OTEL_TRACES_EXPORTER=otlp,console v -nocache run .
curl -H 'content-type: application/json' \
  -H 'traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \
  -d '{"query":"query Feed { users(first: 1) { edges { node { name articles(first: 2) { edges { node { title } } } } } } }"}' \
  http://localhost:8080/graphql            # continues trace 0af76519…
v -nocache test .                          # the tracing tests, over HTTP
v run ../../cmd/vgraph gen .               # regenerate graph/ after changing a model
```

Then open <http://localhost:16686>, pick the service `service_otel`, and find
the traces; `docker compose logs collector` prints each span as it arrives, and
with `console` the service prints them too, one JSON line each. Ctrl-c sends the
spans still queued and stops the service; `docker compose down` the rest.

`-nocache`: V master's default `v run` build can miscompile calls between
modules, which vgraph's calls into otel's SDK are (otel's
`regressions/run_cross_module_interface`); `v -nocache run .` and a plain `v .`
build are fine, as is `v test`.

Without exporters (`OTEL_TRACES_EXPORTER` unset or `none`), the service runs as
`service` does and records nothing, and its GraphQL server says so when it
starts:

```
vgraph: GraphQL server has no tracer provider; no spans will be recorded (pass tracer_provider to Client.new)
```

## What is traced

Each model chooses how much its code records, in its `otel()` method:

| Model | Level | Spans |
|-------|-------|-------|
| users | `full` | its queries, writes and edge loads; its hooks, interceptors and privacy rules; its GraphQL resolvers |
| articles | `ops` | its queries, writes and edge loads |
| posts | `default` | what the app chooses when it starts: `VGRAPH_OTEL_LEVEL`, `ops` when unset |
| comments | none | nothing of its own (no `otel()` method) |

Whatever the levels, each GraphQL operation is a span (`query Feed`,
`mutation Join`) and each statement one (`SELECT users`, `INSERT users`,
`BEGIN`), so a comment's statements still show, under the span of whatever ran
them. The `Feed` request above makes this tree:

```
query Feed
  resolve Query.users          users are full: their resolvers
    query users
      intercept users          the soft delete's interceptor
      SELECT users
  resolve User.articles
    load users.articles        articles are ops: their load, not their resolvers
      SELECT articles
```

Spans hold names, counts, and the SQL vgraph writes, with its placeholders: never
a value of the request, a parameter or an error's message. A request that
carries a W3C `traceparent` continues the caller's trace: `query Feed` is the
child of the caller's span.

## Settings

The settings of [`service`](../service#running), and these, from `.env` or the
environment (copy `.env.example`):

| Key | Default | Meaning |
|-----|---------|---------|
| `OTEL_TRACES_EXPORTER` | `none` | `otlp`, `console`, both (`otlp,console`), or `none`. |
| `OTEL_SERVICE_NAME` | `unknown_service:` and the program's name | The service's name in the traces. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | The collector. |
| `VGRAPH_OTEL_LEVEL` | `ops` | The level of posts, whose model leaves it to the app: `none`, `ops` or `full`. |

Every other `OTEL_*` variable otel reads works too, such as the sampler's
(`OTEL_TRACES_SAMPLER`). The `.env` file's `OTEL_*` and `VGRAPH_OTEL_LEVEL` go
into the environment at startup, where otel and vgraph read them, unless the
environment has them already.

## Layout

The layout of [`service`](../service#layout), and:

```
telemetry.v                the tracer provider: one processor per exporter
main.v                     startup: the provider, the app, ctrl-c
app.v                      the graph on the provider; each request's trace from
                           its headers
main_test.v                the tests, over HTTP, with the spans kept in memory
docker-compose.yml         the collector and Jaeger
collector.yaml             the collector's settings: OTLP in, print, on to Jaeger
```

The tests start the service on a free port with an in-memory exporter, and check
the spans each request makes; they need no collector. `service`'s own tests
cover the API.
