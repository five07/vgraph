module graphql

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
	s.resolve('Query', 'books', fn [books] (_ Context, info FieldInfo, parents []Source) ![]Resolved {
		genre := info.arg('genre')
		found := books.filter(genre is Null || Value(it.genre) == genre).map(obj(it))
		return parents.map(list(found))
	})
	s.resolve('Query', 'hello', fn (_ Context, info FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(Value('hello ${info.arg('name')}')))
	})
	s.resolve('Query', 'broken', fn (_ Context, _ FieldInfo, parents []Source) ![]Resolved {
		return error('it broke')
	})
	s.resolve_each('Book', 'id', fn (_ Context, _ FieldInfo, parent Source) !Resolved {
		return Value((parent as Book).id)
	})
	s.resolve_each('Book', 'title', fn (_ Context, _ FieldInfo, parent Source) !Resolved {
		return Value((parent as Book).title)
	})
	s.resolve_each('Book', 'genre', fn (_ Context, _ FieldInfo, parent Source) !Resolved {
		return Value((parent as Book).genre)
	})
	// one call for every book at a level: the batching the executor promises
	s.resolve('Book', 'author', fn (_ Context, _ FieldInfo, parents []Source) ![]Resolved {
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
	}, unsafe { nil })
	assert r.errors.len == 0, r.json()
	assert r.json() == '{"data":{"scifi":[{"id":"1","title":"Dune","genre":"SCIFI"},{"id":"3","title":"Children of Dune","genre":"SCIFI"}],"all":[{"title":"Dune","author":{"name":"Herbert"}},{"title":"Hobbit","author":{"name":"Tolkien"}},{"title":"Children of Dune","author":{"name":"Herbert"}}],"hello":"hello world","other":"hello you","__typename":"Query"}}'
}

fn test_errors_null_the_nearest_nullable_field() {
	mut s := library()!
	r := s.execute(Request{
		query: '{ hello broken }'
	}, unsafe { nil })
	assert r.json() == '{"errors":[{"message":"it broke","locations":[{"line":1,"column":9}],"path":["broken"]}],"data":null}'
}

fn test_request_errors() {
	mut s := library()!
	assert s.execute(Request{
		query: '{ nope }'
	}, unsafe { nil }).json() == '{"errors":[{"message":"Cannot query field \\"nope\\" on type \\"Query\\".","locations":[{"line":1,"column":3}]}]}'
	assert s.execute(Request{
		query: '{'
	}, unsafe { nil }).json() == '{"errors":[{"message":"Syntax Error: Expected Name, found <EOF>.","locations":[{"line":1,"column":2}]}]}'
	r := s.execute(Request{
		query:     'query ($g: Genre) { books(genre: $g) { id } }'
		variables: {
			'g': Value('HORROR')
		}
	}, unsafe { nil })
	assert r.request_error
	assert r.errors[0].message == 'Variable "\$g" got invalid value "HORROR"; Value "HORROR" does not exist in "Genre" enum.'
}

fn test_introspection() {
	mut s := library()!
	r := s.execute(Request{
		query: '{ __type(name: "Book") { name kind fields { name type { kind name ofType { name } } } } }'
	}, unsafe { nil })
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
		}, unsafe { nil })
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

fn (mut t MemoryTx) begin() ! {
	t.calls.log << 'begin'
}

fn (mut t MemoryTx) commit() ! {
	t.calls.log << 'commit'
}

fn (mut t MemoryTx) rollback() ! {
	t.calls.log << 'rollback'
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
	s.resolve('Query', 'animals', fn [animals] (_ Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(Value(animals)))
	})
	s.resolve('Query', 'pets', fn [animals] (_ Context, _ FieldInfo, parents []Source) ![]Resolved {
		// a null item in a nullable list, and an object of no type at all
		return parents.map(list([Resolved(animals[0]), null, obj(map[string]Value{})]))
	})
	s.resolve('Query', 'count', fn (_ Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(null))
	})
	s.resolve('Query', 'numbers', fn (_ Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(Value([Value(1), null, Value(3)])))
	})
	s.resolve('Query', 'big', fn (_ Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(Value(f64(1e10))))
	})
	s.resolve('Animal', 'name', fn (_ Context, _ FieldInfo, parents []Source) ![]Resolved {
		return error('never called: fields resolve on object types')
	})
	// count the calls per field: each must be called once per level
	for t in ['Dog', 'Cat'] {
		s.resolve(t, 'name', fn [mut calls, t] (_ Context, _ FieldInfo, parents []Source) ![]Resolved {
			calls.counts['${t}.name']++
			return parents.map(Resolved((it as map[string]Value)['name'] or { null }))
		})
	}
	s.resolve('Mutation', 'add', fn [mut calls] (_ Context, info FieldInfo, parents []Source) ![]Resolved {
		calls.names << info.arg('name').as_string()
		return parents.map(Resolved(Value(calls.names.len)))
	})
	s.resolve('Mutation', 'fail', fn (_ Context, _ FieldInfo, parents []Source) ![]Resolved {
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
	}, unsafe { nil })
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
	}, unsafe { nil })
	assert r.json() == '{"errors":[{"message":"Cannot return null for non-nullable field Query.numbers.","locations":[{"line":1,"column":3}],"path":["numbers",1]},{"message":"Abstract type \\"Pet\\" must resolve to an Object type at runtime for field \\"Query.pets\\". Either the \\"Pet\\" type should provide a \\"resolveType\\" function or each possible type should provide an \\"isTypeOf\\" function.","locations":[{"line":1,"column":11}],"path":["pets",2]}],"data":{"numbers":null,"pets":[{"name":"rex"},null,null]}}'
	whole := s.execute(Request{
		query: '{ count }'
	}, unsafe { nil })
	assert whole.json() == '{"errors":[{"message":"Cannot return null for non-nullable field Query.count.","locations":[{"line":1,"column":3}],"path":["count"]}],"data":null}'
	assert s.execute(Request{
		query: '{ big }'
	}, unsafe { nil }).errors[0].message == 'Int cannot represent non 32-bit signed integer value: 10000000000'
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
	}, unsafe { nil })
	assert r.json() == '{"data":{"animals":[{"barks":true},{}]}}'
	assert s.execute(Request{
		query: query
	}, unsafe { nil }).errors[0].message == 'Must provide operation name if query contains multiple operations.'
	assert s.execute(Request{
		query:          query
		operation_name: 'C'
	}, unsafe { nil }).errors[0].message == 'Unknown operation named "C".'
}

fn test_mutations_run_in_order_in_a_transaction() {
	mut calls := &Calls{}
	mut s := zoo(mut calls)!
	r := s.execute(Request{
		query: 'mutation { a: add(name: "x") b: add(name: "y") }'
	}, unsafe { nil })
	assert r.json() == '{"data":{"a":1,"b":2}}'
	assert calls.names == ['x', 'y']
	assert calls.log == ['begin', 'commit']
	failed := s.execute(Request{
		query: 'mutation { a: add(name: "z") fail }'
	}, unsafe { nil })
	assert failed.errors.map(it.message) == ['no']
	assert calls.log == ['begin', 'commit', 'begin', 'rollback']
}

fn test_http() {
	mut calls := &Calls{}
	mut s := zoo(mut calls)!
	ok := s.handle(HttpRequest{
		method:       'POST'
		content_type: 'application/json'
		body:         '{"query": "query (\$n: Boolean!) { __typename @include(if: \$n) }", "variables": {"n": true}}'
	}, unsafe { nil })
	assert ok.status == 200
	assert ok.content_type == 'application/json; charset=utf-8'
	assert ok.body == '{"data":{"__typename":"Query"}}'
	invalid := s.handle(HttpRequest{
		method:       'POST'
		content_type: 'application/json'
		accept:       'application/graphql-response+json'
		body:         '{"query": "{ nope }"}'
	}, unsafe { nil })
	assert invalid.status == 400
	assert invalid.content_type == 'application/graphql-response+json; charset=utf-8'
	get := s.handle(HttpRequest{
		method:       'GET'
		query_string: 'query=%7B%20__typename%20%7D'
	}, unsafe { nil })
	assert get.body == '{"data":{"__typename":"Query"}}'
	mutation := s.handle(HttpRequest{
		method:       'GET'
		query_string: 'query=mutation%20%7B%20fail%20%7D'
	}, unsafe { nil })
	assert mutation.status == 405
	assert mutation.headers['Allow'] == 'POST'
	assert s.handle(HttpRequest{
		method:       'POST'
		content_type: 'text/plain'
		body:         '{}'
	}, unsafe { nil }).status == 415
	assert s.handle(HttpRequest{
		method:       'POST'
		content_type: 'application/json'
		body:         '{"query": 1}'
	}, unsafe { nil }).body == '{"errors":[{"message":"The request must have a \\"query\\" string."}]}'
}
