module models

import time
import five07.vgraph

// Post is a short piece of writing by a user, like a status update.
@[table: 'posts']
pub struct Post {
	Stamps
pub:
	id         i64 @[primary; sql: serial]
	user_id    i64
	body       string
	deleted_at ?time.Time
}

// otel leaves the level of posts to the app when it runs: `VGRAPH_OTEL_LEVEL`
// or the client's `otel_level`, `ops` when neither says.
pub fn (p Post) otel() vgraph.Otel {
	return vgraph.Otel{
		level: .default
	}
}

// edges declares a post's author, which every post has and which doesn't
// change, deleted or not, and its comments, deleted ones left out.
pub fn (p Post) edges() []vgraph.Edge {
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
			name:     'comments'
			kind:     .one_to_many
			to:       'comments'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Post'
			soft_del: 'deleted_at'
		},
	]
}

// fields checks a post's body.
pub fn (p Post) fields() []vgraph.Field {
	return [
		deleted_at,
		vgraph.Field{
			name:     'body'
			max_len:  2_000
			validate: not_blank
		},
	]
}

// hooks turns a delete into setting `deleted_at`.
pub fn (p Post) hooks() []vgraph.Hook {
	return [vgraph.soft_delete_hook('deleted_at')]
}

// interceptors leaves deleted posts out of queries, but not out of edges: a
// comment on a deleted post still shows it.
pub fn (p Post) interceptors() []vgraph.Interceptor {
	return [soft_delete_query()]
}

// graphql: posts are Nodes, and their lists Relay connections.
pub fn (p Post) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		node:  true
		relay: true
	}
}
