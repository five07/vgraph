module graphql

fn schema_errors(sdl string) []string {
	s := build_schema(sdl) or { return ['build: ${err.msg()}'] }
	return validate_schema(s).map(it.message)
}

fn test_valid_schema() {
	assert schema_errors('type Query { a: Int }') == []
}

fn test_schema_problems() {
	assert schema_errors('type Mutation { a: Int }') == ['Query root type must be provided.']
	assert schema_errors('schema { query: Q } scalar Q') == [
		'Query root type must be Object type, it cannot be Q.',
	]
	assert schema_errors('type Query { a: In }') == ['build: Unknown type "In". Did you mean "ID" or "Int"?']
	assert schema_errors('
		type Query { a: Node }
		interface Node { id: ID! name(x: Int): String }
		type A implements Node { id: String }') == [
		'Interface field Node.id expects type ID! but A.id is type String.',
		'Interface field Node.name expected but A does not provide it.',
	]
	assert schema_errors('
		type Query { a(f: In): Int }
		input In { self: In! other: Int }') == [
		'Cannot reference Input Object "In" within itself through a series of non-null fields: "self".',
	]
	assert schema_errors('type Query { __a: Int }') == [
		'Name "__a" must not begin with "__", which is reserved by GraphQL introspection.',
	]
	assert schema_errors('
		type Query { a(c: Choice): Int }
		input Choice @oneOf { x: Int! y: Int = 1 }') == [
		'OneOf input field Choice.x must be nullable.',
		'OneOf input field Choice.y cannot have a default value.',
	]
}

// Each problem `validate_schema` reports, with graphql-js 16.11.0's message for
// the same SDL.
fn test_every_schema_problem() {
	for sdl, want in {
		'schema { query: Query mutation: M } type Query { a: Int } scalar M':                            ['Mutation root type must be Object type if provided, it cannot be M.']
		'schema { query: Query subscription: S } type Query { a: Int } scalar S':                        ['Subscription root type must be Object type if provided, it cannot be S.']
		'directive @d(a: Query) on FIELD type Query { a: Int }':                                         ['The type of @d(a:) must be Input Type but got: Query.']
		'directive @d(a: Int! @deprecated) on FIELD type Query { a: Int }':                              ['Required argument @d(a:) cannot be deprecated.']
		'type Query { a: E } enum E':                                                                    ['Enum type E must define one or more values.']
		'type Query { a: T } type T':                                                                    ['Type T must define one or more fields.']
		'type Query { a: In } input In { x: Int }':                                                      ['The type of Query.a must be Output Type but got: In.']
		'type Query { a(x: Query): Int }':                                                               ['The type of Query.a(x:) must be Input Type but got: Query.']
		'type Query { a(x: Int! @deprecated): Int }':                                                    ['Required argument Query.a(x:) cannot be deprecated.']
		'type Query implements Q2 { a: Int } type Q2 { a: Int }':                                        ['Type Query must only implement Interface types, it cannot implement Q2.']
		'type Query { i: I } interface I implements I { a: Int }':                                       ['Type I cannot implement itself because it would create a circular reference.']
		'type Query implements I & I { a: Int } interface I { a: Int }':                                 ['Type Query can only implement I once.']
		'type Query implements A { a: Int } interface A implements B { a: Int } interface B { a: Int }': ['Type Query must implement B because it is implemented by A.']
		'type Query implements I { f: Int } interface I { f(x: Int): Int }':                             ['Interface field argument I.f(x:) expected but Query.f does not provide it.']
		'type Query implements I { f(x: String): Int } interface I { f(x: Int): Int }':                  ['Interface field argument I.f(x:) expects type Int but Query.f(x:) is type String.']
		'type Query implements I { f(x: Int, y: Int!): Int } interface I { f(x: Int): Int }':            ['Object field Query.f includes required argument y that is missing from the Interface field I.f.']
		'type Query { u: U } union U':                                                                   ['Union type U must define one or more member types.']
		'type Query { u: U } union U = Query | Query':                                                   ['Union type U can only include type Query once.']
		'type Query { u: U } union U = I interface I { a: Int }':                                        ['Union type U can only include Object types, it cannot include I.']
		'type Query { a(x: In): Int } input In':                                                         ['Input Object type In must define one or more fields.']
		'type Query { a(x: In): Int } input In { x: Query }':                                            ['The type of In.x must be Input Type but got: Query.']
		'type Query { a(x: In): Int } input In { x: Int! @deprecated }':                                 ['Required input field In.x cannot be deprecated.']
	} {
		assert schema_errors(sdl) == want, sdl
	}
}
