# Writes

Each table gets builders, as Ent's. A write runs in a transaction when the
connection can begin one, with its edge writes; inside `g.tx`, it joins that
one ([Transactions](transactions.md)).

<!-- snippet: docs/snippets/writes_test.v#create -->
```v
v := g.tags().create().set_name('v-lang').save()!
article := g.articles().create()
	.set_author(ada) // or .set_author_id(ada.user.id)
	.set_title('Writing with vgraph')
	.add_tags(v) // writes the join row
	.save()! // graph.ArticleNode, read back with its defaults
```

<!-- snippet: docs/snippets/writes_test.v#update -->
```v
article.update().set_title('Writing, with vgraph').set_status(.published).add_views(1).exec()!
n := g.articles().update().where_status(.draft).set_status(.archived).exec()! // rows changed
g.articles().update_one_id(article.article.id).remove_tags(v).exec()!
```

<!-- snippet: docs/snippets/writes_test.v#delete -->
```v
g.comments().delete().where_body('Nice!').exec()!
g.articles().delete_one(article).exec()! // soft: the model's hook sets deleted_at
gone := g.skip('soft_delete').articles().where_deleted_at_is_not_null().count()!
```

<!-- snippet: docs/snippets/writes_test.v#bulk -->
```v
tags := g.tags().create_bulk(g.tags().create().set_name('orm'), g.tags().create().set_name('graphql')).save()!
// an upsert: a name taken already keeps its row
g.tags().create().set_name('orm').on_conflict_columns('name').ignore().exec()!
```

- **Builders:** `create`, `create_bulk`, `map_create_bulk`, `update_one`,
  `update_one_id` (or `node.update()`), `update`, `delete_one`, `delete_one_id`,
  `delete`. `update()` and `delete()` take the query's predicates.
- **Setters:** `set_<field>`; `set_nillable_<field>` and `clear_<field>` for
  nullable fields; `add_<field>` adds to a number in the database; `set_input`
  takes a GraphQL input struct.
- **Edges:** `set_<edge>_id`, `set_<edge>` and `clear_<edge>` for edges to one
  row; `add_<edge>_ids`, `add_<edge>`, `remove_<edge>_ids`, `remove_<edge>` and
  `clear_<edge>` for the others. A bidirectional edge writes both directions.
- **Results:** `save()` returns the node, read back; `exec()` doesn't read it.
  On one row, both return `graph.NotFoundError` when it is missing.
- **Upserts:** `on_conflict_columns(...)` with `update_new_values()`, `ignore()`
  or `do_nothing()`; they need a driver.

## Validation

Defaults apply first, then the hooks, then the checks of the field options and
edges, then the SQL. A failed check is a `vgraph.ValidationError`:

<!-- snippet: docs/snippets/writes_test.v#validation -->
```v
g.articles().create().set_author(b.ada).set_title('').exec() or {
	assert err is vgraph.ValidationError
	println(err) // `articles.title`: is empty
}
g.articles().create().set_title('No author').exec() or {
	println(err) // `articles.user_id`: the edge `author` is required
}
```

## Polymorphic keys

A polymorphic edge's column holds keys of several tables, so no foreign key can
check it. The writes do: a create or update that sets either column of the pair
reads the target by key, through that table's root query, and fails with a
`ValidationError` when there is none, such as
`` `comments.owner_id`: no `Article` has the key `9` ``. The target's privacy
rules and interceptors apply, so a soft-deleted target counts as missing; a type
no edge declares fails too; a null key passes. `vgraph.add_polymorphic_checks`
adds database triggers that check the same, for writes made outside vgraph
([Migrations](migrations.md)). [`examples/service`](../examples/service) has
comments on articles and posts.

## Statements per write

A create inserts its row, then writes its edges, a statement each; hooks run per
row. A bulk create on PostgreSQL with no hooks is one insert; on SQLite it is one
per row, as SQLite's `RETURNING` doesn't promise the rows' order.
