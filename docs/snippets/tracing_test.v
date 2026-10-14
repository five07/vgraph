module main

import five07.vgraph
import five07.vgraph.sqlite as vsqlite
import db.sqlite
import v.migrations
import graph

fn test_tracing() {
	mut db := sqlite.connect(':memory:')!
	mut m := migrations.new(mut db, [initial], dialect: .sqlite)!
	m.migrate()!
	mut seen := []string{}
	ptr := &seen
	// snippet: trace
	g := graph.Graph.new(vgraph.trace(vsqlite.new(db), fn [ptr] (e vgraph.TraceEvent) {
		// the kind, table, duration and failure of each statement; never values
		mut out := unsafe { ptr }
		out << '${e.kind} ${e.table}'
	}))!
	g.articles().with_author().all()!
	// end snippet
	assert seen == ['select articles']
}
