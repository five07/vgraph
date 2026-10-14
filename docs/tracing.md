# Tracing

`vgraph.trace(conn, tracer)` wraps a connection, a driver or not, and calls
`tracer` with each statement: its kind (select, insert, update, delete, raw,
begin, commit, …), its table, how long it took, and whether it failed, plus the
SQL vgraph writes itself, with its placeholders.

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
