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
