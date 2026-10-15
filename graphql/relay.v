module graphql

import context

// Relay connections: https://relay.dev/graphql/connections.htm. A resolver
// returns a `Connection`, and `Server.connection` resolves its fields.

// Connection is a page of a list: its edges, where it is in the list, and the
// list's length.
pub struct Connection {
pub:
	edges       []ConnectionEdge
	page_info   PageInfo
	total_count int
}

// ConnectionEdge is an item of a page, and its cursor.
pub struct ConnectionEdge {
pub:
	node   Source
	cursor string
}

// PageInfo says whether there are items before and after a page, and the
// cursors of its first and last items.
pub struct PageInfo {
pub:
	has_next_page     bool
	has_previous_page bool
	start_cursor      ?string
	end_cursor        ?string
}

// connection returns the page of `nodes`, whose cursors are `cursors`.
pub fn connection(nodes []Source, cursors []string, has_next bool, has_previous bool, total int) Connection {
	mut edges := []ConnectionEdge{cap: nodes.len}
	for i, node in nodes {
		edges << ConnectionEdge{
			node:   node
			cursor: cursors[i] or { '' }
		}
	}
	return Connection{
		edges:       edges
		page_info:   PageInfo{
			has_next_page:     has_next
			has_previous_page: has_previous
			start_cursor:      if edges.len > 0 { edges[0].cursor } else { none }
			end_cursor:        if edges.len > 0 { edges.last().cursor } else { none }
		}
		total_count: total
	}
}

// PageArgs are a connection's arguments: `first` and `after` to page forwards,
// `last` and `before` to page backwards.
pub struct PageArgs {
pub:
	first  ?int
	after  ?string
	last   ?int
	before ?string
}

// PageSize bounds the pages of a list or a connection. A request that asks
// for no size gets `default_size` items, or `max_size` when there is no
// default, and one that asks for more than `max_size` is an error. 0 is no
// bound.
@[params]
pub struct PageSize {
pub:
	default_size int
	max_size     int
}

// check reports a bound below zero, or a default past the maximum.
pub fn (s PageSize) check() ! {
	if s.default_size < 0 || s.max_size < 0 {
		return error('a page size cannot be less than zero')
	}
	if s.max_size > 0 && s.default_size > s.max_size {
		return error('the default page size, ${s.default_size}, is more than the maximum, ${s.max_size}')
	}
}

// fallback returns the size of a page a request gives no size for, or none
// when the page is unbounded.
fn (s PageSize) fallback() ?int {
	if s.default_size > 0 {
		return s.default_size
	}
	if s.max_size > 0 {
		return s.max_size
	}
	return none
}

// page_args reads a connection's arguments, and refuses `first` and `last`
// together, or below zero, as entgql does, or past `size.max_size`. With
// neither, the page is `first: size.default_size` (or `max_size`).
pub fn page_args(args map[string]Value, size PageSize) !PageArgs {
	mut first := int_arg(args, 'first')
	last := int_arg(args, 'last')
	if first != none && last != none {
		return error('Passing both `first` and `last` to paginate a connection is not supported.')
	}
	if n := first {
		check_size('`first` on a connection', n, size)!
	}
	if n := last {
		check_size('`last` on a connection', n, size)!
	}
	if first == none && last == none {
		first = size.fallback()
	}
	return PageArgs{
		first:  first
		after:  string_arg(args, 'after')
		last:   last
		before: string_arg(args, 'before')
	}
}

// ListArgs are a plain list's arguments: at most `limit` items, after
// skipping `offset`.
pub struct ListArgs {
pub:
	limit  ?int
	offset ?int
}

// list_args reads a list's `limit` and `offset`, and refuses either below
// zero, or a `limit` past `size.max_size`. Without one, the limit is
// `size.default_size` (or `max_size`).
pub fn list_args(args map[string]Value, size PageSize) !ListArgs {
	mut limit := int_arg(args, 'limit')
	offset := int_arg(args, 'offset')
	if n := limit {
		check_size('`limit` on a list', n, size)!
	} else {
		limit = size.fallback()
	}
	if n := offset {
		if n < 0 {
			return error('`offset` on a list cannot be less than zero.')
		}
	}
	return ListArgs{
		limit:  limit
		offset: offset
	}
}

// check_size refuses `n`, the size `what` asks for, below zero or past
// `size.max_size`.
fn check_size(what string, n int, size PageSize) ! {
	if n < 0 {
		return error('${what} cannot be less than zero.')
	}
	if size.max_size > 0 && n > size.max_size {
		return error('${what} cannot be more than ${size.max_size}.')
	}
}

fn int_arg(args map[string]Value, name string) ?int {
	v := args[name] or { return none }
	return if v is int { v } else { none }
}

fn string_arg(args map[string]Value, name string) ?string {
	v := args[name] or { return none }
	return if v is string { v } else { none }
}

// connection registers the resolvers of the connection type `connection_type`
// and its edge type `edge_type`, whose resolvers return `Connection` values,
// and of `PageInfo`.
pub fn (mut s Server) connection(connection_type string, edge_type string) {
	s.resolve(connection_type, 'edges', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(list((it as Connection).edges.map(obj(it))))
	})
	s.resolve(connection_type, 'pageInfo', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(page_info_value((it as Connection).page_info)))
	})
	s.resolve(connection_type, 'totalCount', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(Value((it as Connection).total_count)))
	})
	s.resolve(edge_type, 'node', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(obj((it as ConnectionEdge).node))
	})
	s.resolve(edge_type, 'cursor', fn (_ context.Context, _ FieldInfo, parents []Source) ![]Resolved {
		return parents.map(Resolved(Value((it as ConnectionEdge).cursor)))
	})
}

// page_info_value returns a `PageInfo` as an object value, whose fields
// resolve by key.
fn page_info_value(p PageInfo) Value {
	return Value({
		'hasNextPage':     Value(p.has_next_page)
		'hasPreviousPage': Value(p.has_previous_page)
		'startCursor':     if c := p.start_cursor { Value(c) } else { null }
		'endCursor':       if c := p.end_cursor { Value(c) } else { null }
	})
}

// cursor_scalar checks Cursor values: strings.
pub const cursor_scalar = Scalar{
	parse_value:   fn (v Value) !Value {
		if v !is string {
			return error('Cursor must be a string')
		}
		return v
	}
	parse_literal: fn (node ValueNode, _ map[string]Value) !Value {
		if node is StringValue {
			return Value(node.value)
		}
		return error('Cursor must be a string')
	}
}
