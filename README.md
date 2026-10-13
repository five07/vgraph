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

articles := sql db {
	select from Article
}!
authors := graph.load_one[Article, User](articles, 'author')! // map[int]User, one query
comments := graph.load_many[Article, Comment](articles, 'comments')! // map[int][]Comment, one query
```

The edge kinds are `one_to_many`, `many_to_one` and `many_to_many` (through a join
table, in two queries). `type_col` / `type_val` make an edge polymorphic, and
`soft_del` leaves out targets whose column is not null. `Client.new` reports every
edge that names a missing table or column, or a column of the wrong type.

`five07.vgraph.load` has the same loads by column name, for code without a schema.

## Layout

- `edge.v`, `schema.v`, `client.v`: the `vgraph` module.
- `load/`: `vgraph.load`, the batched loads that `Client` runs.
- `example/`: a JSON REST API that uses vgraph, and its test bed.
- `regressions/`: one small program per V compiler bug that vgraph works around.
- `spike/`: Phase 0, which checked that V's reflection and ORM can support this.

## Development

```sh
v test .                                    # SQLite; pg_test.v is skipped
PGPORT=5432 v -d started_postgres test pg_test.v  # with a PostgreSQL server running
```

`example/` imports vgraph as `five07.vgraph`, so link this checkout there first:
`ln -s "$PWD" ~/.vmodules/five07/vgraph`. `pg_test.v` reads `PGHOST`, `PGPORT`,
`PGUSER`, `PGPASSWORD` and `PGDATABASE`.

## Requirements

V master (built against `53dd72c`, 2026-10-12). It will pin to a `0.5.x` release
before `v0.1.0`.

## License

MIT
