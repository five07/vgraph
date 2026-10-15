module graphql

import context
import os

const library_sdl = '
type Query {
  books(genre: Genre): [Book!]!
  book(id: ID!): Book
  hello(name: String = "world"): String!
  broken: String!
}

type Mutation {
  addBook(title: String!): Book!
}

enum Genre { SCIFI FANTASY }

type Book {
  id: ID!
  title: String!
  genre: Genre
  author: Author
}

type Author {
  name: String!
  books: [Book!]!
}
'

struct Book {
	id     int
	title  string
	genre  string
	author string
}

fn library() !&Server {
	mut s := Server.new(library_sdl)!
	books := [Book{1, 'Dune', 'SCIFI', 'Herbert'}, Book{2, 'Hobbit', 'FANTASY', 'Tolkien'},
		Book{3, 'Children of Dune', 'SCIFI', 'Herbert'}]
	s.resolve('Query', 'books', fn [books] (_ context.Context, info FieldInfo, parents []Source) ![]Resolved {
		genre := info.arg('genre')
		found := books.filter(genre is Null || Value(it.genre) == genre).map(obj(it))
		return parents.map(list(found))
	})
	s.resolve('Query', 'hello', fn (_ context.Context, info FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(Value('hello ${info.arg('name')}')))
	})
	s.resolve('Query', 'broken', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return error('it broke')
	})
	s.resolve_each('Book', 'id', fn (_ context.Context, _ FieldInfo, parent Source) !Resolved {
		return Value((parent as Book).id)
	})
	s.resolve_each('Book', 'title', fn (_ context.Context, _ FieldInfo, parent Source) !Resolved {
		return Value((parent as Book).title)
	})
	s.resolve_each('Book', 'genre', fn (_ context.Context, _ FieldInfo, parent Source) !Resolved {
		return Value((parent as Book).genre)
	})
	// one call for every book at a level: the batching the executor promises
	s.resolve('Book', 'author', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(Value({
			'name': Value((it as Book).author)
		})))
	})
	return s
}

fn test_query_with_arguments_aliases_and_fragments() {
	mut s := library()!
	r := s.execute(Request{
		query:     '
			query ($g: Genre) {
				scifi: books(genre: $g) { ...b }
				all: books { title author { name } }
				hello
				other: hello(name: "you")
				__typename
			}
			fragment b on Book { id title genre }'
		variables: {
			'g': Value('SCIFI')
		}
	}, context.background())
	assert r.errors.len == 0, r.json()
	assert r.json() == '{"data":{"scifi":[{"id":"1","title":"Dune","genre":"SCIFI"},{"id":"3","title":"Children of Dune","genre":"SCIFI"}],"all":[{"title":"Dune","author":{"name":"Herbert"}},{"title":"Hobbit","author":{"name":"Tolkien"}},{"title":"Children of Dune","author":{"name":"Herbert"}}],"hello":"hello world","other":"hello you","__typename":"Query"}}'
}

fn test_errors_null_the_nearest_nullable_field() {
	mut s := library()!
	r := s.execute(Request{
		query: '{ hello broken }'
	}, context.background())
	assert r.json() == '{"errors":[{"message":"it broke","locations":[{"line":1,"column":9}],"path":["broken"]}],"data":null}'
}

fn test_request_errors() {
	mut s := library()!
	assert s.execute(Request{
		query: '{ nope }'
	}, context.background()).json() == '{"errors":[{"message":"Cannot query field \\"nope\\" on type \\"Query\\".","locations":[{"line":1,"column":3}]}]}'
	assert s.execute(Request{
		query: '{'
	}, context.background()).json() == '{"errors":[{"message":"Syntax Error: Expected Name, found <EOF>.","locations":[{"line":1,"column":2}]}]}'
	r := s.execute(Request{
		query:     'query ($g: Genre) { books(genre: $g) { id } }'
		variables: {
			'g': Value('HORROR')
		}
	}, context.background())
	assert r.request_error
	assert r.errors[0].message == 'Variable "\$g" got invalid value "HORROR"; Value "HORROR" does not exist in "Genre" enum.'
}

fn test_introspection() {
	mut s := library()!
	r := s.execute(Request{
		query: '{ __type(name: "Book") { name kind fields { name type { kind name ofType { name } } } } }'
	}, context.background())
	assert r.errors.len == 0, r.json()
	assert r.json() == '{"data":{"__type":{"name":"Book","kind":"OBJECT","fields":[{"name":"id","type":{"kind":"NON_NULL","name":null,"ofType":{"name":"ID"}}},{"name":"title","type":{"kind":"NON_NULL","name":null,"ofType":{"name":"String"}}},{"name":"genre","type":{"kind":"ENUM","name":"Genre","ofType":null}},{"name":"author","type":{"kind":"OBJECT","name":"Author","ofType":null}}]}}}'
}

fn test_introspection_matches_graphql_js() {
	text := os.read_file(os.join_path(@DIR, 'testdata', 'introspection.json'))!
	cases := parse_json(text)!.as_list()
	assert cases.len == 2
	for c in cases {
		m := c.as_map()
		mut s := Server.new(m['sdl'] or { null }.as_string())!
		got := s.execute(Request{
			query: m['query'] or { null }.as_string()
		}, context.background())
		want := m['result'] or { null }
		assert got.json() == want.json()
	}
}

const zoo_sdl = '
type Query {
  animals: [Animal!]!
  pets: [Pet]
  count: Int!
  numbers: [Int!]
  big: Int
}

type Mutation {
  add(name: String!): Int!
  fail: Int
}

interface Animal { name: String! }
type Dog implements Animal { name: String! barks: Boolean! }
type Cat implements Animal { name: String! lives: Int! }
union Pet = Dog | Cat
'

@[heap]
struct Calls {
mut:
	names  []string
	log    []string
	counts map[string]int
}

struct MemoryTx {
mut:
	calls &Calls
}

// InTx is the value a `MemoryTx` adds to the context of a request's mutations.
struct InTx {
	n int
}

const in_tx_key = 'in_tx'

fn in_tx(ctx context.Context) ?InTx {
	if v := ctx.value(in_tx_key) {
		if v is InTx {
			return v
		}
	}
	return none
}

fn (t MemoryTx) begin(ctx context.Context) !context.Context {
	mut calls := t.calls
	calls.log << 'begin'
	return context.with_value(ctx, in_tx_key, InTx{
		n: calls.log.len
	})
}

fn (t MemoryTx) commit(ctx context.Context) ! {
	mut calls := t.calls
	calls.log << if tx := in_tx(ctx) { 'commit ${tx.n}' } else { 'commit' }
}

fn (t MemoryTx) rollback(ctx context.Context) ! {
	mut calls := t.calls
	calls.log << if tx := in_tx(ctx) { 'rollback ${tx.n}' } else { 'rollback' }
}

fn zoo(mut calls Calls) !&Server {
	mut s := Server.new(zoo_sdl)!
	animals := [
		Value({
			'__typename': Value('Dog')
			'name':       'rex'
			'barks':      true
		}),
		Value({
			'__typename': Value('Cat')
			'name':       'tom'
			'lives':      9
		}),
	]
	s.resolve('Query', 'animals', fn [animals] (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(Value(animals)))
	})
	s.resolve('Query', 'pets', fn [animals] (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		// a null item in a nullable list, and an object of no type at all
		return parents.map(list([Resolved(animals[0]), null, obj(map[string]Value{})]))
	})
	s.resolve('Query', 'count', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(null))
	})
	s.resolve('Query', 'numbers', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(Value([Value(1), null, Value(3)])))
	})
	s.resolve('Query', 'big', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(Value(f64(1e10))))
	})
	s.resolve('Animal', 'name', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return error('never called: fields resolve on object types')
	})
	// count the calls per field: each must be called once per level
	for t in ['Dog', 'Cat'] {
		s.resolve(t, 'name', fn [mut calls, t] (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
			calls.counts['${t}.name']++
			return parents.map(Resolved((it as map[string]Value)['name'] or { null }))
		})
	}
	s.resolve('Mutation', 'add', fn [mut calls] (ctx context.Context, info FieldInfo, parents []Source) ![]Resolved {
		// the resolvers of a mutation get the transaction's context
		if in_tx(ctx) == none {
			return error('not in the transaction')
		}
		calls.names << info.arg('name').as_string()
		return parents.map(Resolved(Value(calls.names.len)))
	})
	s.resolve('Mutation', 'fail', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return error('no')
	})
	s.transaction = MemoryTx{
		calls: calls
	}
	return s
}

fn test_abstract_types_and_batching() {
	mut calls := &Calls{}
	mut s := zoo(mut calls)!
	r := s.execute(Request{
		query: '{ animals { __typename name ... on Dog { barks } ... on Cat { lives } } }'
	}, context.background())
	assert r.json() == '{"data":{"animals":[{"__typename":"Dog","name":"rex","barks":true},{"__typename":"Cat","name":"tom","lives":9}]}}'
	assert calls.counts == {
		'Dog.name': 1
		'Cat.name': 1
	}
}

fn test_null_propagation_and_paths() {
	mut calls := &Calls{}
	mut s := zoo(mut calls)!
	r := s.execute(Request{
		query: '{ numbers pets { ... on Dog { name } } }'
	}, context.background())
	assert r.json() == '{"errors":[{"message":"Cannot return null for non-nullable field Query.numbers.","locations":[{"line":1,"column":3}],"path":["numbers",1]},{"message":"Abstract type \\"Pet\\" must resolve to an Object type at runtime for field \\"Query.pets\\". Either the \\"Pet\\" type should provide a \\"resolveType\\" function or each possible type should provide an \\"isTypeOf\\" function.","locations":[{"line":1,"column":11}],"path":["pets",2]}],"data":{"numbers":null,"pets":[{"name":"rex"},null,null]}}'
	whole := s.execute(Request{
		query: '{ count }'
	}, context.background())
	assert whole.json() == '{"errors":[{"message":"Cannot return null for non-nullable field Query.count.","locations":[{"line":1,"column":3}],"path":["count"]}],"data":null}'
	assert s.execute(Request{
		query: '{ big }'
	}, context.background()).errors[0].message == 'Int cannot represent non 32-bit signed integer value: 10000000000'
}

fn test_skip_include_and_operation_names() {
	mut calls := &Calls{}
	mut s := zoo(mut calls)!
	query := '
		query A(\$on: Boolean!) { animals { name @include(if: \$on) ... on Dog @skip(if: \$on) { barks } } }
		query B { __typename }'
	r := s.execute(Request{
		query:          query
		operation_name: 'A'
		variables:      {
			'on': Value(false)
		}
	}, context.background())
	assert r.json() == '{"data":{"animals":[{"barks":true},{}]}}'
	assert s.execute(Request{
		query: query
	}, context.background()).errors[0].message == 'Must provide operation name if query contains multiple operations.'
	assert s.execute(Request{
		query:          query
		operation_name: 'C'
	}, context.background()).errors[0].message == 'Unknown operation named "C".'
}

fn test_mutations_run_in_order_in_a_transaction() {
	mut calls := &Calls{}
	mut s := zoo(mut calls)!
	r := s.execute(Request{
		query: 'mutation { a: add(name: "x") b: add(name: "y") }'
	}, context.background())
	assert r.json() == '{"data":{"a":1,"b":2}}'
	assert calls.names == ['x', 'y']
	assert calls.log == ['begin', 'commit 1']
	failed := s.execute(Request{
		query: 'mutation { a: add(name: "z") fail }'
	}, context.background())
	assert failed.errors.map(it.message) == ['no']
	assert calls.log == ['begin', 'commit 1', 'begin', 'rollback 3']
}

fn test_http() {
	mut calls := &Calls{}
	mut s := zoo(mut calls)!
	ok := s.handle(HttpRequest{
		method:       'POST'
		content_type: 'application/json'
		body:         '{"query": "query (\$n: Boolean!) { __typename @include(if: \$n) }", "variables": {"n": true}}'
	}, context.background())
	assert ok.status == 200
	assert ok.content_type == 'application/json; charset=utf-8'
	assert ok.body == '{"data":{"__typename":"Query"}}'
	invalid := s.handle(HttpRequest{
		method:       'POST'
		content_type: 'application/json'
		accept:       'application/graphql-response+json'
		body:         '{"query": "{ nope }"}'
	}, context.background())
	assert invalid.status == 400
	assert invalid.content_type == 'application/graphql-response+json; charset=utf-8'
	get := s.handle(HttpRequest{
		method:       'GET'
		query_string: 'query=%7B%20__typename%20%7D'
	}, context.background())
	assert get.body == '{"data":{"__typename":"Query"}}'
	mutation := s.handle(HttpRequest{
		method:       'GET'
		query_string: 'query=mutation%20%7B%20fail%20%7D'
	}, context.background())
	assert mutation.status == 405
	assert mutation.headers['Allow'] == 'POST'
	assert s.handle(HttpRequest{
		method:       'POST'
		content_type: 'text/plain'
		body:         '{}'
	}, context.background()).status == 415
	assert s.handle(HttpRequest{
		method:       'POST'
		content_type: 'application/json'
		body:         '{"query": 1}'
	}, context.background()).body == '{"errors":[{"message":"The request must have a \\"query\\" string."}]}'
	// each malformed request, with its status and message
	for req, want in {
		'POST {':            '400 The body is not valid JSON'
		'POST []':           '400 The body must be a JSON object.'
		'POST op':           '400 operationName\\" must be a string.'
		'POST vars':         '400 variables\\" must be an object.'
		'GET variables=%7B': '400 variables is not valid JSON.'
		'GET a=%':           '400 The query string is malformed.'
		'PUT':               '405 GraphQL is served with GET and POST.'
	} {
		method := req.all_before(' ')
		rest := req.all_after_first(' ')
		body := match rest {
			'op' { '{"query": "{ __typename }", "operationName": 1}' }
			'vars' { '{"query": "{ __typename }", "variables": []}' }
			else { rest }
		}
		res := s.handle(HttpRequest{
			method:       method
			content_type: 'application/json; charset=utf-8'
			query_string: if method == 'GET' { 'query=%7B__typename%7D&' + rest } else { '' }
			body:         body
		}, context.background())
		assert '${res.status} ${res.body}'.starts_with(want.all_before(' ') + ' '), req
		assert res.body.contains(want.all_after_first(' ')), req
	}
	put := s.handle(HttpRequest{
		method: 'PUT'
	}, context.background())
	assert put.headers['Allow'] == 'GET, POST'
	// a named operation by GET, with variables
	named := s.handle(HttpRequest{
		method:       'GET'
		query_string: 'query=query%20A(%24n%3A%20Boolean!)%20%7B%20__typename%20%40include(if%3A%20%24n)%20%7D&operationName=A&variables=%7B%22n%22%3Afalse%7D'
	}, context.background())
	assert named.body == '{"data":{}}'
}

// Relay connections: `Server.connection` resolves a `Connection`; a resolver
// sees whether `totalCount` is asked for, through named fragments too.
fn test_connections() {
	mut s := Server.new('type Query { items(first: Int, last: Int, after: String): ItemConnection! }
type Item { name: String! }
type ItemConnection { edges: [ItemEdge] pageInfo: PageInfo! totalCount: Int! }
type ItemEdge { node: Item cursor: String! }
type PageInfo { hasNextPage: Boolean! hasPreviousPage: Boolean! startCursor: String endCursor: String }')!
	mut asked := []bool{}
	log := &asked
	s.resolve('Query', 'items', fn [log] (_ context.Context, info FieldInfo, parents []Source) ![]Resolved {
		mut l := unsafe { log }
		l << info.selected('totalCount')
		page := page_args(info.args)!
		names := ['a', 'b', 'c']
		n := page.first or { 3 }
		items := names[..n].map(Source({
			'name': Value(it)
		}))
		result := obj(connection(items, names[..n].map('c-${it}'), n < 3, false, 3))
		return parents.map(result)
	})
	s.connection('ItemConnection', 'ItemEdge')
	r := s.execute(Request{
		query: '{ items(first: 2) { ...Page edges { cursor node { name } } } } fragment Page on ItemConnection { totalCount pageInfo { hasNextPage hasPreviousPage startCursor endCursor } }'
	}, context.background())
	assert r.json() == '{"data":{"items":{"totalCount":3,"pageInfo":{"hasNextPage":true,"hasPreviousPage":false,"startCursor":"c-a","endCursor":"c-b"},"edges":[{"cursor":"c-a","node":{"name":"a"}},{"cursor":"c-b","node":{"name":"b"}}]}}}'
	empty := s.execute(Request{
		query: '{ items(first: 0) { edges { cursor } pageInfo { startCursor endCursor } } }'
	}, context.background())
	assert empty.json() == '{"data":{"items":{"edges":[],"pageInfo":{"startCursor":null,"endCursor":null}}}}'
	assert asked == [true, false]
	both := s.execute(Request{
		query: '{ items(first: 1, last: 1) { totalCount } }'
	}, context.background())
	assert both.errors.map(it.message) == ['Passing both `first` and `last` to paginate a connection is not supported.']
	below := s.execute(Request{
		query: '{ items(last: -2) { totalCount } }'
	}, context.background())
	assert below.errors.map(it.message) == ['`last` on a connection cannot be less than zero.']
}

// Applied directives print only when asked for, as Apollo's subgraph schemas
// print them; graphql-js's printSchema leaves them out.
fn test_print_applied_directives() {
	schema := build_schema('directive @tag(name: String!) repeatable on OBJECT | FIELD_DEFINITION | ENUM_VALUE | INPUT_FIELD_DEFINITION
type Query @tag(name: "q") { a(x: Int): Int @tag(name: "a") @deprecated(reason: "no") }
enum E { X @tag(name: "x") }
input I { f: Int @tag(name: "f") }')!
	plain := print_schema(schema)
	assert !plain.contains('@tag(name: "')
	with := print_schema_with(schema, applied_directives: true)
	assert with.contains('type Query @tag(name: "q") {\n  a(x: Int): Int @deprecated(reason: "no") @tag(name: "a")\n}')
	assert with.contains('enum E {\n  X @tag(name: "x")\n}')
	assert with.contains('input I {\n  f: Int @tag(name: "f")\n}')
	// and it reads back the same
	assert print_schema_with(build_schema(with)!, applied_directives: true) == with
}

// The limits on depth and size: they count through inline fragments and
// named ones, each spread of a fragment again, and a validation error stops the
// request before it runs.
fn test_depth_and_size_limits() {
	mut s := library()!
	s.validation = ValidateOptions{
		max_depth:      3
		max_selections: 6
	}
	ok := s.execute(Request{
		query: '{ books { author { name } } }'
	}, context.background())
	assert ok.errors.len == 0
	deep := s.execute(Request{
		query: 'query Deep { books { author { books { title } } } }'
	}, context.background())
	assert deep.request_error
	assert deep.errors.map(it.message) == [
		'Operation "Deep" is nested 4 levels deep, more than the limit of 3.',
	]
	// an inline fragment and a named one add no level of their own
	via := s.execute(Request{
		query: '{ books { ... on Book { author { ...A } } } } fragment A on Author { books { id } }'
	}, context.background())
	assert via.errors.map(it.message) == [
		'Operation is nested 4 levels deep, more than the limit of 3.',
	]
	// each spread counts the fragment's fields again
	wide := s.execute(Request{
		query: '{ a: books { ...F } b: books { ...F } } fragment F on Book { id title genre }'
	}, context.background())
	assert wide.errors.map(it.message) == [
		'Operation selects 8 fields, more than the limit of 6.',
	]
	// a fragment cycle is counted once, and reported by its own rule
	cycle := s.execute(Request{
		query: '{ books { author { ...X } } } fragment X on Author { books { author { ...X } } }'
	}, context.background())
	assert cycle.errors.any(it.message.contains('Cannot spread fragment "X" within itself'))
}

const inputs_sdl = '
enum Genre { SCIFI FANTASY }
input Filter { genre: Genre, title: String = "any", ids: [ID!], min: Int! }
input One @oneOf { a: Int, b: String }
type Query {
  find(f: Filter): String!
  one(o: One): String!
  many(ids: [Int!]): String!
}
'

fn inputs() !&Server {
	mut s := Server.new(inputs_sdl)!
	for field in ['find', 'one', 'many'] {
		s.resolve_each('Query', field, fn (_ context.Context, info FieldInfo, _ Source) !Resolved {
			return Value(Value(info.args.clone()).json())
		})
	}
	return s
}

// run_vars executes `query` with `variables`, and returns its data or its
// errors' messages, as JSON.
fn run_vars(s &Server, query string, variables map[string]Value) string {
	r := s.execute(Request{
		query:     query
		variables: variables
	}, context.background())
	if r.errors.len > 0 {
		return r.errors.map(it.message).join('\n')
	}
	return (r.data or { null }).json()
}

// Variables are coerced as graphql-js coerces them: input objects with
// defaults and required fields, lists (a single value becomes a list of one),
// enums, scalars and `@oneOf` inputs, each problem with its path.
fn test_variables_are_coerced() {
	s := inputs()!
	mut got := []string{}
	find := 'query (\$f: Filter) { find(f: \$f) }'
	got << run_vars(s, find, {
		'f': Value({
			'genre': Value('SCIFI')
			'ids':   '7'
			'min':   1
		})
	})
	got << run_vars(s, find, {
		'f': Value({
			'genre': Value(1)
			'ids':   Value([Value('1'), null])
			'mni':   1
		})
	})
	got << run_vars(s, find, {
		'f': Value('x')
	})
	got << run_vars(s, 'query (\$o: One) { one(o: \$o) }', {
		'o': Value({
			'a': Value(1)
			'b': 'x'
		})
	})
	got << run_vars(s, 'query (\$o: One) { one(o: \$o) }', {
		'o': Value({
			'a': null
		})
	})
	got << run_vars(s, 'query (\$ids: [Int!] = [1, 2]) { many(ids: \$ids) }', map[string]Value{})
	got << run_vars(s, 'query (\$ids: [Int!]!) { many(ids: \$ids) }', map[string]Value{})
	got << run_vars(s, 'query (\$ids: [Int!]!) { many(ids: \$ids) }', {
		'ids': null
	})
	got << run_vars(s, 'query (\$ids: [Int!]) { many(ids: \$ids) }', {
		'ids': Value([Value('a'), Value(1.5)])
	})
	got << run_vars(s, 'query (\$q: Query) { many }', map[string]Value{})
	// the messages graphql-js 16.11.0 gives for the same requests
	assert got == [
		'{"find":"{\\"f\\":{\\"genre\\":\\"SCIFI\\",\\"title\\":\\"any\\",\\"ids\\":[\\"7\\"],\\"min\\":1}}"}',
		'Variable "\$f" got invalid value 1 at "f.genre"; Enum "Genre" cannot represent non-string value: 1.\nVariable "\$f" got invalid value null at "f.ids[1]"; Expected non-nullable type "ID!" not to be null.\nVariable "\$f" got invalid value { genre: 1, ids: ["1", null], mni: 1 }; Field "min" of required type "Int!" was not provided.\nVariable "\$f" got invalid value { genre: 1, ids: ["1", null], mni: 1 }; Field "mni" is not defined by type "Filter". Did you mean "min"?',
		'Variable "\$f" got invalid value "x"; Expected type "Filter" to be an object.',
		'Variable "\$o" got invalid value { a: 1, b: "x" }; Exactly one key must be specified for OneOf type "One".',
		'Variable "\$o" got invalid value null at "o.a"; Field "a" must be non-null.',
		'{"many":"{\\"ids\\":[1,2]}"}',
		'Variable "\$ids" of required type "[Int!]!" was not provided.',
		'Variable "\$ids" of non-null type "[Int!]!" must not be null.',
		'Variable "\$ids" got invalid value "a" at "ids[0]"; Int cannot represent non-integer value: "a"\nVariable "\$ids" got invalid value 1.5 at "ids[1]"; Int cannot represent non-integer value: 1.5',
		'Variable "\$q" cannot be non-input type "Query".\nVariable "\$q" is never used.',
	]
}
