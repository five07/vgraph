module main

// The hooks that read other tables through the generated graph, which the
// models can't import: they are registered on the graph at startup.

import five07.vgraph.graphql
import graph

// register_comment_checks adds to `g` the hook that checks a new reply: its
// parent exists and is on the same owner. vgraph checks the owner itself: it
// exists, isn't deleted, and is of the type `owner_type` names.
fn register_comment_checks(g graph.Graph) {
	g.comments().use(fn [g] (next graph.CommentMutate) graph.CommentMutate {
		return fn [g, next] (ctx graphql.Context, mut m graph.CommentMutation) ! {
			if m.operation() == .create {
				check_parent(g.with_ctx(ctx), m)!
			}
			next(ctx, mut m)!
		}
	})
}

// check_parent checks the parent of the comment `m` creates, if it has one.
// Deleted records are left out of `g`'s queries.
fn check_parent(g graph.Graph, m graph.CommentMutation) ! {
	parent_id := m.parent_id() or { return }
	parent := g.comments().where_id(parent_id).first() or {
		return error('the parent comment ${parent_id} not found')
	}
	if parent.comment.owner_type != (m.owner_type() or { '' })
		|| parent.comment.owner_id != (m.owner_id() or { i64(0) }) {
		return error('a reply is on the owner of the comment it answers')
	}
}
