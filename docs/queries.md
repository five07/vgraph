# Queries

The generated client has a query per table, `g.<table>()`, which builds a
`load.Query` and runs it when asked for results. A query reads through the
table's privacy rules and interceptors ([Hooks, interceptors and
privacy](hooks-and-privacy.md)).

<!-- snippet: docs/snippets/queries_test.v#query -->
```v
published := g.articles()
	.where_status(.published)
	.where_title_contains('V')
	.order_by_views_desc()
	.limit(10)
	.all()! // []graph.ArticleNode
```

`where_<field>` and its variants come per field, by type: `_ne`, `_lt`, `_le`,
`_gt`, `_ge`, `_in`, `_not_in`, `_like`, `_contains`, `_has_prefix`,
`_has_suffix` (with `%` and `_` matched as themselves), `_equal_fold`,
`_contains_fold`, `_is_null` and `_is_not_null`. `order_by_<field>` and
`order_by_<field>_desc`, `limit` and `offset` follow.

## Results

<!-- snippet: docs/snippets/queries_test.v#results -->
```v
first := g.articles().order_by_id().first()! // NotFoundError when there is none
hello := g.articles().where_title('Hello, V').only()! // and NotSingularError when there are more
ids := g.articles().order_by_id().ids()! // []i64
n := g.articles().where_status(.draft).count()!
any := g.articles().where_views_gt(100).exist()!
```

A node holds the row (`a.article`) and the edges loaded with it.

## Eager loading

`with_<edge>` loads an edge for every row of the result, in one query per edge,
however many rows there are; nested loads add one query per level:

<!-- snippet: docs/snippets/queries_test.v#with -->
```v
articles := g.articles()
	.with_author()
	.with_tags()
	.with_comments(fn (q graph.CommentQuery) graph.CommentQuery {
		return q.with_author().order_by_id() // nested: still one query per edge
	})
	.order_by_id()
	.all()!
for a in articles {
	names := a.tags.map(it.tag.name).join(', ')
	println('${a.article.title} [${names}]: ${a.comments.len} comments')
	for c in a.comments {
		author := c.author or { continue }
		println('  ${author.user.name}: ${c.comment.body}')
	}
}
```

A `limit` or `offset` inside `with_<edge>` applies to each row's targets, not to
the whole load (Ent's applies to the whole load). Through a driver, the database
cuts each parent's rows with a window function, in the same one query:

<!-- snippet: docs/snippets/queries_test.v#with-limit -->
```v
// each user's newest article: the limit applies per user
users := g.users().with_articles(fn (q graph.ArticleQuery) graph.ArticleQuery {
	return q.order_by_id_desc().limit(1)
}).order_by_id().all()!
```

The same edge loaded twice, with other conditions, is a named edge; an edge that
wasn't loaded is an error to ask for:

<!-- snippet: docs/snippets/queries_test.v#named -->
```v
u := g.users().where_name('Ada').with_named_articles('drafts', fn (q graph.ArticleQuery) graph.ArticleQuery {
	return q.where_status(.draft)
}).only()!
drafts := u.named_articles['drafts']
u.articles_or_err() or { println(err) } // NotLoadedError: no with_articles()
```

`nodes` loads edges onto rows you already have:

<!-- snippet: docs/snippets/queries_test.v#nodes -->
```v
// rows read elsewhere: load their edges only
rows := [b.hello.article, b.notes.article]
with_authors := g.articles().with_author().nodes(rows)!
```

## Predicates and traversals

<!-- snippet: docs/snippets/queries_test.v#predicates -->
```v
// OR, NOT and the rest, with a function per field and operator
popular_or_v := g.articles().where(load.or(graph.article_views_gt(100), graph.article_title_has_prefix('Notes'))).all()!
untagged := g.articles().where(load.not(graph.article_has_tags())).all()!
// edge predicates
commented := g.articles().has_comments().all()!
by_ada := g.articles().has_author_with(fn (q graph.UserQuery) graph.UserQuery {
	return q.where_name('Ada')
}).all()!
// SQL of your own, with parameters
short := g.articles().where(load.raw('length(title) < ?', 12)).all()!
```

Each predicate is also a function, `graph.<struct>_<field>_<op>`, for
`load.and`, `load.or` and `load.not`. `has_<edge>` and `has_<edge>_with` are
edge predicates; the target table's privacy rules and interceptors apply to
them.

A traversal follows an edge from a query or from a node, and returns a query of
the target table:

<!-- snippet: docs/snippets/queries_test.v#traversals -->
```v
// from a query: the tags of Ada's articles
tags := g.users().where_name('Ada').query_articles().query_tags().order_by_name().all()!
// from a node
comments := b.hello.query_comments().order_by_id().all()!
```

## Aggregates, selects and orders

<!-- snippet: docs/snippets/queries_test.v#aggregates -->
```v
total := g.articles().sum_views()!
most := g.articles().max_views()!
titles := g.articles().order_by_title().select('title').all()! // other columns left at zero
scanned := g.articles().order_by_title().scan[TitleOnly]()!
by_author := g.articles().group_by('user_id').aggregate(vgraph.count(), vgraph.sum('views')).all()!
```

<!-- snippet: docs/snippets/queries_test.v#orders -->
```v
// several orders, by an edge's count, and nulls last
busiest := g.articles().order_by_comments_count_desc().order_by_id().all()!
by_author_name := g.articles().order_by_author_name().order_by_title().all()!
newest_deleted := g.articles().order_by(vgraph.desc('deleted_at').nulls_last()).all()!
```

`for_update`, `for_share`, `no_wait` and `skip_locked` lock rows, inside a
transaction, on PostgreSQL.

## What runs where

A query the ORM can express runs as one ORM select. One that needs more (NOT
around LIKE, escaped or case-insensitive matches, subqueries, several orders,
orders by an edge, nulls first or last, locks, raw SQL, `group_by`) runs keys
first through a driver: the driver selects the matching keys, in order, and the
ORM reads those rows. Without a driver, a subquery runs first as a query of its
own, and the rest fails with an error naming the drivers ([Drivers](drivers.md)).

## No N+1 queries

Every read runs a fixed list of statements, whatever the number of rows: root
queries, every edge kind with `with_<edge>` (nested, named, with per-parent
limits), traversals, edge predicates, aggregates and edge orders, interceptors
and privacy rules on queries, and every GraphQL field, list, connection and
`node`. The tests check each on SQLite and PostgreSQL, with and without a driver,
on a seed and on many more rows of every table: the statements must be the same
(`examples/relations/selects.v`).

An edge load lists at most 10,000 keys in one statement (`load.max_keys`), under
the databases' caps on parameters; past that, it runs once per 10,000 parents.
Writes aren't on the list: a create writes its row, then its edges, and hooks run
per row.

## Without the generated client

`vgraph.Client` loads edges between structs registered in a `vgraph.Schema`,
keyed by the parent key's string form (`'3'`, or a UUID), and
`five07.vgraph.load` does the same by column name, for code without a schema:

<!-- snippet: docs/snippets/queries_test.v#client-load -->
```v
mut schema := vgraph.Schema{}
schema.add[models.User]()!
schema.add[models.Article]()!
schema.add[models.Comment]()!
schema.add[models.Tag]()!
client := vgraph.Client.new(conn, schema)! // checks every edge against the structs

articles := load.select_where[models.Article](conn, load.Query{ order: 'id' })!
authors := client.load_one[models.Article, models.User](articles, 'author')! // map[string]models.User
by_user := client.load_many[models.User, models.Article](authors.values(), 'articles')!
first_author := authors[articles[0].user_id.str()] // keyed by the key's string form
```
