module gen

import strings

// describe returns `tables` as text, as `ent describe` does: each table's
// columns, edges and indexes, and how many hooks, interceptors and privacy
// rules its model declares.
pub fn describe(entities []Entity, tables []Table) string {
	mut b := strings.new_builder(4096)
	for t in tables {
		struct_name := t.struct_.all_after_last('.')
		kind := if t.view { ' (view)' } else { '' }
		b.writeln('${struct_name} (${t.name})${kind}:')
		mut rows := [['Column', 'Type', 'Null', 'Key', 'Options']]
		for c in t.columns {
			typ := if c.type_name != '' { '${c.type_name} (${c.base()})' } else { c.base() }
			rows << [c.name, typ, yes(c.nullable), if c.name == t.key { 'yes' } else { '' },
				column_options(c)]
		}
		write_rows(mut b, rows)
		if t.edges.len > 0 {
			mut edges := [['Edge', 'Kind', 'To', 'Column', 'Through', 'Options']]
			for e in t.edges {
				through := if e.through != '' { '${e.through}.${e.through_to}' } else { '' }
				edges << [e.name, e.kind, e.to, e.column, through, edge_options(e)]
			}
			write_rows(mut b, edges)
		}
		if t.indexes.len > 0 {
			mut indexes := [['Index', 'Columns', 'Unique', 'Where']]
			for i in t.indexes {
				name := if i.name != '' { i.name } else { '${t.name}_${i.columns.join('_')}_idx' }
				indexes << [name, i.columns.join(', '), yes(i.unique), i.where]
			}
			write_rows(mut b, indexes)
		}
		b.writeln('\thooks: ${t.hooks}, interceptors: ${t.interceptors}, policy rules: ${t.rules}')
		b.writeln('')
	}
	return b.str()
}

fn yes(v bool) string {
	return if v { 'yes' } else { '' }
}

fn column_options(c Column) string {
	mut out := []string{}
	if c.serial {
		out << 'serial'
	}
	if c.unique {
		out << 'unique'
	}
	if c.immutable {
		out << 'immutable'
	}
	if c.sensitive {
		out << 'sensitive'
	}
	if c.has_default {
		out << 'default'
	}
	if c.auto_update {
		out << 'update default'
	}
	if c.optional && !c.nullable && !c.serial && !c.has_default {
		out << 'optional'
	}
	if c.json_type != '' {
		out << 'json ${c.json_type}'
	}
	if c.enum_values.len > 0 {
		out << 'values ${c.enum_values.join('|')}'
	}
	if c.embedded != '' {
		out << 'from ${c.embedded}'
	}
	if c.graphql_skip && !c.sensitive {
		out << 'not in GraphQL'
	}
	return out.join(', ')
}

fn edge_options(e Edge) string {
	mut out := []string{}
	if e.type_col != '' {
		out << '${e.type_col} = ${e.type_val}'
	}
	if e.soft_del != '' {
		out << 'soft_del ${e.soft_del}'
	}
	if e.ref != '' {
		out << 'ref ${e.ref}'
	}
	if e.unique {
		out << 'unique'
	}
	if e.bidi {
		out << 'bidi'
	}
	if e.required {
		out << 'required'
	}
	if e.immutable {
		out << 'immutable'
	}
	return out.join(', ')
}

// write_rows writes `rows` as a table, the first row its header.
fn write_rows(mut b strings.Builder, rows [][]string) {
	mut widths := []int{len: rows[0].len}
	for row in rows {
		for i, cell in row {
			if cell.len > widths[i] {
				widths[i] = cell.len
			}
		}
	}
	line := '\t+' + widths.map('-'.repeat(it + 2)).join('+') + '+'
	b.writeln(line)
	for r, row in rows {
		mut cells := []string{}
		for i, cell in row {
			cells << ' ${cell}${' '.repeat(widths[i] - cell.len)} '
		}
		b.writeln('\t|' + cells.join('|') + '|')
		if r == 0 {
			b.writeln(line)
		}
	}
	b.writeln(line)
}
