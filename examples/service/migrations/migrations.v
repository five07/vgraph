// Package migrations holds the app's database migrations, which `v.migrations`
// runs at startup and records in `schema_migrations`.
module migrations

import db.sqlite
// `vm`: this module's own name is `migrations`.
import v.migrations as vm
import five07.vgraph
import graph
import articles.models as article_models
import comments.models as comment_models
import posts.models as post_models
import users.models as user_models

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

// initial_up creates the four tables from their structs, users first since
// the others refer to it, then the indexes their edges need.
//
// The indexes come from the schema as it is now. When a later migration adds
// edges, it adds their indexes itself, and this one then lists the indexes it
// made, so that it makes the same ones on a new database.
fn initial_up(mut ctx vm.Context) ! {
	vm.create_orm_table[user_models.User](mut ctx)!
	vm.create_orm_table[article_models.Article](mut ctx)!
	vm.create_orm_table[post_models.Post](mut ctx)!
	vm.create_orm_table[comment_models.Comment](mut ctx)!
	vgraph.add_edge_indexes(mut ctx, graph.schema()!)!
}

// initial_down drops the four tables, and their indexes with them.
fn initial_down(mut ctx vm.Context) ! {
	vm.drop_orm_table[comment_models.Comment](mut ctx)!
	vm.drop_orm_table[post_models.Post](mut ctx)!
	vm.drop_orm_table[article_models.Article](mut ctx)!
	vm.drop_orm_table[user_models.User](mut ctx)!
}
