module load

import db.sqlite
import orm
import time

@[table: 'authors']
pub struct Author {
pub:
	id         int @[primary; sql: serial]
	name       string
	deleted_at ?time.Time
}

@[table: 'notes']
pub struct Note {
pub:
	id         int @[primary; sql: serial]
	author     int @[sql: 'author_id']
	owner_type string
	owner_id   int
	parent_id  ?int
	body       string
	created_at time.Time
}

fn seed() !sqlite.DB {
	mut db := sqlite.connect(':memory:')!
	sql db {
		create table Author
		create table Note
	}!
	for name in ['ada', 'bob', 'cy'] {
		author := Author{
			name: name
		}
		sql db {
			insert author into Author
		}!
	}
	gone := Author{
		name:       'gone'
		deleted_at: time.now()
	}
	sql db {
		insert gone into Author
	}!
	// author, owner type, owner id, parent
	for n in [[1, 0, 1, 0], [2, 0, 1, 1], [4, 1, 1, 0], [1, 1, 2, 0]] {
		note := Note{
			author:     n[0]
			owner_type: if n[1] == 0 { 'Author' } else { 'Other' }
			owner_id:   n[2]
			parent_id:  if n[3] > 0 { ?int(n[3]) } else { none }
			body:       'note ${n}'
			created_at: time.now()
		}
		sql db {
			insert note into Note
		}!
	}
	return db
}

@[heap]
struct Log {
mut:
	tables []string
}

// Counting runs queries on `inner`, and logs the table of each select.
struct Counting {
mut:
	inner orm.Connection
	log   &Log
}

fn (mut c Counting) select(config orm.SelectConfig, data orm.QueryData, where orm.QueryData) ![][]orm.Primitive {
	c.log.tables << config.table.name
	return c.inner.select(config, data, where)
}

fn (mut c Counting) insert(table orm.Table, data orm.QueryData) ! {
	c.inner.insert(table, data)!
}

fn (mut c Counting) update(table orm.Table, data orm.QueryData, where orm.QueryData) ! {
	c.inner.update(table, data, where)!
}

fn (mut c Counting) delete(table orm.Table, where orm.QueryData) ! {
	c.inner.delete(table, where)!
}

fn (mut c Counting) create(table orm.Table, fields []orm.TableField) ! {
	c.inner.create(table, fields)!
}

fn (mut c Counting) drop(table orm.Table) ! {
	c.inner.drop(table)!
}

fn (mut c Counting) last_id() int {
	return c.inner.last_id()
}

fn (mut c Counting) execute(query string) ![]orm.Row {
	return c.inner.execute(query)
}

fn counting(db sqlite.DB) (Counting, &Log) {
	log := &Log{}
	return Counting{
		inner: db
		log:   log
	}, log
}

fn test_load_one_follows_a_column_in_one_query() {
	db := seed()!
	conn, log := counting(db)
	notes := select_in[Note](conn, 'id', [1, 2, 3, 4])!
	log.tables.clear()
	authors := load_one[Note, Author](conn, notes, 'author_id')!
	assert log.tables == ['authors']
	assert authors.keys().sorted() == [1, 2, 4]
	assert authors[4].name == 'gone', 'soft-deleted records are included'
	assert authors[4].deleted_at != none
	assert authors[1].deleted_at == none
}

fn test_load_one_skips_null_keys() {
	db := seed()!
	conn, log := counting(db)
	notes := select_in[Note](conn, 'id', [1, 2, 3, 4])!
	parents := load_one[Note, Note](conn, notes, 'parent_id')!
	assert parents.keys() == [1]
	assert parents[1].parent_id == none
	log.tables.clear()
	assert load_one[Note, Note](conn, notes[..1], 'parent_id')!.len == 0
	assert log.tables.len == 0, 'no keys, no query'
}

fn test_load_one_polymorphic() {
	db := seed()!
	conn, log := counting(db)
	notes := select_in[Note](conn, 'id', [1, 2, 3, 4])!
	log.tables.clear()
	owners := load_one[Note, Author](conn, notes, 'owner_id',
		type_col: 'owner_type'
		type_val: 'Author'
	)!
	assert owners.keys() == [1]
	assert log.tables == ['authors']
}

fn test_load_many_groups_by_parent() {
	db := seed()!
	conn, log := counting(db)
	authors := select_in[Author](conn, 'id', [1, 2, 3, 1])!
	assert authors.len == 3
	log.tables.clear()
	notes := load_many[Author, Note](conn, authors, 'author_id')!
	assert log.tables == ['notes']
	assert notes[1].map(it.id) == [1, 4]
	assert notes[2].map(it.id) == [2]
	assert 3 !in notes
	owned := load_many[Author, Note](conn, authors, 'owner_id',
		type_col: 'owner_type'
		type_val: 'Author'
	)!
	assert owned[1].map(it.id) == [1, 2]
	assert 2 !in owned
}

fn test_select_in_maps_every_field() {
	db := seed()!
	conn, _ := counting(db)
	note := select_in[Note](conn, 'id', [2])![0]
	assert note.author == 2
	assert note.owner_type == 'Author'
	assert note.parent_id or { 0 } == 1
	assert note.body == 'note [2, 0, 1, 1]'
	assert note.created_at.year >= 2026
}

fn test_reflection() {
	assert table_name[Note]() == 'notes'
	assert primary_key[Note]() == 'id'
	assert keys_of[Author]([Author{ id: 3 }, Author{ id: 1 }, Author{ id: 3 }])! == [
		3,
		1,
	]
	assert int_column[Note](Note{ author: 7 }, 'author_id')? == 7
	assert int_column[Note](Note{ author: 7 }, 'author') == none
	assert int_column[Note](Note{}, 'parent_id') == none
}
