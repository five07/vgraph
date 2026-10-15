# vgraph

An [Ent](https://entgo.io)-style graph layer for [V](https://vlang.io). Declare the
edges between your models once; `vgraph gen` writes a typed client that loads
them in batches (one query per edge, never one per row), writes rows with
hooks and privacy rules, and serves it all over GraphQL with
[entgql](https://entgo.io/docs/graphql)'s conventions. It runs on V's ORM, on
SQLite and PostgreSQL.

**Status:** early, and not on VPM yet. Built against V master at `04cb7fa`
(2026-10-14), a daily build that still reports `V 0.5.2`.

## Quick start

A model is a V struct for V's ORM, with methods beside it:

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

Generate the client, `graph/`, in the folder with your `v.mod`:

```sh
git clone https://github.com/five07/vgraph ~/.vmodules/five07/vgraph
v run ~/.vmodules/five07/vgraph/cmd/vgraph gen .
```

Then query and write, here on a SQLite database that `open()` migrates (see
[getting started](docs/getting-started.md#create-the-tables)):

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

and serve it over GraphQL:

<!-- snippet: docs/snippets/graphql_test.v#server -->
```v
server := g.graphql(graph.Resolvers{ g: g }, default_page: 20, max_page: 100)!
res := server.execute(graphql.Request{
	query: '{ articles(first: 2, orderBy: {field: VIEWS, direction: DESC}) { edges { node { title author { name } } } } }'
}, as_viewer(Viewer{ id: 1 })) // the request's context: hooks and privacy rules get it
println(res.json())
```

## What it does

- **Every relationship kind** of Ent's: one to one, one to many, many to many,
  of two types or one, bidirectional, through an edge schema, polymorphic; on
  `int`, `i64` and UUID keys.
- **Queries** with predicates per field, edge predicates, traversals,
  aggregates, `group_by`, orders by an edge, locks, and eager loads nested to any
  depth, whose limits apply per parent. Every read runs a fixed number of
  statements, whatever the number of rows, and the tests check it.
- **Writes** with builders, upserts, bulk creates, edge writes, transactions,
  field defaults and checks, and polymorphic keys checked against their tables.
- **Hooks, interceptors and privacy rules**, on models and on the graph, with
  the app's context of who is asking; soft deletes.
- **GraphQL**: the schema and server written for you, Relay connections or
  `limit` / `offset` lists, page sizes, `WhereInput`, orders, mutations in one
  transaction, `Node`, your own fields in `.graphql` files, introspection. Its
  GraphQL module is its own, tested against graphql-js.
- **Migrations** through V's `v.migrations`: tables, indexes, foreign keys,
  triggers and global ids, from the schema.

## Docs

The [guides](docs/README.md): [getting started](docs/getting-started.md),
[schema](docs/schema.md), [queries](docs/queries.md), [writes](docs/writes.md),
[transactions](docs/transactions.md),
[hooks, interceptors and privacy](docs/hooks-and-privacy.md),
[GraphQL](docs/graphql.md), [migrations](docs/migrations.md),
[drivers](docs/drivers.md), [tracing](docs/tracing.md), and
[differences from Ent](docs/differences-from-ent.md). Their code, and the code
above, compiles and runs in [`docs/snippets`](docs/snippets).

The [examples](examples):

- [`relations`](examples/relations): every Ent relationship kind and schema
  option, on SQLite and PostgreSQL;
- [`service`](examples/service): a GraphQL API on vgraph alone, with hooks, soft
  deletes, global ids and migrations;
- [`pagination`](examples/pagination): lists by `limit` and `offset` beside
  Relay connections by cursor, and when to use which;
- [`auth`](examples/auth): JWT logins, privacy rules by viewer, and hooks that
  run one way for an admin and another for a member.

## Contributing

Issues and pull requests are welcome on GitHub. The issue forms ask for what's
needed: for a bug, the V and vgraph versions, the database, the model and query,
and the SQL `vgraph.trace` shows; for a feature, what it's for, and the Ent or
entgql feature it matches, if any.

**Setup.** vgraph needs V master at the commit in `.github/workflows/ci.yml`
(`V_COMMIT`), and `five07.otel` at the commit there (`OTEL_COMMIT`). The
examples and the generator import vgraph as `five07.vgraph`, so link your
checkout there:

```sh
v run examples/setup.vsh
```

It links the checkout into `~/.vmodules` (`$VMODULES`), and says so when another
`five07.vgraph` is already there. It links an `otel` checkout beside this one as
`five07.otel` when that is missing, or says where to get it.

**Tests.**

```sh
v test .     # everything on SQLite; the PostgreSQL tests are skipped
PGHOST=localhost PGUSER=... PGPASSWORD=... PGDATABASE=vgraph_test \
  v -d vgraph_pg test pg_test.v examples/relations/pg_test.v examples/pagination/pg_test.v
```

The PostgreSQL tests drop and recreate their tables: give them a database of
their own. The generated schemas are checked against graphql-js 16.11.0:
`npm install graphql@16.11.0`, then
`NODE_PATH=node_modules node graphql/testdata/check_schema.js examples/*/graph/schema.graphql docs/snippets/graph/schema.graphql`.
Coverage comes from V's own tool:
`v -no-skip-unused -coverage /tmp/vgraph-cov test .`, then
`v cover /tmp/vgraph-cov --filter vgraph/`.

**Layout.** The `vgraph` module is the root's `.v` files (schema, client,
writes, hooks, tracing, migration helpers). `load/` runs batched selects and
the SQL the ORM can't; `graphql/` is the GraphQL server, which doesn't import
the rest; `gen/` and `cmd/vgraph/` are the generator; `sqlite/` and `pg/` the
drivers; `regressions/` holds a program per V compiler bug vgraph meets.

**Branches.** Work goes to `develop`, and `main` gets releases, merged from it.
CI runs on `main`: formatting, doc comments, the API docs, generated code up to
date, the tests on SQLite and PostgreSQL, and graphql-js.

**Generated code.** After a change to the generator or to a model, run
`v run cmd/vgraph gen <folder>` for each of `examples/service`,
`examples/relations`, `examples/pagination`, `examples/auth` and
`docs/snippets`, and commit what changed; CI fails on stale output. A change to
`examples/service`'s schema also needs its `testdata/introspection.json`
recorded again from graphql-js (`graphql/testdata/README.md`).

**Docs.** The code in the guides and in this README is copied from
`docs/snippets`, between `// snippet: <name>` and `// end snippet`, and
`docs/snippets/docs_test.v` fails when they differ. Change the code there, then
`UPDATE_SNIPPETS=1 v test docs/snippets/docs_test.v` rewrites the Markdown.

**V's bugs.** Generics across modules and comptime are where the compiler has
had bugs. When vgraph works around one, add a small program to `regressions/`
that shows it, with a comment that says what it prints now and once fixed, and
where vgraph works around it; then report it to V, with the `upstream` label on
vgraph's issue.

**Style.** `v fmt`, and a doc comment on every `pub` item (`v vet` checks them).
Comments and docs say what a thing does and why, in plain, short sentences.

## Credits

- [Ent](https://entgo.io) and [entgql](https://entgo.io/docs/graphql), whose
  design and names vgraph follows.
- [graphql-js](https://github.com/graphql/graphql-js), the reference
  implementation that vgraph's GraphQL module is tested against, and
  [graphql.org](https://graphql.org), with the
  [GraphQL](https://spec.graphql.org) and
  [Relay connection](https://relay.dev/graphql/connections.htm) specs.
- [V](https://vlang.io), its ORM and `v.migrations`.
- `rest-api`, the V service that `examples/service` started from.

## License

MIT
