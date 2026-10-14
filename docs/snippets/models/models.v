// Package models holds the blog the guides use: users, their articles, the
// comments on them, and tags. The regions between `snippet:` comments are
// copied into the guides, and `docs_test.v` checks they stay the same.
module models

import orm
import time
import five07.vgraph

// snippet: stamps
// Stamps is a mixin: a struct embedded in a model, whose fields are the
// model's columns, and whose options apply to each model that embeds it.
pub struct Stamps {
pub:
	created_at time.Time
	updated_at time.Time
}

// fields sets the times: both on create, `updated_at` on each update.
pub fn (s Stamps) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:        'created_at'
			default_now: true
			immutable:   true
		},
		vgraph.Field{
			name:        'updated_at'
			default_now: true
			update_now:  true
		},
	]
}

// end snippet

// snippet: user
// User writes articles and comments.
@[table: 'users']
pub struct User {
	Stamps
pub:
	id    i64 @[primary; sql: serial]
	name  string
	email string
}

// edges declares a user's articles: the other side of `Article.author`.
pub fn (u User) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'articles'
			kind:   .one_to_many
			to:     'articles'
			column: 'user_id'
			ref:    'author'
		},
	]
}

// fields checks a name, and keeps emails unique and out of GraphQL's output.
pub fn (u User) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:      'name'
			not_empty: true
			max_len:   100
		},
		vgraph.Field{
			name:      'email'
			unique:    true
			sensitive: true
			pattern:   r'^[^@\s]+@[^@\s]+$'
		},
	]
}

// graphql makes users Nodes, found by global id.
pub fn (u User) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		node: true
	}
}

// end snippet

// snippet: article
// Status is where an article is in its life: stored as an integer, a GraphQL
// enum.
pub enum Status {
	draft
	published
	archived
}

// Article is written by a user, has comments, and is tagged.
@[table: 'articles']
pub struct Article {
	Stamps
pub:
	id         i64 @[primary; sql: serial]
	user_id    i64
	title      string
	status     Status
	views      int
	deleted_at ?time.Time
}

// edges declares an article's author, its comments and its tags.
pub fn (a Article) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:     'author'
			kind:     .many_to_one
			to:       'users'
			column:   'user_id'
			ref:      'articles'
			required: true
		},
		vgraph.Edge{
			name:   'comments'
			kind:   .one_to_many
			to:     'comments'
			column: 'article_id'
		},
		vgraph.Edge{
			name:       'tags'
			kind:       .many_to_many
			to:         'tags'
			column:     'article_id'
			through:    'article_tags'
			through_to: 'tag_id'
		},
	]
}

// fields checks a title and describes it in GraphQL, starts each article
// as a draft with no views.
pub fn (a Article) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:      'title'
			not_empty: true
			max_len:   200
			comment:   'The headline, at most 200 bytes.'
		},
		vgraph.Field{
			name:    'status'
			default: fn () orm.Primitive {
				return int(Status.draft)
			}
		},
		vgraph.Field{
			name:    'views'
			min:     0
			default: fn () orm.Primitive {
				return 0
			}
		},
	]
}

// hooks and interceptors make deletes soft: a delete sets `deleted_at`, and
// queries leave those rows out.
pub fn (a Article) hooks() []vgraph.Hook {
	return [vgraph.soft_delete_hook('deleted_at')]
}

// interceptors leaves soft-deleted articles out of queries: see `hooks`.
pub fn (a Article) interceptors() []vgraph.Interceptor {
	return [vgraph.soft_delete_query('deleted_at')]
}

// graphql makes articles Nodes, and their lists Relay connections.
pub fn (a Article) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		node:  true
		relay: true
	}
}

// end snippet

// Comment is a user's comment on an article.
@[table: 'comments']
pub struct Comment {
	Stamps
pub:
	id         i64 @[primary; sql: serial]
	article_id i64
	user_id    i64
	body       string
}

// edges declares a comment's article and author.
pub fn (c Comment) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:      'article'
			kind:      .many_to_one
			to:        'articles'
			column:    'article_id'
			required:  true
			immutable: true
		},
		vgraph.Edge{
			name:      'author'
			kind:      .many_to_one
			to:        'users'
			column:    'user_id'
			required:  true
			immutable: true
		},
	]
}

// fields checks a comment's body.
pub fn (c Comment) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:      'body'
			not_empty: true
			max_len:   5_000
		},
	]
}

// graphql makes comments Nodes.
pub fn (c Comment) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		node: true
	}
}

// Tag labels articles.
@[table: 'tags']
pub struct Tag {
pub:
	id   int @[primary; sql: serial]
	name string
}

// edges declares the articles of a tag: the other side of `Article.tags`.
pub fn (t Tag) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:       'articles'
			kind:       .many_to_many
			to:         'articles'
			column:     'tag_id'
			through:    'article_tags'
			through_to: 'article_id'
		},
	]
}

// fields keeps tag names unique.
pub fn (t Tag) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:   'name'
			unique: true
		},
	]
}
