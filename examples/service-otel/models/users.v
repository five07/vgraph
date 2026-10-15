module models

import orm
import time
import five07.vgraph

// User is someone who writes articles, posts and comments. Its id is a global
// id (`vgraph.global_ids`), so GraphQL finds it with `node(id:)`.
@[table: 'users']
pub struct User {
	Stamps
pub:
	id         i64 @[primary; sql: serial]
	name       string
	email      string @[unique]
	deleted_at ?time.Time
}

// otel records every span of users: their queries, writes and edge loads,
// and their hooks, interceptors and GraphQL resolvers.
pub fn (u User) otel() vgraph.Otel {
	return vgraph.Otel{
		level: .full
	}
}

// edges declares a user's articles, posts and comments, deleted ones left out.
pub fn (u User) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:     'articles'
			kind:     .one_to_many
			to:       'articles'
			column:   'user_id'
			soft_del: 'deleted_at'
		},
		vgraph.Edge{
			name:     'posts'
			kind:     .one_to_many
			to:       'posts'
			column:   'user_id'
			soft_del: 'deleted_at'
		},
		vgraph.Edge{
			name:     'comments'
			kind:     .one_to_many
			to:       'comments'
			column:   'user_id'
			soft_del: 'deleted_at'
		},
	]
}

// fields checks a user's name and email, after `hooks` has normalized them.
pub fn (u User) fields() []vgraph.Field {
	return [
		deleted_at,
		vgraph.Field{
			name:      'name'
			not_empty: true
			max_len:   100
		},
		vgraph.Field{
			name:      'email'
			not_empty: true
			max_len:   254
			validate:  fn (v orm.Primitive) ! {
				if v is string && !v.contains('@') {
					return error('needs an `@`')
				}
			}
		},
	]
}

// hooks trims the name, and trims and lowercases the email, so that emails
// differing only in case are the same; and turns a delete into setting
// `deleted_at`.
pub fn (u User) hooks() []vgraph.Hook {
	return [
		normalize(fn (mut m vgraph.Mutation) {
			if name := m.field_value('name') {
				if name is string {
					m.set_field_value('name', name.trim_space())
				}
			}
			if email := m.field_value('email') {
				if email is string {
					m.set_field_value('email', email.trim_space().to_lower())
				}
			}
		}),
		vgraph.soft_delete_hook('deleted_at'),
	]
}

// interceptors leaves deleted users out of queries, but not out of edges: an
// article by a deleted user still shows its author.
pub fn (u User) interceptors() []vgraph.Interceptor {
	return [soft_delete_query()]
}

// graphql: users are Nodes, and their lists Relay connections.
pub fn (u User) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		node:  true
		relay: true
	}
}
