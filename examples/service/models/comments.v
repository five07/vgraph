module models

import time
import five07.vgraph

// Comment is a comment by a user on another record, its owner: `owner_type`
// is the owner's type (`Article`, `Post`), and `owner_id` its id. The owner
// can be in either table, so the database can't check it with a foreign key:
// vgraph's writes do, from the `article` and `post` edges, and so do the
// triggers of the second migration. A reply has the id of the comment it
// answers in `parent_id`, which must have the same owner: a hook of the app
// checks that (`register_comment_checks`, in `hooks.v`).
@[table: 'comments']
pub struct Comment {
	Stamps
pub:
	id         i64 @[primary; sql: serial]
	user_id    i64
	owner_type string
	owner_id   i64
	parent_id  ?i64
	body       string
	deleted_at ?time.Time
}

// edges declares a comment's author, parent and owner, deleted or not, none of
// which change, and its replies, deleted ones left out. Its owner is reached
// through `article` or `post`, as its `owner_type` says.
pub fn (c Comment) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:      'author'
			kind:      .many_to_one
			to:        'users'
			column:    'user_id'
			required:  true
			immutable: true
		},
		vgraph.Edge{
			name:      'parent'
			kind:      .many_to_one
			to:        'comments'
			column:    'parent_id'
			immutable: true
		},
		vgraph.Edge{
			name:      'article'
			kind:      .many_to_one
			to:        'articles'
			column:    'owner_id'
			type_col:  'owner_type'
			type_val:  'Article'
			immutable: true
		},
		vgraph.Edge{
			name:      'post'
			kind:      .many_to_one
			to:        'posts'
			column:    'owner_id'
			type_col:  'owner_type'
			type_val:  'Post'
			immutable: true
		},
		vgraph.Edge{
			name:     'replies'
			kind:     .one_to_many
			to:       'comments'
			column:   'parent_id'
			soft_del: 'deleted_at'
		},
	]
}

// fields checks a comment's body; its owner's type doesn't change.
pub fn (c Comment) fields() []vgraph.Field {
	return [
		deleted_at,
		vgraph.Field{
			name:      'owner_type'
			immutable: true
		},
		vgraph.Field{
			name:     'body'
			max_len:  5_000
			validate: not_blank
		},
	]
}

// hooks turns a delete into setting `deleted_at`.
pub fn (c Comment) hooks() []vgraph.Hook {
	return [vgraph.soft_delete_hook('deleted_at')]
}

// interceptors leaves deleted comments out of queries, but not out of edges:
// a reply to a deleted comment still shows its parent.
pub fn (c Comment) interceptors() []vgraph.Interceptor {
	return [soft_delete_query()]
}

// graphql: comments are Nodes, and their lists Relay connections.
pub fn (c Comment) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		node:  true
		relay: true
	}
}
