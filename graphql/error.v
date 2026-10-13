module graphql

// GraphQLError is an error in a response's `errors`: a message, the places in the
// document it refers to, and for an error raised while executing, the path of the
// field in the response.
pub struct GraphQLError {
	Error
pub:
	message    string
	locations  []Location
	path       []PathItem
	extensions map[string]Value
}

// msg returns the error's message.
pub fn (e GraphQLError) msg() string {
	return e.message
}

// PathItem is one step of a path in a response: a field's response name, or an
// index in a list.
pub type PathItem = int | string

// syntax_error returns the error for a document that can't be parsed, at the
// byte offset `pos` of `body`.
fn syntax_error(body string, pos int, description string) GraphQLError {
	return GraphQLError{
		message:   'Syntax Error: ${description}'
		locations: [location_of(body, pos)]
	}
}

// to_value returns the error as it appears in a response's `errors`.
pub fn (e GraphQLError) to_value() Value {
	mut out := map[string]Value{}
	out['message'] = e.message
	if e.locations.len > 0 {
		out['locations'] = Value(e.locations.map(Value({
			'line':   Value(it.line)
			'column': Value(it.column)
		})))
	}
	if e.path.len > 0 {
		out['path'] = Value(e.path.map(match it {
			int { Value(it) }
			string { Value(it) }
		}))
	}
	if e.extensions.len > 0 {
		out['extensions'] = Value(e.extensions)
	}
	return Value(out)
}
