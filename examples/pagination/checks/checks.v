// Package checks holds the example's checks, which `main_test.v` runs on
// SQLite and `pg_test.v` on PostgreSQL: each pages through the seed with
// GraphQL queries, as a client sends them, and compares what comes back with
// what the formulas in `catalog` say the pages hold.
module checks

import five07.vgraph
import five07.vgraph.graphql
import catalog
import graph

// Log holds the table of each select the server's connection ran, and `sql`
// for each statement of the driver's own.
@[heap]
pub struct Log {
mut:
	tables []string
}

// Fixture is a seeded database's GraphQL server, and the log of its
// statements.
pub struct Fixture {
	g      graph.Graph
	server &graphql.Server
	log    &Log
}

// new_fixture returns the server of `g`, a graph on a seeded database whose
// connection reports to `log`.
pub fn new_fixture(g graph.Graph, log &Log) !Fixture {
	return Fixture{
		g:      g
		server: g.graphql(graph.Resolvers{})!
		log:    log
	}
}

// log_to returns a tracer that adds each select's table to `log`, and `sql`
// for each statement of the driver's own.
pub fn log_to(log &Log) vgraph.Tracer {
	return fn [log] (e vgraph.TraceEvent) {
		mut l := unsafe { log }
		if e.kind == .select {
			l.tables << e.table
		} else if e.kind == .raw {
			l.tables << 'sql'
		}
	}
}

// statements returns the statements run since the last call.
fn (f Fixture) statements() []string {
	mut log := f.log
	tables := log.tables.clone()
	log.tables.clear()
	return tables
}

// run runs `query` and returns its data, or its errors as one.
fn (f Fixture) run(query string) !graphql.Value {
	r := f.server.execute(graphql.Request{
		query: query
	}, unsafe { nil })
	if r.errors.len > 0 {
		return error(r.errors.map(it.message).join('\n'))
	}
	return r.data or { graphql.null }
}

// at returns the value at `keys` in the objects of `v`.
fn at(v graphql.Value, keys ...string) graphql.Value {
	mut cur := v
	for k in keys {
		cur = cur.as_map()[k] or { graphql.null }
	}
	return cur
}

// strings returns `key` of each object of the list `v`.
fn strings(v graphql.Value, key string) []string {
	return v.as_list().map(at(it, key).as_string())
}

// titles returns the titles of a book connection's nodes.
fn titles(conn graphql.Value) []string {
	return at(conn, 'edges').as_list().map(at(it, 'node', 'title').as_string())
}

// names_by_name returns the names of the authors with the ids `ids`, sorted.
fn names_by_name(ids []int) []string {
	mut names := ids.map(catalog.author_name(it))
	names.sort()
	return names
}

// titles_by_year returns the titles of the books with the ids `ids`, by year
// and then id, as a connection ordered by YEAR returns them.
fn titles_by_year(ids []int) []string {
	mut sorted := ids.clone()
	sorted.sort_with_compare(fn (a &int, b &int) int {
		ya, yb := catalog.book_year(*a), catalog.book_year(*b)
		if ya != yb {
			return ya - yb
		}
		return *a - *b
	})
	return sorted.map(catalog.book_title(it))
}

// all_books returns the ids of the seeded books.
pub fn all_books() []int {
	return []int{len: catalog.book_count, init: index + 1}
}

// books_of returns the ids of the books of the author `author`.
fn books_of(author int) []int {
	return all_books().filter(author in catalog.book_authors(it))
}

// list_pages pages through `authors` with `args`, `limit` at a time, by
// `offset`, until a page comes back short, and returns the names in order.
fn (f Fixture) list_pages(args string, limit int) ![]string {
	mut out := []string{}
	for offset := 0; true; offset += limit {
		page := strings(at(f.run('{ authors(${args}, limit: ${limit}, offset: ${offset}) { name } }')!,
			'authors'), 'name')
		out << page
		if page.len < limit {
			break
		}
	}
	return out
}

// walk pages through the book connection that `field` selects (`books`, or
// `authors(...) { books` for an author's), with `args`, `n` at a time:
// forwards with `first` and `after`, or backwards with `last` and `before`.
// It returns the titles in the connection's order, and the number of pages.
fn (f Fixture) walk(field string, args string, n int, forward bool) !([]string, int) {
	mut out := []string{}
	mut cursor := ''
	mut pages := 0
	for {
		mut page := if forward { 'first: ${n}' } else { 'last: ${n}' }
		if cursor != '' {
			page += if forward { ', after: "${cursor}"' } else { ', before: "${cursor}"' }
		}
		mut conn := graphql.Value(graphql.null)
		if field == 'books' {
			conn = at(f.run('{ books(${page}${args}) { edges { node { title } } pageInfo { hasNextPage hasPreviousPage startCursor endCursor } } }')!,
				'books')
		} else {
			lists := at(f.run('{ ${field}(${page}${args}) { edges { node { title } } pageInfo { hasNextPage hasPreviousPage startCursor endCursor } } } }')!,
				'authors').as_list()
			conn = at(lists[0], 'books')
		}
		pages++
		info := at(conn, 'pageInfo')
		if forward {
			out << titles(conn)
			if !at(info, 'hasNextPage').as_bool() {
				return out, pages
			}
			cursor = at(info, 'endCursor').as_string()
		} else {
			mut before := titles(conn)
			before << out
			out = before.clone()
			if !at(info, 'hasPreviousPage').as_bool() {
				return out, pages
			}
			cursor = at(info, 'startCursor').as_string()
		}
		if pages > catalog.book_count {
			return error('${field}: the pages never end')
		}
	}
	return out, pages
}

// check_lists checks that lists page by `limit` and `offset`, in the order
// `orderBy` gives, and that a page that comes back short is the last.
pub fn check_lists(f Fixture) ! {
	by_name := names_by_name([]int{len: catalog.author_count, init: index + 1})
	for limit in [1, 7, 40, 100] {
		assert f.list_pages('orderBy: {field: NAME}', limit)! == by_name
	}
	assert f.list_pages('orderBy: {field: NAME, direction: DESC}', 9)! == by_name.reverse()
	// a filter, and the count a client shows beside the pages
	born := []int{len: catalog.author_count, init: index + 1}.filter(catalog.author_born(it) >= 1950)
	data := f.run('{ authorsCount(where: {bornGTE: 1950}) authors(where: {bornGTE: 1950}, orderBy: {field: NAME}, limit: 5, offset: 5) { name } }')!
	assert at(data, 'authorsCount').as_int() == born.len
	assert strings(at(data, 'authors'), 'name') == names_by_name(born)[5..10]
	// past the end, an empty page
	assert f.run('{ authors(limit: 10, offset: 40) { name } }')!.json() == '{"authors":[]}'
}

// check_connections checks that connections page by cursor, forwards and
// backwards, by the key or by a field (then the key, so the order is total).
pub fn check_connections(f Fixture) ! {
	by_id := all_books().map(catalog.book_title(it))
	for n in [25, 100] {
		forwards, pages := f.walk('books', '', n, true)!
		assert forwards == by_id
		assert pages == (catalog.book_count + n - 1) / n
		backwards, _ := f.walk('books', '', n, false)!
		assert backwards == by_id
	}
	by_year := titles_by_year(all_books())
	for n in [1, 16, 64] {
		forwards, _ := f.walk('books', ', orderBy: {field: YEAR}', n, true)!
		assert forwards == by_year
		backwards, _ := f.walk('books', ', orderBy: {field: YEAR}', n, false)!
		assert backwards == by_year
	}
	desc, _ := f.walk('books', ', orderBy: {field: YEAR, direction: DESC}', 32, true)!
	assert desc == by_year.reverse()
	// a filter: totalCount is the whole connection, not the page
	recent := all_books().filter(catalog.book_year(it) >= 2000)
	conn := at(f.run('{ books(first: 5, where: {yearGTE: 2000}, orderBy: {field: YEAR}) { totalCount edges { node { title } } pageInfo { hasNextPage hasPreviousPage } } }')!,
		'books')
	assert at(conn, 'totalCount').as_int() == recent.len
	assert titles(conn) == titles_by_year(recent)[..5]
	assert at(conn, 'pageInfo').json() == '{"hasNextPage":true,"hasPreviousPage":false}'
	filtered, _ := f.walk('books', ', where: {yearGTE: 2000}, orderBy: {field: YEAR}', 10,
		true)!
	assert filtered == titles_by_year(recent)
	// first: 0 asks for the count alone
	assert f.run('{ books(first: 0) { totalCount edges { cursor } } }')!.json() == '{"books":{"totalCount":300,"edges":[]}}'
	// a cursor is opaque, and one that isn't vgraph's is an error
	if _ := f.run('{ books(first: 1, after: "nope") { totalCount } }') {
		assert false
	}
}

// check_nested checks that lists and connections on edges page per parent:
// each author's first books, each book's authors.
pub fn check_nested(f Fixture) ! {
	// each author's three earliest books, and how many it has
	data := f.run('{ authors(orderBy: {field: ID}, limit: 6) { name books(first: 3, orderBy: {field: YEAR}) { totalCount edges { node { title } } pageInfo { hasNextPage } } } }')!
	for i, author in at(data, 'authors').as_list() {
		mine := books_of(i + 1)
		books := at(author, 'books')
		assert at(author, 'name').as_string() == catalog.author_name(i + 1)
		assert at(books, 'totalCount').as_int() == mine.len
		assert titles(books) == titles_by_year(mine)[..3]
		assert at(books, 'pageInfo', 'hasNextPage').as_bool() == (mine.len > 3)
	}
	// all of one author's books, a page at a time, both ways
	for n in [2, 5] {
		forwards, _ := f.walk('authors(where: {id: "7"}) { books', ', orderBy: {field: YEAR}',
			n, true)!
		assert forwards == titles_by_year(books_of(7))
		backwards, _ := f.walk('authors(where: {id: "7"}) { books', ', orderBy: {field: YEAR}',
			n, false)!
		assert backwards == titles_by_year(books_of(7))
	}
	// each book's second author by name: a list edge's limit and offset
	books := at(f.run('{ books(first: 9) { edges { node { title authors(orderBy: {field: NAME}, limit: 1, offset: 1) { name } } } } }')!,
		'books', 'edges').as_list()
	for i, edge in books {
		names := names_by_name(catalog.book_authors(i + 1))
		assert strings(at(edge, 'node', 'authors'), 'name') == names[1..]
	}
}

// check_statements checks that a page costs the same statements whatever its
// size, and wherever it is.
pub fn check_statements(f Fixture) ! {
	query := '{ authors(orderBy: {field: NAME}, limit: LIMIT, offset: OFFSET) { name books(first: FIRST, orderBy: {field: YEAR}) { totalCount edges { node { title authors { name } } } } } }'
	f.statements()
	f.run(query.replace('LIMIT', '2').replace('OFFSET', '0').replace('FIRST', '1'))!
	small := f.statements()
	f.run(query.replace('LIMIT', '30').replace('OFFSET', '10').replace('FIRST', '20'))!
	assert f.statements() == small
	conn := '{ books(first: FIRST, after: AFTER, orderBy: {field: YEAR}) { totalCount edges { node { title authors(limit: 1) { name } } } pageInfo { endCursor } } }'
	first := at(f.run(conn.replace('FIRST', '3').replace(', after: AFTER', ''))!, 'books',
		'pageInfo', 'endCursor').as_string()
	f.statements()
	f.run(conn.replace('FIRST', '3').replace('AFTER', '"${first}"'))!
	small_page := f.statements()
	f.run(conn.replace('FIRST', '90').replace('AFTER', '"${first}"'))!
	assert f.statements() == small_page
}

// check_writes_between_pages checks what a write between two requests does
// to each kind of page: an offset shifts, so a row shows twice (or is
// skipped); a cursor carries on after the last row seen. It writes, so it
// runs on a database of its own.
pub fn check_writes_between_pages(f Fixture) ! {
	// a list: page 1, then an author that sorts first, then page 2
	page1 := strings(at(f.run('{ authors(orderBy: {field: NAME}, limit: 5) { name } }')!,
		'authors'), 'name')
	f.run('mutation { createAuthor(input: {name: "Aaron Abbot", born: 1990}) { id } }')!
	page2 := strings(at(f.run('{ authors(orderBy: {field: NAME}, limit: 5, offset: 5) { name } }')!,
		'authors'), 'name')
	assert page2[0] == page1[4], 'the offset moved: the last row of page 1 shows again'
	// a connection: page 1, then a book that sorts first, then the next page
	conn := at(f.run('{ books(first: 5, orderBy: {field: YEAR}) { edges { node { title } } pageInfo { endCursor } } }')!,
		'books')
	f.run('mutation { createBook(input: {title: "Early", year: 1900, pages: 10}) { id } }')!
	next := at(f.run('{ books(first: 5, after: "${at(conn, 'pageInfo', 'endCursor').as_string()}", orderBy: {field: YEAR}) { edges { node { title } } } }')!,
		'books')
	by_year := titles_by_year(all_books())
	assert titles(conn) == by_year[..5]
	assert titles(next) == by_year[5..10], 'the cursor carried on where page 1 ended'
}

// check_page_sizes checks the bounds on page sizes: a size below zero is an
// error, a server's `GraphqlOptions` give a default and a maximum, and a
// table's `graphql()` overrides them (books: at most 100).
pub fn check_page_sizes(plain Fixture) ! {
	g := plain.g
	for query, message in {
		'{ authors(limit: -1) { name } }':                                        '`limit` on a list cannot be less than zero.'
		'{ authors(offset: -1) { name } }':                                       '`offset` on a list cannot be less than zero.'
		'{ books(first: -1) { totalCount } }':                                    '`first` on a connection cannot be less than zero.'
		'{ books(last: -2) { totalCount } }':                                     '`last` on a connection cannot be less than zero.'
		'{ books(first: 1) { edges { node { authors(limit: -1) { name } } } } }': '`limit` on a list cannot be less than zero.'
		'{ authors(limit: 1) { books(first: -1) { totalCount } } }':              '`first` on a connection cannot be less than zero.'
		'{ books(first: 101) { totalCount } }':                                   '`first` on a connection cannot be more than 100.'
	} {
		if _ := plain.run(query) {
			assert false, query
		} else {
			assert err.msg() == message
		}
	}
	// without options, a list without a limit is every row, and books are
	// bounded by their own maximum
	assert at(plain.run('{ authors { name } }')!, 'authors').as_list().len == catalog.author_count
	assert titles(at(plain.run('{ books { edges { node { title } } } }')!, 'books')).len == 100
	// a default and a maximum for every table; books keep their own maximum
	f := Fixture{
		g:      g
		server: g.graphql(graph.Resolvers{}, default_page: 10, max_page: 50)!
		log:    &Log{}
	}
	assert at(f.run('{ authors { name } }')!, 'authors').as_list().len == 10
	assert at(f.run('{ authors(limit: 50) { name } }')!, 'authors').as_list().len == 40
	conn := at(f.run('{ books { edges { node { title } } pageInfo { hasNextPage } } }')!, 'books')
	assert titles(conn).len == 10
	assert at(conn, 'pageInfo', 'hasNextPage').as_bool()
	assert titles(at(f.run('{ books(first: 100) { edges { node { title } } } }')!, 'books')).len == 100
	// per parent too
	nested := f.run('{ authors(limit: 2, orderBy: {field: ID}) { books { edges { node { title } } } } }')!
	assert at(nested, 'authors').as_list().map(titles(at(it, 'books')).len) == [10, 10]
	for query, message in {
		'{ authors(limit: 51) { name } }':     '`limit` on a list cannot be more than 50.'
		'{ books(last: 101) { totalCount } }': '`last` on a connection cannot be more than 100.'
	} {
		if _ := f.run(query) {
			assert false, query
		} else {
			assert err.msg() == message
		}
	}
	// a maximum alone is the size of a page that asks for none
	capped := Fixture{
		g:      g
		server: g.graphql(graph.Resolvers{}, max_page: 25)!
		log:    &Log{}
	}
	assert at(capped.run('{ authors { name } }')!, 'authors').as_list().len == 25
	// options that can't hold
	if _ := g.graphql(graph.Resolvers{}, default_page: 60, max_page: 50) {
		assert false
	} else {
		assert err.msg() == 'GraphqlOptions: the default page size, 60, is more than the maximum, 50'
	}
	if _ := g.graphql(graph.Resolvers{}, default_page: 200) {
		assert false
	} else {
		assert err.msg() == '`books`: the default page size, 200, is more than the maximum, 100'
	}
}
