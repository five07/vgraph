# Hooks, interceptors and privacy

As in Ent, a model declares hooks, interceptors and privacy rules beside
`edges()`, and an app registers more on its graph at startup. All three get a
context: the app's value of who is asking, which `g.with_ctx(ctx)` gives the
graph, and the GraphQL server gives each request.

<!-- snippet: docs/snippets/setup.v#viewer -->
```v
// Viewer is the app's own context: who is asking. `g.with_ctx(viewer)` passes
// it to hooks, interceptors and privacy rules; the GraphQL server passes each
// request's.
struct Viewer {
	id    i64
	admin bool
}

fn viewer_of(ctx graphql.Context) Viewer {
	return if ctx is Viewer { ctx } else { Viewer{} }
}
```

## Hooks

A hook wraps the writes of a table: it can change the mutation before `next`,
check it after, or return an error, which stops the write and rolls back its
transaction. On the graph, hooks are typed:

<!-- snippet: docs/snippets/hooks_test.v#hook -->
```v
// trim every title, on create and update
g.articles().use(fn (next graph.ArticleMutate) graph.ArticleMutate {
	return fn [next] (ctx graphql.Context, mut m graph.ArticleMutation) ! {
		if title := m.title() {
			m.set_title(title.trim_space())
		}
		next(ctx, mut m)!
	}
})
```

On a model, or for every table, they are untyped, as a model can't import the
generated module. `vgraph.on`, `only_if` and `unless` limit one:

<!-- snippet: docs/snippets/hooks_test.v#hook-generic -->
```v
// a hook for every table, limited to deletes, that logs who deleted what
g.use(vgraph.on(vgraph.Hook{
	name: 'audit'
	run:  fn (next vgraph.Mutate) vgraph.Mutate {
		return fn [next] (ctx graphql.Context, mut m vgraph.Mutation) ! {
			next(ctx, mut m)!
			println('${viewer_of(ctx).id} deleted ${m.table_name()} ${m.key()}')
		}
	}
}, .delete_one))
```

They run outermost first: privacy, the graph's (`g.use`), the table's
(`g.articles().use`), the model's (`hooks()`); then the checks and the SQL, in
the write's transaction. Defaults are set before the hooks run. A hook can
change values, edges (`add_ids`, `remove_ids`, `clear_edge`) and conditions
(`where`), turn a delete into an update (`set_op`), read `key()`, `keys()` and
`old_field()` (or a typed `old_<field>()`), and register `on_commit` and
`on_rollback` callbacks. A bulk create runs them per row.

## Interceptors

An interceptor runs before every select of its table: root queries, counts, edge
loads, traversals, edge predicates and the GraphQL resolvers. It narrows the
query or fails it:

<!-- snippet: docs/snippets/hooks_test.v#interceptor -->
```v
// a viewer who isn't an admin reads published articles only, everywhere:
// lists, counts, edges, traversals and GraphQL
g.articles().intercept(fn (ctx graphql.Context, q graph.ArticleQuery) !graph.ArticleQuery {
	if viewer_of(ctx).admin {
		return q
	}
	return q.where_status(.published)
})
```

One with `edges: false` leaves edge loads out, so a record still shows a
soft-deleted row it refers to, while lists leave it out.

## Privacy

Query rules and mutation rules return `.allow`, `.deny` or `.skip`: the first to
allow or deny decides, and when they all skip, the operation runs. A query rule
can narrow the query and skip, as a filter. A denial is a `vgraph.PrivacyError`,
and in GraphQL an error at its field.

<!-- snippet: docs/snippets/hooks_test.v#policy -->
```v
// only an admin deletes users; anyone else is a PrivacyError
g.users().policy(vgraph.Policy{
	mutation: [
		fn (ctx graphql.Context, m vgraph.Mutation) !vgraph.Decision {
			if m.operation() !in [.delete, .delete_one] {
				return .skip
			}
			return if viewer_of(ctx).admin { .allow } else { .deny }
		},
	]
})
```

Rules registered on the graph run before the model's own (`policy()`), so a
rule that should leave admins to the model's rule has to skip them itself.

## Skipping them

<!-- snippet: docs/snippets/hooks_test.v#privileged -->
```v
// the app's own reads and writes: privacy rules skipped, hooks still run
g.privileged().users().delete_one(b.bob).exec() or { println(err) }
// interceptors and hooks skipped by name, such as the soft delete's
deleted := g.skip('soft_delete').articles().where_deleted_at_is_not_null().all()!
```

`vgraph.soft_delete_hook(column)` and `vgraph.soft_delete_query(column)`, both
named `soft_delete`, make a table's deletes soft: the snippets' articles use
them.

[`examples/auth`](../examples/auth) puts it together: JWT logins, privacy rules
by viewer, and hooks that run one way for an admin and another for a member.
