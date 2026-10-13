// Package migrations holds the app's database migrations, which `v.migrations`
// runs at startup and records in `schema_migrations`.
module migrations

import db.sqlite
// `vm`: this module's own name is `migrations`.
import v.migrations as vm
import five07.vgraph
import graph

// all returns the app's migrations, oldest first. They are written by hand. A
// migration that has run on a database is not changed afterwards: a schema
// change is a new migration.
pub fn all() []vm.Migration {
	return [
		vm.Migration{
			version: 1
			name:    'initial'
			up:      initial_up
			down:    initial_down
		},
	]
}

// new returns a migrator that runs `all()` on `db`.
pub fn new(mut db sqlite.DB) !vm.Migrator {
	return vm.new(mut db, all(), dialect: .sqlite)!
}

// initial_up creates the four tables from the schema, users first since the
// others refer to it, with auto-incrementing keys and their foreign keys; then
// the indexes their edges need, and each table's range of global ids, which
// `node(id:)` reads.
//
// The indexes come from the schema as it is now. When a later migration adds
// edges, it adds their indexes itself, and this one then lists the indexes it
// made, so that it makes the same ones on a new database.
fn initial_up(mut ctx vm.Context) ! {
	s := graph.schema()!
	for table in ['users', 'articles', 'posts', 'comments'] {
		vgraph.create_table(mut ctx, s, table)!
	}
	vgraph.add_edge_indexes(mut ctx, s)!
	vgraph.global_ids(mut ctx, s)!
}

// initial_down drops the four tables, their indexes with them, and the ranges
// of their global ids.
fn initial_down(mut ctx vm.Context) ! {
	for table in ['comments', 'posts', 'articles', 'users', 'vgraph_types'] {
		ctx.drop_table(table)!
	}
}
