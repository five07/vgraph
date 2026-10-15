# Changelog

## 0.2.0

### Breaking: one context

`graphql.Context`, the empty interface the app's value rode in, is gone. vgraph
uses V's `context.Context` everywhere: `with_ctx`, hooks, interceptors, privacy
rules, the GraphQL resolvers and `Transaction`, and `execute` and `handle`. The
app's own values ride in it, and so does the trace.

To upgrade an app:

- Put its value in a context instead of passing it as one, with a key of its
  own, and read it back with `ctx.value`:

  ```v
  const viewer_key_cell = u8(1)

  fn with_viewer(ctx context.Context, v Viewer) context.Context {
  	return context.with_value(ctx, voidptr(&viewer_key_cell), v)
  }

  fn viewer_of(ctx context.Context) Viewer {
  	if value := ctx.value(voidptr(&viewer_key_cell)) {
  		if value is Viewer {
  			return value
  		}
  	}
  	return Viewer{}
  }
  ```

  `g.with_ctx(Viewer{...})` becomes `g.with_ctx(with_viewer(ctx, Viewer{...}))`,
  and `ctx is Viewer` in a rule becomes `viewer_of(ctx)`.
- Change `graphql.Context` to `context.Context` in hooks, rules, interceptors
  and the methods of `Resolvers` (`graph/resolvers.v`), and import `context`.
- Pass `context.background()`, not `unsafe { nil }`, to `execute` and `handle`
  when there is no request context.
- Run `vgraph gen` again.

`vgraph.NoContext` and `vgraph.TxContext` are gone: a GraphQL request's
transaction rides in its context, and a hook that calls `g.with_ctx(ctx)` now
reads inside that transaction.

### Added

- OpenTelemetry tracing through `five07.otel`, which vgraph now depends on
  ([Tracing](docs/tracing.md)): `Graph.new(conn, tracer_provider: ...)`, a
  span per GraphQL operation and per statement, and a level per model
  (`otel()`: `none`, `ops`, `full`, `default`) for the spans of its queries,
  writes, edge loads, hooks, interceptors, privacy rules and resolvers.
  `VGRAPH_OTEL_LEVEL` sets the level of `default` models.
- A GraphQL server built without a tracer provider says so on stdout when it
  starts; the no-op provider silences it.
- `TraceEvent.ctx`, the context of the client that ran a statement, and
  `TraceEvent.started`.
- `vgraph describe` prints each table's level.
- The [`service-otel`](examples/service-otel) example.

### Changed

- `v test` of the whole repository needs `-nocache` (`v -nocache test .`): with
  otel linked, V master's module cache builds a test that hangs.

## 0.1.0

The first release.
