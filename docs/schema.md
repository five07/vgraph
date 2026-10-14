# Schema

A schema is the models' structs, the methods beside them, and V's ORM attributes
on their fields. `vgraph gen` reads it by compiling a program that registers
each struct with an `edges()` method; `Schema.validate` (run by `Client.new` and
by `vgraph gen`) reports every problem at once.

## Fields

Every field of the struct is a column, named as V's ORM names it. The key has
`@[primary]`; `@[sql: serial]` lets the database set it.

- **Types:** `i8` to `u64`, `f32`, `f64`, `bool`, `string`, `time.Time`, enums,
  aliases of those (`pub type Email = string`), and options of all of them
  (`?time.Time` is a nullable column). `[]u8` isn't supported yet: V's ORM can't
  create or read a bytes column.
- **Keys:** `int`, `i64` or `string` (a UUID: `@[primary; sql_type: 'uuid']` on
  PostgreSQL).
- **Required:** a field that isn't an option, has no default and isn't `serial`
  is required on create.

`fields()` gives fields options:

<!-- snippet: docs/snippets/models/models.v#article -->
```v
// Status is where an article is in its life: stored as an integer, a GraphQL
// enum.
pub enum Status {
	draft
	published
	archived
}

// Article is written by a user, has comments, and is tagged.
@[table: 'articles']
pub struct Article {
	Stamps
pub:
	id         i64 @[primary; sql: serial]
	user_id    i64
	title      string
	status     Status
	views      int
	deleted_at ?time.Time
}

// edges declares an article's author, its comments and its tags.
pub fn (a Article) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:     'author'
			kind:     .many_to_one
			to:       'users'
			column:   'user_id'
			ref:      'articles'
			required: true
		},
		vgraph.Edge{
			name:   'comments'
			kind:   .one_to_many
			to:     'comments'
			column: 'article_id'
		},
		vgraph.Edge{
			name:       'tags'
			kind:       .many_to_many
			to:         'tags'
			column:     'article_id'
			through:    'article_tags'
			through_to: 'tag_id'
		},
	]
}

// fields checks a title and describes it in GraphQL, starts each article
// as a draft with no views.
pub fn (a Article) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:      'title'
			not_empty: true
			max_len:   200
			comment:   'The headline, at most 200 bytes.'
		},
		vgraph.Field{
			name:    'status'
			default: fn () orm.Primitive {
				return int(Status.draft)
			}
		},
		vgraph.Field{
			name:    'views'
			min:     0
			default: fn () orm.Primitive {
				return 0
			}
		},
	]
}

// hooks and interceptors make deletes soft: a delete sets `deleted_at`, and
// queries leave those rows out.
pub fn (a Article) hooks() []vgraph.Hook {
	return [vgraph.soft_delete_hook('deleted_at')]
}

// interceptors leaves soft-deleted articles out of queries: see `hooks`.
pub fn (a Article) interceptors() []vgraph.Interceptor {
	return [vgraph.soft_delete_query('deleted_at')]
}

// graphql makes articles Nodes, and their lists Relay connections.
pub fn (a Article) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		node:  true
		relay: true
	}
}
```

| Option | What it does |
|--------|--------------|
| `not_empty`, `min_len`, `max_len`, `pattern` | check strings |
| `min`, `max`, `positive` | check numbers |
| `validate: fn (value orm.Primitive) !` | any other check |
| `default`, `default_now` | a value on create, when the write sets none |
| `update_default`, `update_now` | a value on each update |
| `optional` | a create may leave it out: the database's default applies |
| `immutable` | only a create sets it |
| `unique` | a unique index, from the migration helpers |
| `sensitive` | never in GraphQL's output (still in its inputs) |
| `json: '[]string'` | a `string` column holding JSON of that V type |
| `comment`, `deprecated` | the field's GraphQL description, and `@deprecated` |
| `graphql_skip_in`, `order_field`, `directives` | the field's GraphQL shape |

A failed check is a `vgraph.ValidationError`, such as
`` `articles.title`: is empty ``. Checks run after the hooks, on the values the
write will store.

## Edges

An edge is a `vgraph.Edge` in `edges()`: its `name`, `kind`, the table it goes
`to`, and the `column` that holds the key.

| Kind | Where `column` is | Example |
|------|-------------------|---------|
| `many_to_one` | on this table | an article's `author` (`articles.user_id`) |
| `one_to_many` | on the target | a user's `articles` (`articles.user_id`) |
| `one_to_one` | on the target, at most one row | a user's `profile` |
| `many_to_many` | in the join table `through`; `through_to` holds the target's key | an article's `tags` (`article_tags`) |

The side with the foreign key is `many_to_one`; the other side is `one_to_many`
or `one_to_one`; a join table makes `many_to_many`. These cover every Ent
relationship kind; [`examples/relations`](../examples/relations) has one of each,
of two types and of the same type, bidirectional, through an edge schema, and on
UUID keys.

Edge options:

- `ref`: the inverse edge's name; `validate` checks the two are one relationship.
- `required`, `immutable`: on a many_to_one edge, a create must set it, and only a
  create may.
- `unique`: a many_to_one edge that is the key side of a one-to-one relationship
  (Ent's `Unique()`), with a unique index.
- `bidi`: a self edge stored both ways (a spouse, which must be `unique`;
  friends).
- `soft_del`: a target column that marks targets deleted when it isn't null;
  loads leave them out.
- `type_col`, `type_val`: a polymorphic edge, whose `column` holds keys of several
  tables and `type_col` names which, such as a comment's `owner_type` and
  `owner_id`. No foreign key can check it, so writes read the target
  ([Writes](writes.md#polymorphic-keys)).
- `graphql_skip`, `order_field`, `directives`: the edge's GraphQL shape.

A many_to_many edge whose join table is a registered struct is an edge schema:
its join rows are written through that struct's create, with its defaults and
hooks.

## Mixins

An embedded struct is a mixin: its fields are the table's columns, named
`<Struct>.<field>` as V's ORM names them, and its `fields()`, `edges()`,
`hooks()`, `interceptors()`, `indexes()` and `policy()` apply before the table's
own.

<!-- snippet: docs/snippets/models/models.v#stamps -->
```v
// Stamps is a mixin: a struct embedded in a model, whose fields are the
// model's columns, and whose options apply to each model that embeds it.
pub struct Stamps {
pub:
	created_at time.Time
	updated_at time.Time
}

// fields sets the times: both on create, `updated_at` on each update.
pub fn (s Stamps) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:        'created_at'
			default_now: true
			immutable:   true
		},
		vgraph.Field{
			name:        'updated_at'
			default_now: true
			update_now:  true
		},
	]
}
```

## Enums, aliases and JSON

An enum is stored as an integer and is a GraphQL enum (`Status` above: `DRAFT`,
`PUBLISHED`, `ARCHIVED`). An alias keeps its name in the generated API: a
`serial_no Serial` field takes a `Serial`. A `string` field with
`json: '[]string'` gets `node.<field>_value()`, `set_<field>_value(v)`, and on
updates `append_<field>(items...)` for lists; it is a `JSON` scalar in GraphQL.

## Views, indexes, global ids

- **Views:** a struct marked `@[vgraph: 'view']` reads a database view; it has
  no write builders.
- **Indexes:** `indexes()` returns `vgraph.Index` values: columns, `unique`, and
  a partial index's `where`. The migration helpers create them with the indexes
  the edges need.
- **Global ids:** `vgraph.global_ids` gives each table with an `i64` serial key its
  own range of keys, as Ent does: the table with index `n` counts from `n << 32`,
  so a key names its table (`client.table_of(key)`). GraphQL's `node(id:)` needs
  them. Create such tables with `vgraph.create_table`, which gives the key
  `AUTOINCREMENT` on SQLite and `BIGSERIAL` on PostgreSQL.

`graphql()` returns a `vgraph.GraphqlTable` with the table's GraphQL options:
see [GraphQL](graphql.md#options).
