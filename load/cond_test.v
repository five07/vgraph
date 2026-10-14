module load

import db.sqlite
import orm

// either is `load.or`, which this module can't call by name: `or` is a keyword
// when unqualified.
fn either(conds ...Cond) Cond {
	return Cond{
		junction: .or
		children: conds
	}
}

fn rendered(c Cond, dialect orm.SQLDialect) !(string, []string) {
	mut p := Params{
		dialect: dialect
	}
	text := render(normalize(c, false), mut p)!
	return text, p.values
}

fn test_not_is_pushed_to_the_comparisons() {
	c := normalize(not(and(eq('a', 1), either(lt('b', 2), in_ints('c', [3])))), false)
	assert c.junction == .or
	// NOT (a AND (b OR c)) is NOT a OR (NOT b AND NOT c)
	assert c.children.len == 2
	assert '${c.children[0].column} ${c.children[0].kind}' == 'a neq'
	assert c.children[1].junction == .and
	assert c.children[1].children.map('${it.column} ${it.kind}') == ['b ge', 'c not_in']
	// LIKE has no operator for its negation: it keeps a NOT
	like_not := normalize(not(like('d', 'x%')), false)
	assert like_not.kind == .orm_like && like_not.negate
	assert normalize(not(not(eq('a', 1))), false).kind == .eq
}

fn test_constants_fold() {
	// an empty IN matches no row: inside an OR, only that branch goes
	assert normalize(either(in_ints('a', []), eq('b', 1)), false).column == 'b'
	assert normalize(and(in_ints('a', []), eq('b', 1)), false).junction == .false
	assert normalize(and(not_in_ints('a', []), eq('b', 1)), false).column == 'b'
	assert normalize(not(in_ints('a', [])), false).junction == .true
	assert normalize(and(), false).junction == .true
	assert normalize(either(), false).junction == .false
}

fn test_the_orm_gets_parentheses() {
	data := orm_where(normalize(and(eq('a', 1), either(eq('b', 2), and(eq('c', 3), eq('d', 4)))),
		false))
	assert data.fields == ['a', 'b', 'c', 'd']
	assert data.is_and == [true, false, true]
	assert data.parentheses == [[2, 3], [1, 3]]
	assert !orm_ready(normalize(contains('a', 'x'), false))
	assert orm_ready(normalize(either(eq('a', 1), is_null('b')), false))
}

fn test_sql_for_each_dialect() {
	text, values := rendered(and(eq('n', 3), contains('t', '50%_off'), equal_fold('t', 'Ab'),
		not(has_prefix('t', 'x')), in_strings('s', ['a', 'b'])), .pg)!
	assert text == '("n" = \$1 AND "t" LIKE \$2 ESCAPE \'\\\' AND LOWER("t") = LOWER(\$3) AND NOT ("t" LIKE \$4 ESCAPE \'\\\') AND "s" IN (\$5, \$6))'
	assert values == ['3', '%50\\%\\_off%', 'Ab', 'x%', 'a', 'b']
	lite, lite_values := rendered(and(eq('n', 3), eq('ok', true), raw('length(t) > ?', 2)),
		.sqlite)!
	assert lite == '("n" = CAST(? AS INTEGER) AND "ok" = CAST(? AS INTEGER) AND (length(t) > CAST(? AS INTEGER)))'
	assert lite_values == ['3', '1', '2']
	sub, _ := rendered(not(in_sub('id', Sub{
		table:  'pets'
		column: 'owner_id'
		kind:   .int
		conds:  [eq('name', 'rex')]
	})), .sqlite)!
	assert sub == 'NOT ("id" IN (SELECT "owner_id" FROM "pets" WHERE ("name" = ? AND "owner_id" IS NOT NULL)))'
	rendered(raw('a = ? AND b = ?', 1), .pg) or {
		assert err.msg().contains('more `?` than arguments')
		return
	}
	assert false
}

@[table: 'items']
struct Item {
	id    int @[primary; sql: serial]
	name  string
	owner ?int
}

fn test_without_a_driver() {
	db := sqlite.connect(':memory:')!
	sql db {
		create table Item
	}!
	for name in ['a_b', 'ab', 'c'] {
		item := Item{
			name:  name
			owner: if name == 'c' { ?int(none) } else { ?int(1) }
		}
		sql db {
			insert item into Item
		}!
	}
	// OR and NOT run through the ORM
	rows := select_where[Item](db, Query{
		conds: [either(eq('name', 'c'), not(eq('id', 1)))]
		order: 'id'
	})!
	assert rows.map(it.name) == ['ab', 'c']
	// a subquery runs first
	sub := in_sub('id', Sub{
		table:  'items'
		column: 'id'
		kind:   .int
		conds:  [is_null('owner')]
	})
	assert select_where[Item](db, Query{ conds: [sub] })!.map(it.name) == ['c']
	// an escape is dropped when the value needs none; refused when it does
	assert select_where[Item](db, Query{ conds: [has_prefix('name', 'a')] })!.len == 2
	if _ := select_where[Item](db, Query{ conds: [contains('name', '_')] }) {
		assert false
	} else {
		assert err.msg().contains('vgraph driver')
	}
	// aggregates, and keys
	assert count_where[Item](db, Query{ conds: [like('name', 'a%')] })! == 2
	assert aggregate_where(db, 'items', 'id', Query{}, .sum, 'id')! == 6
	assert select_keys_where(db, 'items', 'id', .int, Query{
		order: 'id'
		desc:  true
		limit: 2
	}, true)! == ['3', '2']
}
