# vgraph

An [Ent](https://entgo.io)-style graph layer for [V](https://vlang.io): declare the edges
between your entities once, load them in batches (one query per edge, not one per row),
and traverse them through a typed API. It runs on V's `orm.Connection`, so it works with
the SQLite, PostgreSQL and MySQL adapters.

**Status:** early. Nothing is published yet. See [PLAN.md](PLAN.md) in the develop
branch for the plan.

## Example

Declare edges with an `edges()` method on each struct:

```v ignore
import five07.vgraph

@[table: 'articles']
pub struct Article {
pub:
	id         int @[primary; sql: serial]
	user_id    int
	title      string
	deleted_at ?time.Time
}

pub fn (a Article) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'author'
			kind:   .many_to_one
			to:     'users'
			column: 'user_id'
		},
		// polymorphic: comments have `owner_type` and `owner_id`
		vgraph.Edge{
			name:     'comments'
			kind:     .one_to_many
			to:       'comments'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Article'
			soft_del: 'deleted_at'
		},
	]
}
```

Register the structs, and load edges for many records at once:

```v ignore
mut schema := vgraph.Schema{}
schema.add[User]()!
schema.add[Article]()!
schema.add[Comment]()!
graph := vgraph.Client.new(db, schema)! // checks every edge against the structs
graph.ensure_indexes()! // indexes the columns edge loads filter by (temporary, see below)

articles := sql db {
	select from Article
}!
authors := graph.load_one[Article, User](articles, 'author')! // map[int]User, one query
comments := graph.load_many[Article, Comment](articles, 'comments')! // map[int][]Comment, one query
```

The edge kinds are `one_to_one`, `one_to_many`, `many_to_one` and `many_to_many`
(through a join table, in two queries). Together they cover all of Ent's
relationship kinds; `examples/relations` has one of each. `type_col` / `type_val` make an edge polymorphic, and
`soft_del` leaves out targets whose column is not null. `Client.new` reports every
edge that names a missing table or column, or a column of the wrong type.

`five07.vgraph.load` has the same loads by column name, for code without a schema.

## Typed client: `vgraph gen`

`vgraph gen` finds the structs with an `edges()` method in a project, checks their
schema, and writes a typed client module, `graph` by default:

```sh
v run ~/.vmodules/five07/vgraph/cmd/vgraph gen .   # in the folder with v.mod
```

```v ignore
import graph

g := graph.Graph.new(db)!
articles := g.articles()
	.where_deleted_at_is_null()
	.where_title_like('V%')
	.order_by_id_desc()
	.limit(10)
	.with_author()
	.with_tags()
	.with_comments(fn (q graph.CommentQuery) graph.CommentQuery {
		return q.with_author().order_by_id() // nested loads, still one query per edge
	})
	.all()! // []graph.ArticleNode

for a in articles {
	println('${a.article.title} by ${a.author?.user.name}, ${a.comments.len} comments')
}
first := articles[0].query_comments().where_body_like('%thanks%').all()! // traversal
nodes := g.comments().with_parent().nodes(rows_you_already_have)! // eager loads only
```

For each table it writes a query (`where_<field>`, `_lt`/`_gt`/`_in`/`_like`/`_is_null`
variants by type, `order_by_<field>`, `limit`, `with_<edge>`, `all`, `first`,
`nodes`) and a node holding the row and its loaded edges, with `query_<edge>` to
traverse. Regenerate it after changing a model; it is checked in, like any code.

`ensure_indexes` runs `CREATE INDEX IF NOT EXISTS` (SQLite and PostgreSQL) for each
column an edge load filters by. It is a stopgap: once a V release includes
`v.migrations`, vgraph will emit migration steps instead.

## Layout

- `edge.v`, `schema.v`, `client.v`, `migrate.v`: the `vgraph` module.
- `gen/`, `cmd/vgraph/`: the generator and the `vgraph` command.
- `load/`: `vgraph.load`, the batched loads that `Client` runs.
- `examples/service/`: a JSON REST API that uses vgraph, and its test bed.
- `examples/relations/`: every Ent relationship kind, declared and tested.
- `regressions/`: one small program per V compiler bug that vgraph works around.
- `spike/`: Phase 0, which checked that V's reflection and ORM can support this.

## Development

```sh
v test .            # SQLite; the PostgreSQL tests are skipped
PGPORT=5432 v -d vgraph_pg test pg_test.v examples/relations/pg_test.v
```

The examples import vgraph as `five07.vgraph`, so link this checkout there first:
`ln -s "$PWD" ~/.vmodules/five07/vgraph`. The PostgreSQL tests run only with
`-d vgraph_pg`, read `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE`,
and drop and recreate their tables.

## Requirements

V master (built against `53dd72c`, 2026-10-12). It will pin to a `0.5.x` release
before `v0.1.0`.

## License

MIT
