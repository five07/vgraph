# Tracing

vgraph records [OpenTelemetry](https://opentelemetry.io) spans through
[`five07.otel`](https://github.com/five07/otel): one for each GraphQL operation,
for the queries, writes and edge loads of the models that ask for them, and for
each database statement. It uses otel's API alone; the app chooses the SDK, the
exporters and the sampler, and hands vgraph a tracer provider. Without one,
vgraph records nothing, and costs next to nothing.

For a lighter look, `vgraph.trace` reports each statement to a function of the
app's, with no OpenTelemetry at all ([Statements](#statements)).

## Turning it on

Build a tracer provider at startup and give it to the client. Each exporter is
a processor of the provider, so spans can go to several places at once: here to
stdout as each one ends, and in batches to a collector over OTLP/HTTP.

<!-- snippet: docs/snippets/tracing_test.v#provider -->
```v
// once, at startup: each span goes to stdout as it ends, and in batches to
// the collector at OTEL_EXPORTER_OTLP_ENDPOINT (default localhost:4318)
provider := trace.TracerProvider.new(
	processors: [
		trace.SimpleSpanProcessor.new(stdout.Exporter.new()),
		trace.BatchSpanProcessor.new(otlphttp.Exporter.new()!),
	]
)!
defer {
	provider.shutdown() or { eprintln(err) }
}
g := graph.Graph.new(vsqlite.new(db), tracer_provider: otel.TracerProvider(provider))!
```

`OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_SAMPLER` and
otel's other variables configure the provider; see otel's
[configuration](https://github.com/five07/otel/blob/main/docs/configuration.md).
The [`service-otel`](../examples/service-otel) example picks its exporters from
`OTEL_TRACES_EXPORTER` (`otlp`, `console`, both, or `none`), and has a collector
and Jaeger in a `docker-compose.yml`.

`Client.new(conn, schema, opts)` takes the same options as `Graph.new`:

| Option | Default | Meaning |
|--------|---------|---------|
| `tracer_provider` | none | Records the client's spans. Without one, nothing is recorded. |
| `otel_level` | `VGRAPH_OTEL_LEVEL`, else `ops` | The level of the models whose level is `default`. |
| `trace_statements` | `true` | A span per database statement, when there is a provider. |

## What each model records

A model chooses how much its code records with an `otel()` method
([Schema](schema.md)); without one, it records nothing of its own. The level is
part of the generated code: a model of level `none` gets the same code as one
of a project without tracing, and the others get a span around each of their
operations.

| Level | Spans |
|-------|-------|
| `none` | none of its own; its statements still have theirs |
| `ops` | its queries, writes and edge loads |
| `full` | `ops`, and its hooks, interceptors, privacy rules and GraphQL resolvers |
| `default` | `full`'s code; the client's `otel_level` decides, when the app starts |

A `default` model lets each deployment choose: `VGRAPH_OTEL_LEVEL=full` for
detail while looking into something, `none` to turn it off, without
regenerating or rebuilding. A model's own `none`, `ops` or `full` is fixed.

## The spans

| Span | Kind | When | Attributes |
|------|------|------|------------|
| `query Feed`, `mutation Join` | server | each GraphQL operation; `query` alone when unnamed, `GraphQL Operation` when it can't be parsed | `graphql.operation.type`, `graphql.operation.name` |
| `resolve User.articles` | internal | a resolver of a `full` type, once per field per level: resolvers run in batches | `vgraph.field`, `vgraph.batch_size` (the parents) |
| `query users` | internal | `all`, `count`, `ids`, `scan`, the aggregates and `group_by`; `first`, `only`, `exist` and the rest run through them | `db.collection.name`, `vgraph.operation`, `vgraph.rows` |
| `load users.articles` | internal | the load of an edge, for every row at its level | `db.collection.name`, `vgraph.edge`, `vgraph.batch_size` |
| `create users`, `update users`, `delete users` | internal | a write's `save` or `exec`, its bulk forms too | `db.collection.name`, `vgraph.operation`, `vgraph.rows` (when it returns rows or a count) |
| `hook users`, `privacy users`, `intercept users` | internal | each hook that applies to a write, a write's or a query's privacy rules, each interceptor, of a `full` model | `vgraph.hook`, `vgraph.decision`, `vgraph.interceptor` |
| `SELECT users`, `INSERT users`, `BEGIN` | client | each statement | `db.system.name` (on vgraph's drivers), `db.collection.name`, `db.operation.name`, `db.query.text` (the SQL vgraph writes) |

Spans nest as the work does: a resolver's queries are its children, a query's
edge loads and statements are the query's, and a write's hooks are the write's.
Hooks nest the way they run: each covers the hooks inside it and the write,
whose statements are the innermost hook's.

A failed operation's span is an error, with the error's type and not its
message, which can quote values. No span holds a value: no parameter, no field
of a row, no part of a request. `db.query.text` is only the SQL vgraph writes
itself, with its placeholders; an app's raw SQL isn't recorded.

## Context

vgraph's spans are children of the span in the client's context, the
`context.Context` that `with_ctx` gives it, which carries the app's own values
too ([Hooks, interceptors and privacy](hooks-and-privacy.md)):

<!-- snippet: docs/snippets/tracing_test.v#context -->
```v
// the app's span, such as its request's: vgraph's spans are its children
ctx, span := tracer.start(context.background(), 'GET /comments')
comments := g.with_ctx(ctx).comments().all()!
span.end()
```

The GraphQL server passes the request's context, the second argument of
`execute` and `handle`, to every resolver. A service that continues its
callers' traces reads the context from the request's headers:

<!-- snippet: docs/snippets/tracing_test.v#propagation -->
```v
// the caller's trace, from the request's W3C `traceparent` and `tracestate`
parent := propagation.default_propagator().extract(context.background(),
	propagation.GetterCarrier{
		get_fn: fn [headers] (key string) ?string {
			return headers[key] or { return none }
		}
	})
```

and hands it to `handle`; the operation's span is then a child of the caller's,
in the caller's trace.

## GraphQL

`Graph.graphql()` gives the server the client's tracer, so each operation is a
span whose children are the request's resolvers, queries and statements; a
mutation's transaction is in it too. A server built on a client without a
tracer provider says so when it starts, on stdout:

```
vgraph: GraphQL server has no tracer provider; no spans will be recorded (pass tracer_provider to Client.new)
```

To run without spans and without the line, pass `otel.noop_tracer_provider()`.

## Statements

`vgraph.trace(conn, tracer)` wraps a connection, a driver or not, and calls
`tracer` with each statement: its kind (select, insert, update, delete, raw,
begin, commit, …), its table, when it started and how long it took, and whether
it failed, plus the SQL vgraph writes itself, with its placeholders.

<!-- snippet: docs/snippets/tracing_test.v#trace -->
```v
g := graph.Graph.new(vgraph.trace(vsqlite.new(db), fn [ptr] (e vgraph.TraceEvent) {
	// the kind, table, duration and failure of each statement; never values
	mut out := unsafe { ptr }
	out << '${e.kind} ${e.table}'
}))!
g.articles().with_author().all()!
```

Events carry no values: no parameters, and no error messages, which can quote
them. The tests of the examples count statements this way, to check that a
request runs the same ones however many rows it reads.

Each event also carries `ctx`, the context of the client that ran the statement
(`g.with_ctx(ctx)`, or the request's, through the GraphQL server), so a tracer
can tell which request a statement belongs to, by the values the app put in it.
This is how vgraph's own statement spans work, and an app's `vgraph.trace` under
a client with a provider gets the same context.

## Testing

otel's in-memory exporter keeps the spans for a test to read:

<!-- snippet: docs/snippets/tracing_test.v#testing -->
```v
exporter := trace.InMemoryExporter.new()
provider := trace.TracerProvider.new(processors: [trace.SimpleSpanProcessor.new(exporter)])!
g := graph.Graph.new(vsqlite.new(db), vgraph.ClientOptions{
	...opts
	tracer_provider: otel.TracerProvider(provider)
})!
// … run the code, then read `exporter.spans()`
```

## Building

Two V master issues touch a program that links otel's SDK:

- `v run .`'s default build can miscompile calls between modules, which
  vgraph's calls into the SDK's provider are: wrong values, or a crash. Use
  `v -nocache run .`, or build first (`v .`); otel's
  `regressions/run_cross_module_interface` has the program.
- A whole-folder `v test` built through V's module cache can hang in the SDK.
  Run `v -nocache test .`; a single file's `v test` is fine.
