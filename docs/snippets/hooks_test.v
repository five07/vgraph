module main

import context
import five07.vgraph
import graph

fn test_hooks() {
	b := blog()!
	g := b.g
	// snippet: hook
	// trim every title, on create and update
	g.articles().use(fn (next graph.ArticleMutate) graph.ArticleMutate {
		return fn [next] (ctx context.Context, mut m graph.ArticleMutation) ! {
			if title := m.title() {
				m.set_title(title.trim_space())
			}
			next(ctx, mut m)!
		}
	})
	// end snippet
	a := g.articles().create().set_author(b.ada).set_title('  Spaced  ').save()!
	assert a.article.title == 'Spaced'
	// snippet: hook-generic
	// a hook for every table, limited to deletes, that logs who deleted what
	g.use(vgraph.on(vgraph.Hook{
		name: 'audit'
		run:  fn (next vgraph.Mutate) vgraph.Mutate {
			return fn [next] (ctx context.Context, mut m vgraph.Mutation) ! {
				next(ctx, mut m)!
				println('${viewer_of(ctx).id} deleted ${m.table_name()} ${m.key()}')
			}
		}
	}, .delete_one))
	// end snippet
	g.with_ctx(as_viewer(Viewer{ id: 7 })).articles().delete_one(a).exec()!
	assert g.skip('audit').articles().where_title('Spaced').count()! == 0
}

fn test_interceptors_and_privacy() {
	b := blog()!
	g := b.g
	// snippet: interceptor
	// a viewer who isn't an admin reads published articles only, everywhere:
	// lists, counts, edges, traversals and GraphQL
	g.articles().intercept(fn (ctx context.Context, q graph.ArticleQuery) !graph.ArticleQuery {
		if viewer_of(ctx).admin {
			return q
		}
		return q.where_status(.published)
	})
	// end snippet
	assert g.with_ctx(as_viewer(Viewer{ id: 1 })).articles().count()! == 2
	assert g.with_ctx(as_viewer(Viewer{ admin: true })).articles().count()! == 3
	// snippet: policy
	// only an admin deletes users; anyone else is a PrivacyError
	g.users().policy(vgraph.Policy{
		mutation: [
			fn (ctx context.Context, m vgraph.Mutation) !vgraph.Decision {
				if m.operation() !in [.delete, .delete_one] {
					return .skip
				}
				return if viewer_of(ctx).admin { .allow } else { .deny }
			},
		]
	})
	// end snippet
	if _ := g.with_ctx(as_viewer(Viewer{ id: 1 })).users().delete_one(b.bob).exec() {
		assert false
	} else {
		assert err is vgraph.PrivacyError
		assert err.msg() == 'privacy: delete_one of `users` denied'
	}
	// snippet: privileged
	// the app's own reads and writes: privacy rules skipped, hooks still run
	g.privileged().users().delete_one(b.bob).exec() or { println(err) }
	// interceptors and hooks skipped by name, such as the soft delete's
	deleted := g.skip('soft_delete').articles().where_deleted_at_is_not_null().all()!
	// end snippet
	assert deleted.len == 0
	assert !g.users().where_name('Bob').exist()!
}
