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
   **Done.**
   - `Schema.add` reads `otel()` by reflection, like `graphql()`, into
     `Table.otel` (level `none` without it); `vgraph.Instrumented` is the
     interface such a model implements, for the docs.
   - The loader's JSON carries the level by name; `gen.Table.otel` mirrors it
     (`gen.Otel.level`, a string).
   - `vgraph describe` ends each table's summary line with `otel: <level>`.
   - `relations`' `Group` is `full` and the docs' `Comment` is `ops`, so the
     describe test and the schema guide (a new `otel()` paragraph, from a
     snippet) show one. No generated code changes yet.
   - `test_otel_level_is_reflected` in `schema_test.v`; the describe test
     checks `full` and `none`. Full suite 28 passed, 3 skipped.
3. **Generator**: `ops` and `full` spans in the generated client, `default`
   generated as `full` with its runtime check; no otel import when every model
   is `none`; gen tests for each level.
   **Done.**
   - `gen/otel.v`: after a table's files are generated, a model whose level
     isn't `none` has each operation's method split into `<name>_untraced`
     (the body as it was) and a wrapper of the same name and doc comment,
     which starts the span (`Client.start_span`, `start_load_span`), runs the
     body with a client whose context holds it, records a failure
     (`vgraph.span_failed`: the error's type, no message) or the rows
     (`vgraph.span_rows`), and ends it. A `none` model's code is unchanged.
   - Operations: `all`, `count`, `ids`, `scan`, the aggregates and the
     group-by's `all` (`query <table>`); each `load_<edge>`
     (`load <table>.<edge>`, with `vgraph.batch_size`); the `save` and `exec`
     of create, create bulk, update one, update, delete one and delete
     (`create`/`update`/`delete <table>`). `first`, `only`, `exist` and the
     rest go through these, and a `save` runs its `exec` inside its own span.
     Attributes: `db.collection.name`, `vgraph.operation`, `vgraph.rows`.
   - The generated code calls vgraph's helpers, so it never imports otel; a
     traced table file imports `five07.vgraph`. The level is a literal in each
     wrapper (`.ops`, `.full`, `.default`), and `Client.records` decides.
   - Hooks, interceptors and privacy rules run in the core, so their `full`
     spans are there, gated by the table's level (`Client.full_spans`):
     `hook <table>` per hook that applies, `privacy <table>` for a write's
     rules (the privacy hook) and for a query's (with `vgraph.decision`), and
     `intercept <table>` per interceptor (`vgraph.interceptor`, its name).
     Hook spans nest, as hooks do: each covers the hooks inside it and the
     write, whose statements are the innermost span's. Rules, interceptors
     and hooks get the span's context, so their own queries nest under it.
   - `full` and `ops` generate the same code but for the level; `full`'s
     generated extra is the GraphQL resolver spans of Phase 4.
   - Tests: the `vgraph gen` end-to-end project has one model per level
     (`full` articles, `ops` users, `default` tags, comments without) and
     checks the span tree, `otel_level: .none` on a `default` model, write and
     hook spans, and a failure; `gen_test.v` tests the signature parser and
     `instrument` by level; `otel_test.v` tests privacy and interceptor spans.
     Full suite 28 passed, 3 skipped; PostgreSQL tests pass locally.
4. **GraphQL server**: the operation span, resolver spans of `full` and
   `default` types, the startup notice and its test.
   **Done.**
   - `graphql.Server.tracer ?otel.Tracer`: with one, each operation is a
     server span, `query Name` / `mutation Name` (the type alone when
     unnamed), with `graphql.operation.type` and `.name`; the transaction and
     resolvers run under it; any error makes it `error`. A request that can't
     be parsed or validated is a failed `GraphQL Operation` span.
   - The generated `Graph.graphql()` sets the tracer from the client
     (`Client.graphql_tracer()`) and prints `Client.tracing_notice()` when the
     client has no provider; the no-op provider silences it.
   - Resolver spans: `Client.traced_resolver(level, type, field, r)` wraps a
     resolver in `resolve Type.field` (`vgraph.field`, `vgraph.batch_size`:
     the parents at its level), whose context reaches the resolver, so its
     queries nest. The generator wraps the function-literal resolvers of
     `full` and `default` types (root fields, edges, mutations, and the
     project's own fields on those types); columns, which only read the row
     they're given, have no span. `traced_resolver` returns the resolver as
     it is when the client wouldn't record it, so a `default` type on an
     `ops` client costs nothing per call.
   - Tests: `test_operations_are_spans` (graphql), `test_resolver_spans` and
     a built program that prints the notice without a provider and not with
     the no-op one (the `vgraph gen` end-to-end test), `test_trace_resolvers`
     (gen), `test_tracing_notice` (core).
   - V bug, for otel's notes: comparing a `?otel.Tracer` with `none` in a
     program that links otel's SDK makes V emit C that copies otel's `shared`
     structs wrongly (`initializing ... with an expression of incompatible
     type '__shared__...'`). The tests use `if x := ...` instead.
5. **Example `service-otel`**, a copy of `service` with instrumentation.
   **Done.**
   - `examples/service-otel`: `service`'s app, models, migrations and seed,
     with users `full`, articles `ops`, posts `default`, comments without
     `otel()`; its own `graph/` and schema (the same API).
   - `telemetry.v`: one processor per `OTEL_TRACES_EXPORTER` entry, `otlp`
     (batch, `otlphttp`) and `console` (simple, `stdout`); none means no
     provider, and the startup notice. `main.v` shuts the provider down on
     ctrl-c, so queued spans go out.
   - `app/config.v`: `OTEL_TRACES_EXPORTER` parsed and checked; the `.env`
     file's `OTEL_*` and `VGRAPH_OTEL_LEVEL` go into the environment unless
     already set, for otel and vgraph to read.
   - `app.v`: each request's context from its headers (W3C `traceparent`,
     `tracestate`, `baggage`), passed to `handle`, so the operation's span is
     the caller's child.
   - `main_test.v` (4 tests, over HTTP, in-memory exporter): the caller's
     trace is continued, and a request without one starts its own; each
     model's level (users' resolver, query, interceptor and statement spans;
     articles' load; comments' statement only); posts at `ops`, `full` and
     `none`; a mutation's transaction, write, hook and statement, and no value
     of the request in any attribute. `service`'s tests cover the API, so the
     copy has none of them.
   - `docker-compose.yml` and `collector.yaml` from otel's `http_service`;
     `.env.example` and a README with the span tree of a request.
   - CI generates and checks `service-otel`'s client and schema; the root
     README lists the example.
   - Found here: with otel linked, a whole-folder `v test vgraph` builds
     `otel_test` through V's module cache into a binary that deadlocks every
     time in `SimpleSpanProcessor.on_end` (its lock held by nothing), while a
     single-file `v test` builds one that never does. otel's README already
     says its own whole-repository runs need `-nocache`. CI and the README now
     run `v -nocache test vgraph` (and the PostgreSQL tests).
   - `v -nocache test vgraph`: 31 passed, 3 skipped (PostgreSQL); `v fmt
     -verify` and `v vet` clean.
6. **Docs**: `docs/tracing.md` (otel and the raw `vgraph.trace` hook), the
   README, getting started, the compiler bug, and the context change in the
   upgrade notes.
