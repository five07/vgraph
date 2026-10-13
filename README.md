# vgraph

An [Ent](https://entgo.io)-style graph layer for [V](https://vlang.io): declare the edges
between your entities once, load them in batches (one query per edge, not one per row),
traverse them through a typed API, and serve them over GraphQL. It runs on V's
`orm.Connection`, so it works with the SQLite, PostgreSQL and MySQL adapters.

**Status:** early. Nothing is published yet.

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
authors := graph.load_one[Article, User](articles, 'author')! // map[string]User, one query
comments := graph.load_many[Article, Comment](articles, 'comments')! // map[string][]Comment, one query
author := authors[articles[0].user_id.str()] // keyed by the key's string form
```

Keys can be `int`, `i64` or `string`, such as a UUID (`id string @[primary]`, with
`sql_type: 'uuid'` on PostgreSQL). The maps are keyed by the key's `str()`, so one
API serves every key type; the generated client below stays typed.

The edge kinds are `one_to_one`, `one_to_many`, `many_to_one` and `many_to_many`
(through a join table, in two queries). Together they cover all of Ent's
relationship kinds; `examples/relations` has one of each. `type_col` / `type_val` make an edge polymorphic, and
`soft_del` leaves out targets whose column is not null. `Client.new` reports every
edge that names a missing table or column, or a column whose type doesn't match the
key it holds.

`five07.vgraph.load` has the same loads by column name, for code without a schema.

## More Examples

Check out the [examples](./examples) in this repo for various examples and use-cases

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
variants by type, `order_by_<field>`, `limit`, `offset`, `with_<edge>`, `all`,
`first`, `count`, `nodes`) and a node holding the row and its loaded edges, with
`query_<edge>` to traverse. Regenerate it after changing a model; it is checked in,
like any code.

A `limit` or `offset` in `with_<edge>` applies to each row's targets:
`with_comments(fn (q graph.CommentQuery) graph.CommentQuery { return q.order_by_id_desc().limit(3) })`
loads each article's three newest comments. Ent's `Limit` there limits the whole
load; vgraph's is per parent, in one query through a driver (a window function),
or cut in V without one.

### More queries

```v ignore
// OR and NOT, with a function per field and operator
g.articles().where(load.or(graph.article_title_contains('V'), graph.article_views_gt(10)))
g.users().where(load.not(graph.user_has_card()))
// edge predicates, and traversal from a query
g.users().has_pets().all()!
g.users().has_groups_with(fn (q graph.GroupQuery) graph.GroupQuery {
	return q.where_name('admins')
}).all()!
g.users().where_name('ada').query_pets().query_owner().all()!
// results, aggregates, groups
g.users().where_name('ada').only()!           // NotFoundError, NotSingularError
g.users().order_by_name().ids()!              // []int
g.users().select('name').all()!               // other columns left at zero
g.users().unique().scan[UserName]()!          // into the app's struct
g.logins().sum_at()!                          // also min_, max_, mean_
g.logins().group_by('device_id').aggregate(vgraph.count(), vgraph.sum('at')).all()!
// orders: several columns, by an edge, nulls last; locks
g.users().order_by_pets_count_desc().order_by_name().all()!
g.pets().order_by(vgraph.asc('owner_id').nulls_last()).all()!
tx.users().where_id(1).for_update().no_wait().all()! // in g.tx, on PostgreSQL
// an edge loaded twice, and an edge that wasn't loaded
u := g.users().with_named_pets('young', fn (q graph.PetQuery) graph.PetQuery {
	return q.where_age_lt(2)
}).first()!
u.named_pets['young']
u.pets_or_err()!                              // NotLoadedError: no with_pets()
```

Predicates on each field, by type: `where_<field>` and `_ne`, `_lt`/`_le`/`_gt`/`_ge`,
`_in`/`_not_in`, `_like`, `_contains`, `_has_prefix`, `_has_suffix` (with `%` and `_`
matched as themselves), `_equal_fold`, `_contains_fold`, `_is_null`/`_is_not_null`;
the same as functions, `graph.<struct>_<field>_<op>`, for `load.and` / `or` / `not`.
`load.raw('length(name) > ?', 3)` takes SQL with parameters.

A query the ORM can express runs as one query, as before. One that needs more
(NOT around LIKE, escaped or case-insensitive matches, subqueries, several order
columns, edge orders, nulls first/last, locks, raw SQL, `group_by`) runs keys
first through a driver: the driver selects the matching keys, in order, then the
ORM reads those rows. Without a driver, a subquery runs first as a query of its
own, and the rest is refused with an error naming the drivers. Edge predicates
and traversals apply the target table's privacy rules and interceptors, as edge
loads do.

## Writes

The generated client writes too. Each table gets builders, as Ent's:

```v ignore
import five07.vgraph.sqlite as vsqlite

g := graph.Graph.new(vsqlite.new(db))! // or pg.pool(db), pg.direct(conn)
art := g.articles().create()
	.set_title('V')
	.set_author_id(user.id)  // or .set_author(user_node)
	.add_tags_ids(1, 2)      // writes the join rows
	.save()!                 // graph.ArticleNode, read back
art.update().set_title('W').clear_deleted_at().remove_tags_ids(2).exec()!
n := g.articles().update().where_user_id(3).set_title('Draft').exec()! // rows changed
g.articles().delete_one(art).exec()!                              // its join rows too
g.tags().create().set_name('v').on_conflict_columns('name').update_new_values().exec()!
g.tx(fn (tx graph.Graph) ! {
	tx.users().update_one_id(3).set_spouse_id(4).exec()!
	tx.users().update_one_id(4).set_spouse_id(3).exec()!
})!
```

- **Builders:** `create`, `create_bulk`, `map_create_bulk`, `update_one`,
  `update_one_id` (or `node.update()`), `update`, `delete_one`, `delete_one_id`,
  `delete`. `update()` and `delete()` start from the query's conditions and take
  the same `where_<field>` predicates.
- **Setters:** `set_<field>`, `set_nillable_<field>` and `clear_<field>` for
  nullable fields, `add_<field>` to increment a number in the database. Edges:
  `set_<edge>_id` / `set_<edge>` / `clear_<edge>` for unique edges, and
  `add_` / `remove_<edge>_ids`, `add_` / `remove_<edge>` and `clear_<edge>` for the
  others. A polymorphic edge sets its type column as well.
- **Transactions:** a write and its edge writes run in one transaction when the
  connection can run one; `g.tx` runs several, and writes inside it join it.
  `save()` and `exec()` on one row return `graph.NotFoundError` when it is missing.
- **Context:** `g.with_ctx(ctx)` carries an app value (its user, its request) to
  hooks, interceptors and privacy rules. It is a `graphql.Context`, and the
  generated GraphQL server passes each request's context on.

Fields that need options list them in a `fields()` method beside `edges()`; the
others are inferred: an option type is optional, a `@[sql: serial]` key is set by the
database, and anything else is required on create.

```v ignore
pub fn (a Article) fields() []vgraph.Field {
	return [
		vgraph.Field{name: 'title', not_empty: true, max_len: 200},
		vgraph.Field{name: 'slug', immutable: true, unique: true, default: fn () orm.Primitive {
			return new_slug()
		}},
		vgraph.Field{name: 'created_at', default_now: true, immutable: true},
		vgraph.Field{name: 'updated_at', default_now: true, update_now: true},
		vgraph.Field{name: 'password_hash', sensitive: true}, // not in GraphQL
	]
}
```

Checks: `not_empty`, `min_len`, `max_len`, `pattern`, `min`, `max`, `positive`, and
`validate: fn (value orm.Primitive) !` for anything else; a failed one is a
`vgraph.ValidationError`. `unique` gives the field a unique index in the migration
helpers.

**Drivers.** `orm.Connection` can't run everything a write needs, so the adapters in
`five07.vgraph.sqlite` and `five07.vgraph.pg` wrap V's connections: inserts read
their keys back with `RETURNING`, upserts use `ON CONFLICT`, and on PostgreSQL a
bulk create is one statement. Every ORM call passes through. On a plain
`orm.Connection`, writes still work: a new key comes from `last_id()` (`int` keys
only, so a string key must be set or have a default), upserts are refused, and
without `orm.TransactionalConnection` statements run one by one. On a pool,
`pg.pool(db)` holds one connection for each transaction. SQLite has one transaction
per connection, so threads that share `sqlite.new(db)` take turns at them: one
begun while another is open waits for it to end. The adapters pass values as
text, stored the way V's ORM stores them (on SQLite, times as Unix seconds), and
the SQLite one keeps SQL out of its error messages.

## Schema options

```v ignore
pub enum Color { red green }
pub type Serial = string

pub struct Stamps { // a mixin: embedded, with its own options
pub:
	created_at time.Time
	updated_at time.Time
}

pub fn (s Stamps) fields() []vgraph.Field {
	return [vgraph.Field{name: 'created_at', default_now: true, immutable: true},
		vgraph.Field{name: 'updated_at', default_now: true, update_now: true}]
}

@[table: 'gadgets']
pub struct Gadget {
	Stamps
pub:
	id        i64 @[primary; sql: serial] // a global id (see below)
	owner_id  int
	serial_no Serial // an alias: the API takes a Serial
	color     Color  // an enum: stored as an integer, a GraphQL enum
	level     i8     // any of V's integer and float types
	tags      string // JSON, with `json: '[]string'` below
}

pub fn (g Gadget) fields() []vgraph.Field {
	return [vgraph.Field{name: 'tags', json: '[]string'}]
}

pub fn (g Gadget) indexes() []vgraph.Index {
	return [vgraph.Index{columns: ['serial_no'], unique: true},
		vgraph.Index{columns: ['owner_id'], where: 'rating IS NOT NULL'}]
}
```

- **Types:** `i8` to `u64`, `f32`, `f64`, `bool`, `string`, `time.Time`, enums, type
  aliases of those, and options of those. `[]u8` isn't: V's ORM can't create or read
  a bytes column yet.
- **JSON:** a `string` column with `Field.json` naming its V type gets
  `node.<field>_value()`, `set_<field>_value(v)`, and on updates
  `append_<field>(items...)` for lists; a `JSON` scalar in GraphQL.
- **Mixins:** an embedded struct's fields are the table's columns, named
  `<Struct>.<field>` as V's ORM names them; its `fields()`, `edges()`, `hooks()`,
  `interceptors()`, `indexes()` and `policy()` apply before the table's own.
- **Edges:** `ref` names the inverse edge, and `validate` checks the pair; `unique`
  makes a many_to_one edge the key side of a one-to-one relationship, with a unique
  index (Ent's `Unique()`); `bidi` on a self edge writes both directions (a spouse,
  which must be `unique`, or friends); `required` and `immutable` on a many_to_one
  edge. A many_to_many edge whose join table is a
  registered struct is an edge schema: its join rows get that struct's defaults and
  hooks.
- **Views:** a struct marked `@[vgraph: 'view']` reads a view; it has no write
  builders.
- **Indexes:** `indexes()` declares indexes, unique and partial; `add_edge_indexes`
  creates them.
- **Global ids:** `vgraph.create_table(mut ctx, schema, 'gadgets')` creates a table
  with an `AUTOINCREMENT` / `BIGSERIAL` key, and `vgraph.global_ids(mut ctx, schema)`
  gives each table with an `i64` serial key its own range: the table with index
  `n` counts from `n << 32`, and `client.table_of(key)` names it. Reading back a new
  `i64` key needs a driver.
- **`vgraph describe [folder]`** prints the schema; `vgraph gen --no-graphql` writes
  the client alone.

## Hooks, interceptors and privacy

As in Ent, a model declares them beside `edges()`, and an app registers more on
its graph at startup:

```v ignore
// on the model: untyped, as the model can't import the generated module
pub fn (a Article) hooks() []vgraph.Hook {
	return [vgraph.on(vgraph.Hook{
		run: fn (next vgraph.Mutate) vgraph.Mutate {
			return fn [next] (ctx graphql.Context, mut m vgraph.Mutation) ! {
				if _ := m.field_value('slug') {} else {
					m.set_field_value('slug', new_slug())
				}
				next(ctx, mut m)!
			}
		}
	}, .create), vgraph.soft_delete_hook('deleted_at')]
}

pub fn (a Article) interceptors() []vgraph.Interceptor {
	return [vgraph.soft_delete_query('deleted_at')]
}

pub fn (a Article) policy() vgraph.Policy {
	return vgraph.Policy{
		mutation: [allow_if_owner, vgraph.always_deny]
	}
}

// on the graph: typed
g.articles().use(fn (next graph.ArticleMutate) graph.ArticleMutate {
	return fn [next] (ctx graphql.Context, mut m graph.ArticleMutation) ! {
		if title := m.title() {
			m.set_title(title.trim_space())
		}
		next(ctx, mut m)!
	}
})
g.users().intercept(fn (ctx graphql.Context, q graph.UserQuery) !graph.UserQuery {
	return q.where_tenant_id((ctx as Request).tenant)
})
```

- **Hooks** run around every write, outermost first: privacy, the graph's
  (`g.use`), the table's (`g.articles().use`, `use_hook`), the model's; then the
  field checks and the SQL, all in the write's transaction. Defaults are set before
  the hooks run. `vgraph.on`, `only_if` and `unless` limit a hook. A hook can change
  values, edges (`add_ids`, `remove_ids`, `clear_edge`) and conditions (`where`), turn
  a delete into an update (`set_op`), read `key()`, `keys()` and `old_field()` (or a
  typed `old_<field>()`), and register `on_commit` / `on_rollback` callbacks; an error
  stops the write. A bulk create runs them per row.
- **Interceptors** run before every select of their table: root queries, counts,
  edge loads, traversals and the GraphQL resolvers. They narrow the query or fail
  it; they can't change its results. One with `edges: false` leaves edge loads
  out, so a record still shows the soft-deleted author it refers to, while lists of
  authors leave them out: `vgraph.Interceptor{...vgraph.soft_delete_query('deleted_at'), edges: false}`.
- **Privacy:** query and mutation rules return `.allow`, `.deny` or `.skip`; the
  first to allow or deny decides, and when all skip the operation runs. A query rule
  can narrow the query and skip, as a filter. A deny is a `vgraph.PrivacyError`; in
  GraphQL it is an error at its field. `g.privileged()` skips privacy.
- **Soft delete:** `soft_delete_query` and `soft_delete_hook`, both named
  `soft_delete`; `g.skip('soft_delete')` reads, changes and purges deleted rows.
- **Transactions:** `g.on_commit(f)` and `g.on_rollback(f)` inside `g.tx`.

**Tracing.** `vgraph.trace(conn, fn (e vgraph.TraceEvent) { ... })` wraps a
connection, driver or not, and reports each statement: its kind, table, duration,
and whether it failed, plus the SQL vgraph writes itself, with its placeholders.
Events carry no values: no parameters, and no error messages, which can quote them.

## GraphQL

`vgraph gen` also writes a GraphQL schema for the tables, `graph/schema.graphql`,
and a server for it, `Graph.graphql()`. The schema follows
[entgql](https://entgo.io/docs/graphql)'s conventions: a type per table with
camelCase fields (`createdAt`, `userID`), keys and foreign keys as `ID`, edges as
fields, and per table a root list, a count, a `WhereInput`, an order and three
mutations:

```graphql
type Query {
  articles(where: ArticleWhereInput, orderBy: [ArticleOrder!], limit: Int, offset: Int): [Article!]!
  articlesCount(where: ArticleWhereInput): Int!
}

type Mutation {
  createArticle(input: CreateArticleInput!): Article!
  updateArticle(id: ID!, input: UpdateArticleInput!): Article!
  deleteArticle(id: ID!): ID!
}

type Article {
  id: ID!
  userID: ID!
  title: String!
  deletedAt: Time
  author: User
  comments(where: CommentWhereInput, orderBy: [CommentOrder!], limit: Int, offset: Int): [Comment!]
}
```

```v ignore
server := g.graphql(graph.Resolvers{})!
res := server.execute(graphql.Request{ query: '{ articles(limit: 10) { title author { name } } }' },
	unsafe { nil })
println(res.json())
// or over HTTP, from any web framework: server.handle(graphql.HttpRequest{...}, ctx)
```

Resolvers read through the client: one query per edge per level of a request,
however many rows there are, with the request's context passed to hooks and
privacy rules. A nested `limit` / `offset` (`comments(limit: 3)`) is per parent,
cut by the database with a window function through a driver, or in V without one.

- **Filters:** `where` takes entgql's `WhereInput`: `not`, `and`, `or`; per field
  `title`, `titleNEQ`, `titleIn`, `titleNotIn`, `titleGT`/`GTE`/`LT`/`LTE`,
  `titleContains`, `titleHasPrefix`, `titleHasSuffix`, `titleEqualFold`,
  `titleContainsFold`, `titleIsNil`/`NotNil`, as the field's type allows; per edge
  `hasAuthor` and `hasAuthorWith: [UserWhereInput!]`.
- **Orders:** `orderBy` takes one order or a list, by any field, and by each list
  edge's count (`TAGS_COUNT`). Several, or an edge's, need a driver.
- **Mutations:** `create<T>`, `update<T>` and `delete<T>`, with entgql's inputs:
  `CreateArticleInput` has each writable field, required when the create needs it,
  and `tagIDs`; `UpdateArticleInput` has every mutable field, `clearDeletedAt`,
  `addTagIDs`, `removeTagIDs`, `clearTags`. They run the generated builders, so
  field checks, defaults, hooks and privacy apply; the client has the inputs too,
  `graph.CreateArticleInput` and `set_input`. A request's mutations run in one
  transaction (`vgraph.GraphqlTransaction`), on the request's connection, when the
  client can begin one: an error in any rolls back all.
- **Relay connections**, per table with `relay` (below): its lists, at the root and
  on edges, take `first`/`after`/`last`/`before` and return
  `ArticleConnection { edges { node cursor } pageInfo totalCount }`. Cursors hold
  the row's order values and key, so pages follow from where the last one ended
  (`after` is a condition, not an offset); `totalCount` is counted only when it is
  asked for. A connection orders by its key last, so another order needs a driver.
- **Node**, per table with `node`: `node(id: ID!)` and `nodes(ids: [ID!]!)` find a
  row by its global id (`vgraph.global_ids`), for tables with an `i64` serial key.
  The server checks at startup that each has its range.

A struct gives its GraphQL options in a `graphql()` method, and its fields' and
edges' in `fields()` and `edges()`, as entgql's annotations:

```v ignore
pub fn (g Gadget) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		type_name:   'Device'          // the type's name; the struct's by default
		query_field: 'devices'         // the root field, or '-' for none
		node:        true              // implements Node
		relay:       true              // connections rather than lists
		mutations:   [.create, .update] // the default is all three; [] for none
		directives:  ['@key(fields: "id")']
	}
}

vgraph.Field{name: 'title', comment: 'A description.', deprecated: 'Use `name`.',
	graphql_skip_in: [.update_input], order_field: 'TITLE', directives: ['@tag(name: "x")']}
vgraph.Edge{..., order_field: 'name'} // orders by the target's name: OWNER_NAME
```

`@[graphql: '-']` on a field or struct, or `graphql_skip`, leaves it out; a
`sensitive` field is left out of the type, filters and orders but stays in the
inputs. Directives print in `schema.graphql` as Apollo's subgraph schemas print
them; declare them in a `.graphql` file.

Fields of your own, and mutations, go in `.graphql` files anywhere in the project
(`extend type Query { me: User }`, `extend type Mutation { ... }`). `vgraph gen`
merges them into the schema and adds a stub for each new field to
`graph/resolvers.v`, a file it creates once and then never changes, apart from
adding stubs: the methods of `Resolvers` are yours to write. A method that writes
should go through `graph.with_ctx(ctx)`, which is the request's transaction in a
mutation. Operations and fragments go in `operations/` folders: `vgraph gen`
checks them against the schema, so a schema change that breaks a client's query
fails there, at its file and line.

The GraphQL implementation is the `graphql` module (`five07.vgraph.graphql`), which
doesn't depend on the rest of vgraph: a lexer and parser for the whole language,
schemas built from SDL, every validation rule of the spec, an executor that hands
each resolver all the parents at a level at once, introspection, Relay
connections, and an HTTP handler following the GraphQL over HTTP spec. It is
tested against cases recorded from graphql-js, the reference implementation
Apollo builds on, and matches its messages, locations, printed schemas and
introspection exactly (`graphql/testdata/README.md`).

## Migrations

vgraph doesn't run migrations: V's `v.migrations` does, from migrations you write.
vgraph gives them what the declared edges need, as `v.migrations` values:

- `schema.migration_indexes()`: an index on each column an edge load filters by
  (unique for a `one_to_one` edge), and a unique index on each join table's two
  columns, so a pair is stored once;
- `schema.foreign_keys()`: a foreign key on each column that holds one table's
  keys; none for a polymorphic edge's column, which holds several tables' keys;
- `schema.join_table(table, edge)`: a many_to_many edge's join table, for
  `ctx.create_table`;
- `vgraph.add_edge_indexes(mut ctx, schema)` and `remove_edge_indexes`, for a
  migration's `up` and `down`.

```v ignore
import v.migrations

fn initial_up(mut ctx migrations.Context) ! {
	migrations.create_orm_table[User](mut ctx)!
	migrations.create_orm_table[Article](mut ctx)!
	migrations.create_orm_table[Comment](mut ctx)!
	vgraph.add_edge_indexes(mut ctx, graph.schema()!)! // graph.schema(): from vgraph gen
}
```

A migration that takes its indexes from the schema makes those the edges need when
it is written. A later migration that adds edges adds their indexes, and the first
one then lists its own, so a new database gets the same ones.

SQLite can't add a foreign key to a table that exists: put a table's keys in the
`migrations.Table` that creates it, or use the ORM's `@[references]` on tables
created from structs. `v.migrations` runs on PostgreSQL through a direct
connection (`pg.connect_direct`), not a pool. Both examples migrate this way, on
SQLite and PostgreSQL.

## Layout

- `edge.v`, `schema.v`, `field.v`, `client.v`, `driver.v`, `mutation.v`, `write.v`,
  `hooks.v`, `trace.v`, `gql.v`, `migrate.v`: the `vgraph` module.
- `sqlite/`, `pg/`: the drivers, `five07.vgraph.sqlite` and `five07.vgraph.pg`.
- `gen/`, `cmd/vgraph/`: the generator and the `vgraph` command.
- `load/`: `vgraph.load`, the batched loads that `Client` runs.
- `graphql/`: the GraphQL server library, independent of the rest of vgraph.
- `examples/service/`: a GraphQL API that runs on vgraph alone, and its test bed.
- `examples/relations/`: every Ent relationship kind, declared and tested.
- `regressions/`: one small program per V compiler bug that vgraph works around.

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
