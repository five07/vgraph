module gen

import strings

// Telemetry: the operations of a model whose level isn't `none` each get a
// span. Each one's method keeps its body as `<name>_untraced`, and a wrapper
// of its name starts the span, runs the body with a client whose context holds
// the span, records a failure or how many rows it returned, and ends the span.
// A `none` model's code is left as it was.

// Traced is an operation that gets a span: the method `method` of `typ`, its
// span `name` and operation `op`.
struct Traced {
	typ    string
	method string
	name   string
	op     string
	// group: `typ` is a group-by builder, which holds its query, not a graph
	group bool
	// edge: the method loads this edge
	edge string
}

// level_of returns the level of `info`'s model, as the generated code names it.
fn level_of(info Info) string {
	return if info.table.otel.level in ['ops', 'full', 'default'] {
		info.table.otel.level
	} else {
		'none'
	}
}

// traced_ops returns the operations of `info`'s table that get a span.
fn traced_ops(info Info) []Traced {
	t := info.table
	q := info.query()
	mut ops := []Traced{}
	for method in ['all', 'count', 'ids', 'scan'] {
		ops << Traced{
			typ:    q
			method: method
			name:   'query ${t.name}'
			op:     method
		}
	}
	ops << Traced{
		typ:    '${info.entity.struct_name}GroupBy'
		method: 'all'
		name:   'query ${t.name}'
		op:     'group_by'
		group:  true
	}
	for e in t.edges {
		ops << Traced{
			typ:    q
			method: 'load_${e.name}'
			name:   'load ${t.name}.${e.name}'
			op:     'load'
			edge:   e.name
		}
	}
	if !t.view {
		for typ, op in {
			info.create():      'create'
			info.create_bulk(): 'create_bulk'
			info.update_one():  'update_one'
			info.update():      'update'
			info.delete_one():  'delete_one'
			info.delete():      'delete'
		} {
			verb := op.all_before('_')
			for method in ['save', 'exec'] {
				ops << Traced{
					typ:    typ
					method: method
					name:   '${verb} ${t.name}'
					op:     op
				}
			}
		}
	}
	return ops
}

// instrument returns `text`, generated code of `info`'s table, with a span
// around each of its operations (`traced_ops`), and its aggregates, when the
// model's level isn't `none`.
fn instrument(text string, info Info) string {
	level := level_of(info)
	if level == 'none' {
		return text
	}
	mut ops := traced_ops(info)
	lines := text.split('\n')
	mut b := strings.new_builder(text.len + 4096)
	mut i := 0
	for i < lines.len {
		line := lines[i]
		sig := parse_signature(line) or {
			b.writeln(line)
			i++
			continue
		}
		recv := sig.recv
		typ := sig.typ
		method := sig.method
		mut op := Traced{}
		mut found := false
		for o in ops {
			if o.typ == typ && o.method == method {
				op = o
				found = true
				break
			}
		}
		// the aggregates of a query: `sum_views`, `max_id`
		if !found && typ == info.query() && method.all_before('_') in ['sum', 'min', 'max', 'mean']
			&& method.contains('_') {
			op = Traced{
				typ:    typ
				method: method
				name:   'query ${info.table.name}'
				op:     method.all_before('_')
			}
			found = true
		}
		if !found {
			b.writeln(line)
			i++
			continue
		}
		// the body, to the closing brace at the start of a line
		mut end := i + 1
		for end < lines.len && lines[end] != '}' {
			end++
		}
		mut body := lines[i + 1..end].join('\n')
		if method == 'save' {
			// a save that runs its own exec runs it inside its span
			body = body.replace('${recv}.exec()', '${recv}.exec_untraced()')
		}
		generic := sig.generic
		params := sig.params
		ret := sig.ret
		b.writeln(wrapper(level, sig.vis, recv, typ, method, generic, params, ret, op, info))
		b.writeln('')
		b.writeln('// ${method}_untraced is `${method}`, without its span.')
		b.writeln('fn (${recv} ${typ}) ${method}_untraced${generic}(${params}) ${ret} {')
		b.writeln(body)
		b.writeln('}')
		i = end + 1
	}
	return b.str().trim_right('\n') + '\n'
}

// wrapper returns the method that runs `<method>_untraced` in the span of `op`.
fn wrapper(level string, vis string, recv string, typ string, method string, generic string, params string, ret string, op Traced, info Info) string {
	client := if op.group { '${recv}.query.graph.client' } else { '${recv}.graph.client' }
	start := if op.edge != '' {
		"${client}.start_load_span(.${level}, '${info.table.name}', '${op.edge}', rows.len)"
	} else {
		"${client}.start_span(.${level}, '${op.name}', '${info.table.name}', '${op.op}')"
	}
	traced := if op.group {
		'${typ}{\n\t\t...${recv}\n\t\tquery: ${info.query()}{\n\t\t\t...${recv}.query\n\t\t\tgraph: Graph{\n\t\t\t\tclient: client\n\t\t\t}\n\t\t}\n\t}'
	} else {
		'${typ}{\n\t\t...${recv}\n\t\tgraph: Graph{\n\t\t\tclient: client\n\t\t}\n\t}'
	}
	args := params.split(', ').filter(it != '').map(it.all_before(' ')).join(', ')
	call := '${traced}.${method}_untraced${generic}(${args})'
	mut b := strings.new_builder(512)
	b.writeln('${vis}fn (${recv} ${typ}) ${method}${generic}(${params}) ${ret} {')
	b.writeln('\tclient, span := ${start}')
	b.writeln('\tdefer {')
	b.writeln('\t\tspan.end()')
	b.writeln('\t}')
	fail := ' or {\n\t\tvgraph.span_failed(span, err)\n\t\treturn err\n\t}'
	if ret == '!' {
		b.writeln('\t${call}${fail}')
	} else {
		b.writeln('\tresult := ${call}${fail}')
		if ret.starts_with('![]') {
			b.writeln('\tvgraph.span_rows(span, result.len)')
		} else if ret == '!int' {
			b.writeln('\tvgraph.span_rows(span, result)')
		}
		b.writeln('\treturn result')
	}
	b.write_string('}')
	return b.str()
}

// Signature is a method's first line, as the generator writes it:
// `pub fn (q ArticleQuery) all() ![]ArticleNode {`.
struct Signature {
	vis     string // `pub ` or ''
	recv    string
	typ     string
	method  string
	generic string // `[T]` or ''
	params  string
	ret     string // a result: `!`, `!int`, `![]ArticleNode`
}

// parse_signature reads a method's first line, or returns none for any other
// line, and for a method that returns no result.
fn parse_signature(line string) ?Signature {
	vis := if line.starts_with('pub fn (') { 'pub ' } else { '' }
	if !line.starts_with('${vis}fn (') || !line.ends_with(' {') {
		return none
	}
	rest := line[vis.len + 4..]
	recv_end := rest.index(')') or { return none }
	receiver := rest[..recv_end].split(' ')
	if receiver.len != 2 {
		return none
	}
	after := rest[recv_end + 2..]
	name_end := after.index_any('([')
	if name_end <= 0 {
		return none
	}
	method := after[..name_end]
	mut j := name_end
	mut generic := ''
	if after[j..].starts_with('[T]') {
		generic = '[T]'
		j += 3
	}
	if j >= after.len || after[j] != `(` {
		return none
	}
	// the parameters, to their closing parenthesis: a parameter's type can
	// have parentheses of its own, such as `fn (UserQuery) UserQuery`
	mut depth := 0
	mut close := -1
	for k := j; k < after.len; k++ {
		if after[k] == `(` {
			depth++
		} else if after[k] == `)` {
			depth--
			if depth == 0 {
				close = k
				break
			}
		}
	}
	if close < 0 {
		return none
	}
	// a result follows the parameters, after a space: `) ![]ArticleNode {`
	if close + 2 >= after.len - 2 {
		return none
	}
	ret := after[close + 2..after.len - 2]
	if !ret.starts_with('!') {
		return none
	}
	return Signature{
		vis:     vis
		recv:    receiver[0]
		typ:     receiver[1]
		method:  method
		generic: generic
		params:  after[j + 1..close]
		ret:     ret
	}
}
