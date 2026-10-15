# Getting started

## Install

vgraph needs V master (it is built against commit `04cb7fa`, 2026-10-14), with
SQLite, and PostgreSQL if you use it. That build still reports `V 0.5.2`, so
`v.mod`'s `min_v` says `0.5.2`; the 0.5.2 release itself is too old (it lacks
`v.migrations`), so use master at that commit or later. Until vgraph is on VPM,
install it from GitHub:

```sh
git clone https://github.com/five07/vgraph ~/.vmodules/five07/vgraph
git clone https://github.com/five07/otel ~/.vmodules/five07/otel
```

vgraph records OpenTelemetry spans through `five07.otel` when an app gives it a
tracer provider ([Tracing](tracing.md)), so it imports it either way.

It imports as `five07.vgraph`, with `five07.vgraph.sqlite` and
`five07.vgraph.pg` (drivers), `five07.vgraph.graphql` (the GraphQL server) and
`five07.vgraph.load` (batched loads by column name).

## Declare models

A model is a V struct for V's ORM, with an `edges()` method that declares how it
relates to other tables. Other methods beside it add field options, hooks,
interceptors, privacy rules, indexes and GraphQL options; [Schema](schema.md) has
them all.

<!-- snippet: docs/snippets/models/models.v#user -->
```v
// User writes articles and comments.
@[table: 'users']
pub struct User {
	Stamps
pub:
	id    i64 @[primary; sql: serial]
	name  string
	email string
}

// edges declares a user's articles: the other side of `Article.author`.
pub fn (u User) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'articles'
			kind:   .one_to_many
			to:     'articles'
			column: 'user_id'
			ref:    'author'
		},
	]
}

// fields checks a name, and keeps emails unique and out of GraphQL's output.
pub fn (u User) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:      'name'
			not_empty: true
			max_len:   100
		},
		vgraph.Field{
			name:      'email'
			unique:    true
			sensitive: true
			pattern:   r'^[^@\s]+@[^@\s]+$'
		},
	]
}

// graphql makes users Nodes, found by global id.
pub fn (u User) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		node: true
	}
}
```

Put the models in a module of their own (`models/`), so the generated client can
import them.

## Generate the client

In the folder with your `v.mod`:

```sh
v run ~/.vmodules/five07/vgraph/cmd/vgraph gen .
```

`vgraph gen` finds the structs with an `edges()` method, checks the schema (every
edge's table and columns, every option), and writes a module, `graph/`: a typed
client (queries, nodes, builders) and a GraphQL server for it. Run it again after
changing a model; the output is checked in, like any code. `vgraph describe .`
prints the schema as vgraph reads it, and `vgraph gen --no-graphql` writes the
client alone.

## Create the tables

vgraph doesn't run migrations; V's `v.migrations` does, and vgraph gives it the
tables, indexes and keys the schema needs ([Migrations](migrations.md)):

<!-- snippet: docs/snippets/setup.v#migration -->
```v
// initial creates the tables from the schema `vgraph gen` wrote, then the
// join table, the indexes the edges need, and each table's range of global ids.
const initial = migrations.Migration{
	version: 1
	name:    'initial'
	up:      fn (mut ctx migrations.Context) ! {
		s := graph.schema()!
		for table in ['users', 'articles', 'comments', 'tags'] {
			vgraph.create_table(mut ctx, s, table)!
		}
		ctx.create_table(s.join_table('articles', 'tags')!)!
		vgraph.add_edge_indexes(mut ctx, s)!
		vgraph.global_ids(mut ctx, s)!
	}
	down:    fn (mut ctx migrations.Context) ! {
		for table in ['article_tags', 'comments', 'tags', 'articles', 'users', 'vgraph_types'] {
			ctx.drop_table(table)!
		}
	}
}
```

<!-- snippet: docs/snippets/setup.v#open -->
```v
// open returns a graph on a new in-memory SQLite database, migrated. vgraph's
// driver wraps the connection, for what the ORM can't run: keys read back
// from inserts, upserts, several orders, per-parent limits.
fn open() !graph.Graph {
	mut db := sqlite.connect(':memory:')!
	mut m := migrations.new(mut db, [initial], dialect: .sqlite)!
	m.migrate()!
	return graph.Graph.new(vsqlite.new(db))!
}
```

## Query and write

<!-- snippet: docs/snippets/getting_started_test.v#quick-start -->
```v
g := open()!
ada := g.users().create().set_name('Ada').set_email('ada@example.com').save()!
g.articles().create().set_author(ada).set_title('Hello, V').exec()!
g.articles().create().set_author(ada).set_title('Batched loads').exec()!

// two queries, however many articles: the articles, then their authors
articles := g.articles().with_author().order_by_id().all()!
for a in articles {
	author := a.author or { continue }
	println('${a.article.title} by ${author.user.name}')
}
```

Each edge loads in one query for all the rows at a level, never one per row.
Next: [Queries](queries.md) and [Writes](writes.md), or serve it all over
[GraphQL](graphql.md).
