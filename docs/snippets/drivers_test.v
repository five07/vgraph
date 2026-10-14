module main

import db.sqlite
import five07.vgraph
import five07.vgraph.sqlite as vsqlite
import graph

fn test_drivers() {
	// snippet: drivers
	db := sqlite.connect(':memory:')!
	// on vgraph's driver: everything
	with_driver := graph.Graph.new(vsqlite.new(db))!
	// on the ORM's connection alone: reads and simple writes, without what
	// needs vgraph's SQL (upserts, i64 keys read back, several orders)
	plain := graph.Graph.new(db)!
	// end snippet
	assert with_driver.client.conn is vgraph.Driver
	assert plain.client.conn !is vgraph.Driver
}
