// Package models holds the example's two tables: authors, whose GraphQL
// lists page by `limit` and `offset`, and books, whose lists are Relay
// connections that page by cursor.
module models

import five07.vgraph

// Author wrote books, each with one or more authors.
@[table: 'authors']
pub struct Author {
pub:
	id   int @[primary; sql: serial]
	name string
	born int
}

// edges declares an author's books, through `book_authors`. Books are Relay
// connections, so `author.books` is one too, paged per author.
pub fn (a Author) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:       'books'
			kind:       .many_to_many
			to:         'books'
			column:     'author_id'
			through:    'book_authors'
			through_to: 'book_id'
		},
	]
}

// Book has one or more authors.
@[table: 'books']
pub struct Book {
pub:
	id    int @[primary; sql: serial]
	title string
	year  int
	pages int
}

// edges declares a book's authors, the other side of `Author.books`. Authors
// are plain lists, so `book.authors` takes `limit` and `offset`, per book.
pub fn (b Book) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:       'authors'
			kind:       .many_to_many
			to:         'authors'
			column:     'book_id'
			through:    'book_authors'
			through_to: 'author_id'
		},
	]
}

// graphql makes lists of books, at the root and on `author.books`, Relay
// connections, of at most 100 books a page, whatever the server's own
// maximum.
pub fn (b Book) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		relay:    true
		max_page: 100
	}
}
