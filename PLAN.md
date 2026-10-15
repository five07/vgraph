# OpenTelemetry in vgraph

vgraph records spans through `five07.otel`, the API only. The app builds the
provider (SDK, exporters, sampler) and hands it to vgraph. Without one, nothing
is recorded and the generated code runs as it does today.

## Decided

- **One context.** `graphql.Context`, the empty interface, is replaced by vlib's
  `context.Context`, which otel uses. The app's own values (its viewer, its
  request) ride in it with `context.with_value`; the trace rides in it with
  `otel.context_with_span`. `Client.with_ctx(ctx context.Context)` sets it, and
  hooks, privacy rules, interceptors and resolvers all take it. The default is
  `context.background()`. 0.1.0 has had no downloads, so the break is free now.
- **Levels**, per model: `none`, `ops`, `full`, `default`.
  - `none`: the generated code for that model has no spans. When every model is
    `none`, the generated module doesn't import otel at all.
  - `ops`: one span per public operation: `query <table>` (`all`, `first`,
    `only`, `count`, `exist`…), `create`/`update`/`delete <table>` (and their
    bulk forms), and one per edge batch load, `load <table>.<edge>`.
  - `full`: `ops`, plus spans for the model's hooks, interceptors and privacy
    rules, and one span per GraphQL resolver of the model's type.
  - `default`: generated as `full`; the level that applies is chosen when the
    app runs. A span above that level is skipped.
- **A model declares its level** like `graphql()`:
  ```v
  pub fn (u User) otel() vgraph.Otel {
  	return vgraph.Otel{ level: .ops }
  }
  ```
  A struct, so options can be added later. No method means `.none`, so a
  project without telemetry gets no instrumentation code. A project that wants
  one level everywhere embeds a struct with the method in each model.
- **No generator flag**, and the generator reads no environment: the same
  models always generate the same code.
- **The level never changes what a span may hold**: names, counts, table and
  edge names. Never values, parameters or error messages.
- **The provider goes to `Client.new`** (`tracer_provider`), as an optional
  `?otel.TracerProvider`, so "not passed" differs from "passed the no-op one".
  `Graph.graphql()` uses the client's.
- **Startup notice**: `Graph.graphql()`, given a client with no provider,
  prints one line to stdout, such as `vgraph: GraphQL server has no tracer
  provider; no spans will be recorded (pass tracer_provider to Client.new)`.
  Passing `otel.noop_tracer_provider()` silences it. A test runs a built program
  and checks its stdout for the line, and for its absence with a provider.
- **Several exporters** are the provider's job: one `SpanProcessor` per
  exporter in `TracerProvider.new(processors: [...])`. vgraph takes one
  provider. The docs and the new example show stdout and OTLP/HTTP together.
- **The GraphQL server** takes the request's context in `Server.handle(req,
  ctx)`, as it does today, now a `context.Context`. With a provider, it starts
  a span per operation, `query <OperationName>` or `mutation <OperationName>`
  (the type alone when unnamed), with `graphql.operation.type` and
  `graphql.operation.name`, and runs the resolvers under it. Extracting
  `traceparent` from the HTTP headers is the app's job
  (`five07.otel.propagation`), shown in the example.
- **Resolver spans** (`full` types) are one per field per level, since
  resolvers run in batches: siblings under the operation span, not one per
  object. A field's loads and statements nest under its resolver span.
- **Database statements** are traced whenever `Client.new` has a provider,
  whatever the models' levels: spans timed after they ran, from the events
  `vgraph.trace` already reports, named like `SELECT users`, with
  `db.system.name`, `db.collection.name`, `db.operation.name`, and
  `db.query.text` only for the SQL vgraph writes itself (placeholders, no
  parameters). `with_ctx` re-wraps the traced connection, so statements nest
  under the caller's span. `trace_statements: false` turns them off.
- **The V compiler bug** (`otel/regressions/run_cross_module_interface`: plain
  `v run` miscompiles vgraph calling `otel.TracerProvider` on the SDK's
  provider) is documented in the README, the tracing guide and the example's
  README (`v -nocache run .`); no workaround in vgraph.
- **The dependency**: `five07.otel` in `v.mod`; `examples/setup.vsh` says where
  it must be linked from, like it does for vgraph; CI checks out otel at a
  pinned develop commit. **vgraph doesn't release this until otel is at
  0.1.0**, and then depends on that release.
- **Metrics and events** come in a later plan, once otel ships them. Providers
  stay separate options (`meter_provider`, later `logger_provider`, beside
  `tracer_provider`); `vgraph.Otel` gains its own metrics switch rather than
  tying metrics to the levels; the startup notice names each missing provider.
- **New example `examples/service-otel`**: a copy of `service` with:
  - mixed levels: users `full`, articles `ops`, posts `default`, comments
    `none`;
  - one provider with two processors, stdout (simple) and OTLP/HTTP (batch),
    chosen by `OTEL_TRACES_EXPORTER`, and the startup notice when neither is on;
  - `traceparent` extracted from incoming requests;
  - a `docker-compose.yml` with a collector and Jaeger, like otel's
    `http_service`;
  - `main_test.v` reading spans back with `InMemoryExporter` and checking the
    tree of one request: operation, resolvers of the `full` type, loads,
    statements, and the `default` model at two levels.

- **A `default` model's level**, when the app runs, is the first that is set:
  `Client.new(..., otel_level: .ops)`; `VGRAPH_OTEL_LEVEL` in the environment
  (`none`, `ops`, `full`; an unknown value is a warning on stderr and is
  ignored); `.ops`. vgraph reads the process environment only, never a `.env`
  file. Explicit levels in models are fixed.
- **`service-otel` chooses its exporters** by `OTEL_TRACES_EXPORTER`, the
  specification's list (`otlp`, `console`, `none`), which it reads itself and
  builds one processor per entry; unset means none, which shows the startup
  notice. An issue on otel proposes reading it there (`exporters_from_env()`),
  and the example switches to it when it lands.
- **`vgraph.TraceEvent` carries `ctx`**, the client's context; the event still
  carries no values.

## Phases

0. **One context**: `context.Context` in place of `graphql.Context` throughout:
   client, hooks, privacy, interceptors, the GraphQL executor and server, the
   generator, regenerated examples (`auth` shows reading a viewer back), docs.
   It doesn't depend on otel. `TraceEvent.ctx`.
   **Done.**
   - `graphql.Context` is gone; resolvers, `Transaction`, `execute` and
     `handle` take `context.Context`. Hooks, interceptors, privacy rules,
     `Client.ctx` (default `context.background()`) and the generated `Graph`,
     mutations, server and resolver stubs use it. `NoContext` and `TxContext`
     are gone.
   - A GraphQL request's transaction rides in the context as a value under a
     private key (`GraphqlTransaction.begin`); `with_ctx` finds it and joins
     it. Unlike before, the context hooks get still carries the transaction,
     so a hook that calls `g.with_ctx(ctx)` (service's `check_parent`) now
     reads inside the request's transaction rather than beside it.
   - `with_ctx` re-wraps a traced connection with the context, so each
     `TraceEvent.ctx` is the client's, in transactions too (new test
     `test_trace_events_carry_the_context`). Phase 1's statement spans parent
     on it.
   - Apps put their values in with `context.with_value` and read them back
     with `ctx.value(key)` and `is`: `auth` (`auth.with_viewer` and
     `viewer_of`, with a private address key), `relations`
     (`models.as_admin`, `is_admin`), the docs' `Viewer` snippet, and the
     `vgraph gen` end-to-end project.
   - Resolver stubs import `context` and `five07.vgraph.graphql`; an existing
     `resolvers.v` gets whichever import it lacks.
   - All examples and `docs/snippets` regenerated; schemas unchanged. `v test`:
     27 passed, 3 skipped (PostgreSQL); the PostgreSQL tests pass on a local
     server. `v fmt -verify`, `v vet` and `v doc` clean.
1. **Core**: the dependency, `vgraph.Otel` and `OtelLevel`, the provider and
   `otel_level` on `Client`, statement spans, tests with
   `InMemoryExporter`.
   **Done.**
   - `otel.v`: `OtelLevel` (`none`, `ops`, `full`, `default`), `Otel`,
     `ClientOptions` (`tracer_provider ?otel.TracerProvider`, `otel_level
     ?OtelLevel`, `trace_statements = true`), `vgraph.version`, and
     `Client.records(level, wanted)`, which the generated code will ask.
   - `Client.new(conn, schema, opts)`; the generated `Graph.new(conn, opts)`
     passes them on. The client keeps `tracer` (a no-op one without a
     provider), `has_tracer_provider` and the resolved `otel_level`.
     `otel_level: .default` is an error.
   - Statement spans: with a provider, `Client.new` wraps the connection in
     `vgraph.trace` with a tracer that makes each event a client span, started
     and ended when the statement ran (`TraceEvent.started`, new), under the
     span of the client's context. Names `SELECT books`, `INSERT books`,
     `BEGIN`…; the table and operation of vgraph's own SQL are read from its
     quoted names; an app's raw SQL is neither read nor recorded.
     `db.query.text` only for vgraph's own SQL; failures are `error` with no
     description.
   - `db.system.name` only for vgraph's drivers, from their dialect: V gives an
     ORM connection's type only as `DB`, and matching the types would link
     every database's C library into vgraph.
   - Re-wrapping with a context reaches a traced connection inside another, so
     the app's own `vgraph.trace` under vgraph's spans gets the context too.
   - The dependency: `five07.otel` in `v.mod`; CI clones it at `OTEL_COMMIT`
     (develop, `5342f59`) in both jobs that build; `examples/setup.vsh` links a
     sibling `otel` checkout or says where to get it; install notes in the
     README and getting started.
   - `otel_test.v`: 8 tests. Full suite 28 passed, 3 skipped; the PostgreSQL
     tests pass on a local server. `v fmt -verify`, `v vet` (with `otel.v`) and
     `v doc` clean.
   - otel's `semconv` has no `db.*` names, so vgraph defines its own; they
     could move to otel.
2. **Loader and schema**: read each model's `otel()` into `Table`;
   `vgraph describe` prints the level.
3. **Generator**: `ops` and `full` spans in the generated client, `default`
   generated as `full` with its runtime check; no otel import when every model
   is `none`; gen tests for each level.
4. **GraphQL server**: the operation span, resolver spans of `full` and
   `default` types, the startup notice and its test.
5. **Example `service-otel`**, a copy of `service` with instrumentation.
6. **Docs**: `docs/tracing.md` (otel and the raw `vgraph.trace` hook), the
   README, getting started, the compiler bug, and the context change in the
   upgrade notes.
