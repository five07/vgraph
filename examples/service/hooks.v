module main

// The hooks that read other tables through the generated graph, which the
// models can't import: they are registered on the graph at startup.

import five07.vgraph.graphql
import graph

// register_comment_checks adds to `g` the hook that checks a new comment's
// references: its owner exists, isn't deleted and is of the type it names,
// and a reply's parent is on the same owner.
fn register_comment_checks(g graph.Graph) {
	g.comments().use(fn [g] (next graph.CommentMutate) graph.CommentMutate {
		return fn [g, next] (ctx graphql.Context, mut m graph.CommentMutation) ! {
			if m.operation() == .create {
				check_references(g.with_ctx(ctx), m)!
			}
			next(ctx, mut m)!
		}
	})
}

// check_references checks the owner and the parent of the comment `m`
// creates. Deleted records are left out of `g`'s queries.
fn check_references(g graph.Graph, m graph.CommentMutation) ! {
	owner_type := m.owner_type() or { '' }
	owner_id := m.owner_id() or { i64(0) }
	exists := match owner_type {
		'Article' { g.articles().where_id(owner_id).exist()! }
		'Post' { g.posts().where_id(owner_id).exist()! }
		else { false }
	}
	if !exists {
		return error('${owner_type} ${owner_id} not found')
	}
	if parent_id := m.parent_id() {
		parent := g.comments().where_id(parent_id).first() or {
			return error('the parent comment ${parent_id} not found')
		}
		if parent.comment.owner_type != owner_type || parent.comment.owner_id != owner_id {
			return error('a reply is on the owner of the comment it answers')
		}
	}
}
