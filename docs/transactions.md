# Transactions

Every write runs in a transaction when the connection can begin one (a vgraph
driver, or an `orm.TransactionalConnection`): the row, its edges and its hooks
commit together. `g.tx` runs several writes in one, and a write inside it joins
it; an error rolls them all back.

<!-- snippet: docs/snippets/writes_test.v#tx -->
```v
g.tx(fn (tx graph.Graph) ! {
	cy := tx.users().create().set_name('Cy').set_email('cy@example.com').save()!
	tx.articles().create().set_author(cy).set_title('First post').exec()!
	tx.on_commit(fn () {
		println('Cy is in')
	})
})!
// an error rolls the whole transaction back
g.tx(fn (tx graph.Graph) ! {
	tx.users().create().set_name('Dee').set_email('dee@example.com').exec()!
	return error('changed my mind')
}) or { println(err) }
```

- `tx.on_commit(f)` runs `f` once the transaction commits, and `tx.on_rollback(f)`
  if it rolls back; outside a transaction, `on_commit` runs at once. A hook gets
  the same through its mutation: `m.on_commit(f)`.
- A transaction inside another joins it: only the outermost commits.
- On a PostgreSQL pool (`pg.pool(db)`), a transaction holds one connection until
  it ends. SQLite has one transaction per connection, so threads that share a
  driver take turns at them.
- A GraphQL request's mutations run in one transaction
  ([GraphQL](graphql.md#mutations)).
- `for_update` and `for_share` lock the rows a query reads until the transaction
  ends, on PostgreSQL; outside one they are an error.
