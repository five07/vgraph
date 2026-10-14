module models

import orm
import time
import five07.vgraph

// Article is a long-form piece of writing by a user. It is published when it
// has a `published_at`.
@[table: 'articles']
pub struct Article {
	Stamps
pub:
	id           i64 @[primary; sql: serial]
	user_id      i64
	title        string
	summary      string
	body         string
	published_at ?time.Time
	deleted_at   ?time.Time
}

// edges declares an article's author, which every article has and which
// doesn't change, deleted or not, and its comments, deleted ones left out.
pub fn (a Article) edges() []vgraph.Edge {
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
			type_val: 'Article'
			soft_del: 'deleted_at'
		},
	]
}

// fields checks an article's title, summary and body, after `hooks` has
// trimmed the title and summary; the summary is empty unless set.
pub fn (a Article) fields() []vgraph.Field {
	return [
		deleted_at,
		vgraph.Field{
			name:      'title'
			not_empty: true
			max_len:   200
		},
		vgraph.Field{
			name:    'summary'
			max_len: 500
			default: fn () orm.Primitive {
				return ''
			}
		},
		vgraph.Field{
			name:     'body'
			max_len:  20_000
			validate: not_blank
		},
	]
}

// hooks trims the title and summary, and turns a delete into setting
// `deleted_at`.
pub fn (a Article) hooks() []vgraph.Hook {
	return [trim('title', 'summary'), vgraph.soft_delete_hook('deleted_at')]
}

// interceptors leaves deleted articles out of queries, but not out of edges: a
// comment on a deleted article still shows it.
pub fn (a Article) interceptors() []vgraph.Interceptor {
	return [soft_delete_query()]
}

// graphql: articles are Nodes, and their lists Relay connections.
pub fn (a Article) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		node:  true
		relay: true
	}
}
