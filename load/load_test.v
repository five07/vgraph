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

@[table: 'tags']
pub struct Tag {
pub:
	id         int @[primary; sql: serial]
	name       string
	deleted_at ?time.Time
}

@[table: 'note_tags']
pub struct NoteTag {
pub:
	id      int @[primary; sql: serial]
	note_id int
	tag_id  int
}

fn seed() !sqlite.DB {
	mut db := sqlite.connect(':memory:')!
	sql db {
		create table Author
		create table Note
		create table Tag
		create table NoteTag
	}!
	for name in ['red', 'blue', 'old'] {
		tag := Tag{
			name:       name
			deleted_at: if name == 'old' { ?time.Time(time.now()) } else { none }
		}
		sql db {
			insert tag into Tag
		}!
	}
	// note 1: red, blue, old; note 2: blue; note 3: none
	for pair in [[1, 1], [1, 2], [1, 3], [2, 2]] {
		link := NoteTag{
			note_id: pair[0]
			tag_id:  pair[1]
		}
		sql db {
			insert link into NoteTag
		}!
	}
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
	notes := select_in[Note](conn, 'id', ['1', '2', '3', '4'])!
	log.tables.clear()
	authors := load_one[Note, Author](conn, notes, 'author_id')!
	assert log.tables == ['authors']
	assert authors.keys().sorted() == ['1', '2', '4']
	assert authors['4'].name == 'gone', 'soft-deleted records are included'
	assert authors['4'].deleted_at != none
	assert authors['1'].deleted_at == none
}

fn test_load_one_skips_null_keys() {
	db := seed()!
	conn, log := counting(db)
	notes := select_in[Note](conn, 'id', ['1', '2', '3', '4'])!
	parents := load_one[Note, Note](conn, notes, 'parent_id')!
	assert parents.keys() == ['1']
	assert parents['1'].parent_id == none
	log.tables.clear()
	assert load_one[Note, Note](conn, notes[..1], 'parent_id')!.len == 0
	assert log.tables.len == 0, 'no keys, no query'
}

fn test_load_one_polymorphic() {
	db := seed()!
	conn, log := counting(db)
	notes := select_in[Note](conn, 'id', ['1', '2', '3', '4'])!
	log.tables.clear()
	owners := load_one[Note, Author](conn, notes, 'owner_id',
		type_col: 'owner_type'
		type_val: 'Author'
	)!
	assert owners.keys() == ['1']
	assert log.tables == ['authors']
}

fn test_load_many_groups_by_parent() {
	db := seed()!
	conn, log := counting(db)
	authors := select_in[Author](conn, 'id', ['1', '2', '3', '1'])!
	assert authors.len == 3
	log.tables.clear()
	notes := load_many[Author, Note](conn, authors, 'author_id')!
	assert log.tables == ['notes']
	assert notes['1'].map(it.id) == [1, 4]
	assert notes['2'].map(it.id) == [2]
	assert '3' !in notes
	owned := load_many[Author, Note](conn, authors, 'owner_id',
		type_col: 'owner_type'
		type_val: 'Author'
	)!
	assert owned['1'].map(it.id) == [1, 2]
	assert '2' !in owned
}

fn test_load_many_skips_soft_deleted_rows() {
	db := seed()!
	conn, _ := counting(db)
	authors := select_in[Author](conn, 'id', ['1', '2', '3', '4'])!
	notes := select_in[Note](conn, 'id', ['3'])!
	assert notes[0].author == 4
	// note 3 is by author 4, who is deleted
	assert load_one[Note, Author](conn, notes, 'author_id', soft_del: 'deleted_at')!.len == 0
	assert load_one[Note, Author](conn, notes, 'author_id')!.len == 1
	assert select_in[Author](conn, 'id', ['1', '4'], soft_del: 'deleted_at')!.map(it.id) == [1]
	assert authors.len == 4
}

fn test_load_through_a_join_table() {
	db := seed()!
	conn, log := counting(db)
	notes := select_in[Note](conn, 'id', ['1', '2', '3'])!
	log.tables.clear()
	tags := load_through[Note, Tag](conn, notes, 'note_tags', 'note_id', 'tag_id')!
	assert log.tables == ['note_tags', 'tags']
	assert tags['1'].map(it.name) == ['red', 'blue', 'old']
	assert tags['2'].map(it.name) == ['blue']
	assert '3' !in tags
	live := load_through[Note, Tag](conn, notes, 'note_tags', 'note_id', 'tag_id',
		soft_del: 'deleted_at'
	)!
	assert live['1'].map(it.name) == ['red', 'blue']
	log.tables.clear()
	assert load_through[Note, Tag](conn, notes[2..], 'note_tags', 'note_id', 'tag_id')!.len == 0
	assert log.tables == ['note_tags'], 'no links, no second query'
}

fn test_select_in_maps_every_field() {
	db := seed()!
	conn, _ := counting(db)
	note := select_in[Note](conn, 'id', ['2'])![0]
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
		'3',
		'1',
	]
	assert key_column[Note](Note{ author: 7 }, 'author_id')? == '7'
	assert key_column[Note](Note{ author: 7 }, 'author') == none
	assert key_column[Note](Note{}, 'parent_id') == none
	assert key_column[Note](Note{ parent_id: 5 }, 'parent_id')? == '5'
	assert key_column[Note](Note{ owner_type: 'x' }, 'owner_type')? == 'x'
	assert key_type[Note]('author_id')! == .int
	assert key_type[Note]('owner_type')! == .string
	if _ := key_type[Note]('created_at') {
		assert false, 'a time is not a key'
	} else {
		assert err.msg() == '`notes.created_at` is not an int, i64 or string column'
	}
}

fn test_select_where() {
	db := seed()!
	conn, log := counting(db)
	by_id := fn [conn] (q Query) ![]int {
		return select_where[Note](conn, q)!.map(it.id)
	}
	assert by_id(Query{})! == [1, 2, 3, 4]
	assert by_id(conds: [eq('owner_type', 'Other')])! == [3, 4]
	assert by_id(conds: [ne('author_id', 1), lt('id', 3)])! == [2]
	assert by_id(conds: [ge('id', 2), le('id', 3)])! == [2, 3]
	assert by_id(conds: [gt('id', 3)])! == [4]
	assert by_id(conds: [is_null('parent_id')], order: 'id', desc: true)! == [4, 3, 1]
	assert by_id(conds: [is_not_null('parent_id')])! == [2]
	assert by_id(conds: [like('body', '%[1, 1%')])! == [4]
	assert by_id(conds: [in_strings('owner_type', ['Author']), in_ints('id', [2, 9])])! == [2]
	assert by_id(order: 'id', desc: true, limit: 2)! == [4, 3]
	log.tables.clear()
	assert by_id(conds: [in_ints('id', [])])! == []
	assert log.tables.len == 0, 'an empty IN runs no query'
}

fn test_load_many_with_a_query() {
	db := seed()!
	conn, _ := counting(db)
	authors := select_in[Author](conn, 'id', ['1'])!
	notes := load_many[Author, Note](conn, authors, 'author_id',
		query: Query{
			conds: [eq('owner_type', 'Other')]
			order: 'id'
			desc:  true
			limit: 1
		}
	)!
	assert notes['1'].map(it.id) == [4], 'the limit is ignored for edge loads'
	newest_first := load_many[Author, Note](conn, authors, 'author_id',
		query: Query{
			order: 'id'
			desc:  true
		}
	)!
	assert newest_first['1'].map(it.id) == [4, 1]
}

fn test_unique_and_link_pairs() {
	assert unique(['3', '1', '3', '2', '1']) == ['3', '1', '2']
	db := seed()!
	conn, log := counting(db)
	assert link_pairs(conn, 'note_tags', 'note_id', 'tag_id', ['2', '1'], .int, .int)! == [
		['1', '1'],
		['1', '2'],
		['1', '3'],
		['2', '2'],
	]
	log.tables.clear()
	assert link_pairs(conn, 'note_tags', 'note_id', 'tag_id', [], .int, .int)!.len == 0
	assert log.tables.len == 0
}

fn test_conditions_on_times() {
	db := seed()!
	conn, _ := counting(db)
	assert select_where[Note](conn, conds: [lt('created_at', time.now().add_days(1))])!.len == 4
	assert select_where[Note](conn, conds: [gt('created_at', time.now().add_days(1))])!.len == 0
}

// Device is keyed by a UUID string.
@[table: 'devices']
pub struct Device {
pub:
	id   string @[primary]
	name string
}

// Login has an i64 key, and refers to a device by its UUID.
@[table: 'logins']
pub struct Login {
pub:
	id        i64 @[primary; sql: serial]
	device_id ?string
	user      string
}

// DeviceTag links a device (a string key) and a tag (an int key).
@[table: 'device_tags']
pub struct DeviceTag {
pub:
	id        int @[primary; sql: serial]
	device_id string
	tag_id    int
}

const phone = '0b9f8a52-6a8e-4c1e-9d1b-3f2a7c1d5e01'
const laptop = '7c3e9d10-2b4f-4a6d-8e5c-1a0b9f8e7d02'

fn seed_devices() !sqlite.DB {
	mut db := seed()!
	sql db {
		create table Device
		create table Login
		create table DeviceTag
	}!
	for d in [[phone, 'phone'], [laptop, 'laptop']] {
		device := Device{
			id:   d[0]
			name: d[1]
		}
		sql db {
			insert device into Device
		}!
	}
	for l in [[phone, 'ada'], [phone, 'bob'], [laptop, 'ada'], ['', 'cy']] {
		login := Login{
			device_id: if l[0] == '' { ?string(none) } else { ?string(l[0]) }
			user:      l[1]
		}
		sql db {
			insert login into Login
		}!
	}
	// phone: red, blue; laptop: blue
	for pair in [[phone, '1'], [phone, '2'], [laptop, '2']] {
		link := DeviceTag{
			device_id: pair[0]
			tag_id:    pair[1].int()
		}
		sql db {
			insert link into DeviceTag
		}!
	}
	return db
}

fn test_string_and_i64_keys() {
	db := seed_devices()!
	conn, log := counting(db)
	assert key_type[Device]('id')! == .string
	assert key_type[Login]('id')! == .i64
	devices := select_in[Device](conn, 'id', [laptop, phone])!
	assert devices.map(it.name).sorted() == ['laptop', 'phone']
	logins := select_where[Login](conn, order: 'id')!
	assert logins.map(it.id) == [i64(1), 2, 3, 4]
	assert select_in[Login](conn, 'id', ['2', '4'])!.map(it.user) == ['bob', 'cy']
	log.tables.clear()
	// many_to_one through a string column; the null one is skipped
	by_device := load_one[Login, Device](conn, logins, 'device_id')!
	assert log.tables == ['devices']
	assert by_device.len == 2
	assert by_device[phone].name == 'phone'
	// one_to_many on a string key
	grouped := load_many[Device, Login](conn, devices, 'device_id')!
	assert grouped[phone].map(it.user) == ['ada', 'bob']
	assert grouped[laptop].map(it.user) == ['ada']
	// a join table with a string column and an int column, both ways
	log.tables.clear()
	tags := load_through[Device, Tag](conn, devices, 'device_tags', 'device_id', 'tag_id')!
	assert log.tables == ['device_tags', 'tags']
	assert tags[phone].map(it.name) == ['red', 'blue']
	assert tags[laptop].map(it.name) == ['blue']
	all_tags := select_in[Tag](conn, 'id', ['1', '2', '3'])!
	tagged := load_through[Tag, Device](conn, all_tags, 'device_tags', 'tag_id', 'device_id')!
	assert tagged['1'].map(it.name) == ['phone']
	assert tagged['2'].map(it.name).sorted() == ['laptop', 'phone']
	assert '3' !in tagged
	assert select_where[Login](conn, conds: [in_keys('id', ['1', '3'], .i64)])!.map(it.user) == [
		'ada',
		'ada',
	]
}

fn test_offset_count_and_not_in() {
	db := seed()!
	conn, log := counting(db)
	ids := fn [conn] (q Query) ![]int {
		return select_where[Note](conn, q)!.map(it.id)
	}
	assert ids(order: 'id', offset: 1)! == [2, 3, 4], 'an offset alone'
	assert ids(order: 'id', limit: 2, offset: 1)! == [2, 3]
	assert ids(conds: [not_in_ints('id', [1, 3])], order: 'id')! == [2, 4]
	assert ids(conds: [not_in_ints('id', [])], order: 'id')! == [1, 2, 3, 4], 'NOT IN () is every row'
	log.tables.clear()
	assert count_where[Note](conn, Query{})! == 4
	assert count_where[Note](conn, conds: [eq('owner_type', 'Other')], limit: 1)! == 2
	assert count_where[Note](conn, conds: [in_ints('id', [])])! == 0
	assert log.tables == ['notes', 'notes'], 'an empty IN counts without a query'
}

fn test_load_through_keeps_the_order_of_the_query() {
	db := seed()!
	conn, _ := counting(db)
	notes := select_in[Note](conn, 'id', ['1'])!
	tags := load_through[Note, Tag](conn, notes, 'note_tags', 'note_id', 'tag_id',
		query: Query{
			order: 'name'
			desc:  true
		}
	)!
	assert tags['1'].map(it.name) == ['red', 'old', 'blue']
}

// sql_of returns `c`, normalized, as SQL for `dialect`, and its parameters.
fn sql_of(c Cond, dialect orm.SQLDialect) !(string, []string) {
	mut p := Params{
		dialect: dialect
	}
	text := render(normalize(c, false), mut p)!
	return text, p.values
}

// Keyset conditions: past a cursor in an order, with nulls where each database
// puts them.
fn test_keyset() {
	orders := [desc('rating'), asc('id')]
	// after (4.5, 3), nulls the largest (PostgreSQL): descending, a smaller
	// rating comes after, and no null does
	after, after_values := sql_of(keyset(orders, [orm.Primitive(4.5), 3], true, true)!, .pg)!
	assert after == '("rating" < \$1 OR ("rating" = \$2 AND "id" > \$3))'
	assert after_values == ['4.5', '4.5', '3']
	// nulls the smallest (SQLite): they come last, descending
	lite, _ := sql_of(keyset(orders, [orm.Primitive(4.5), 3], true, false)!, .sqlite)!
	assert lite == '("rating" < CAST(? AS REAL) OR "rating" IS NULL OR ("rating" = CAST(? AS REAL) AND "id" > CAST(? AS INTEGER)))'
	// after a null rating: on PostgreSQL every non-null one, descending; on
	// SQLite none but the nulls after it
	pg_null, _ := sql_of(keyset(orders, [orm.Primitive(orm.Null{}), 3], true, true)!, .pg)!
	assert pg_null == '("rating" IS NOT NULL OR ("rating" IS NULL AND "id" > \$1))'
	lite_null, _ := sql_of(keyset(orders, [orm.Primitive(orm.Null{}), 3], true, false)!,
		.sqlite)!
	assert lite_null == '("rating" IS NULL AND "id" > CAST(? AS INTEGER))'
	// before is the other way
	before, _ := sql_of(keyset([asc('id')], [orm.Primitive(3)], false, true)!, .pg)!
	assert before == '"id" < \$1'
	// an order by an expression compares it as SQL
	expr, _ := sql_of(keyset([Order{
		expr: '(SELECT COUNT(*) FROM "t1")'
		typ:  'int'
	}, asc('id')], [orm.Primitive(2), 7], true, true)!, .pg)!
	assert expr == '(((SELECT COUNT(*) FROM "t1") > \$1) OR ((SELECT COUNT(*) FROM "t1") IS NULL) OR (((SELECT COUNT(*) FROM "t1") = \$2) AND "id" > \$3))'
	keyset(orders, [orm.Primitive(1)], true, true) or {
		assert err.msg() == 'invalid cursor'
		return
	}
	assert false
}

fn test_cursors() {
	at := time.parse_rfc3339('2026-10-13T07:30:00.250000Z')!
	values := [orm.Primitive(3.5), 'a,"b"', orm.Null{}, at, i64(1) << 40, 7]
	cursor := encode_cursor(values)
	assert !cursor.contains('"')
	got := decode_cursor(cursor, ['f64', 'string', '?int', 'time.Time', 'i64', 'enum'])!
	assert got.len == 6
	assert got[0] == orm.Primitive(3.5)
	assert got[1] == orm.Primitive('a,"b"')
	assert got[2] is orm.Null
	assert (got[3] as time.Time).unix_micro() == at.unix_micro()
	assert got[4] == orm.Primitive(i64(1) << 40)
	assert got[5] == orm.Primitive(7)
	for bad in ['abc', encode_cursor([orm.Primitive(1)]), encode_cursor([orm.Primitive('x')])] {
		if _ := decode_cursor(bad, ['int', 'int']) {
			assert false, bad
		}
	}
	if _ := decode_cursor(encode_cursor([orm.Primitive('x')]), ['int']) {
		assert false
	}
}

// Without a driver, a limit per parent reads every row and cuts each parent's.
fn test_per_parent_without_a_driver() {
	db := seed()!
	conn, log := counting(db)
	// notes 1 and 4 are by author 1, note 2 by author 2
	newest := select_each[Note](conn, 'author_id', ['1', '2', '3'],
		query: Query{
			order: 'id'
			desc:  true
			limit: 1
		}
	)!
	assert newest.map(it.id) == [4, 2]
	assert log.tables == ['notes']
	second := select_each[Note](conn, 'author_id', ['1', '2'],
		query: Query{
			order:  'id'
			desc:   true
			limit:  1
			offset: 1
		}
	)!
	assert second.map(it.id) == [1]
	assert count_each(conn, 'notes', 'author_id', ['1', '2', '3'], .int, Query{})! == {
		'1': 2
		'2': 1
	}
	assert count_each(conn, 'notes', 'author_id', ['1', '2'], .int, Query{
		conds: [eq('owner_type', 'Author')]
	})! == {
		'1': 1
		'2': 1
	}
	// through a join table: note 1 has red, blue and the deleted old; note 2 blue
	live := Query{
		conds: [is_null('deleted_at')]
		order: 'name'
	}
	assert link_each(conn, 'note_tags', 'note_id', 'tag_id', ['1', '2', '3'], .int, .int, 'tags',
		'id', Query{
			...live
			limit: 1
		})! == [['1', '2'], ['2', '2']]
	assert link_each(conn, 'note_tags', 'note_id', 'tag_id', ['1'], .int, .int, 'tags', 'id',
		Query{
			...live
			offset: 1
		})! == [['1', '1']]
	assert count_through(conn, 'note_tags', 'note_id', 'tag_id', ['1', '2', '3'], .int, .int,
		'tags', 'id', live)! == {
		'1': 2
		'2': 1
	}
	// no keys, no query
	log.tables.clear()
	assert count_each(conn, 'notes', 'author_id', [], .int, Query{})!.len == 0
	assert link_each(conn, 'note_tags', 'note_id', 'tag_id', [], .int, .int, 'tags', 'id',
		live)!.len == 0
	assert log.tables.len == 0
	// the order values of an edge need a driver
	if _ := expr_values(conn, 'notes', 'id', .int, ['1'], [Order{
		expr: '1'
		typ:  'int'
	}]) {
		assert false
	}
	assert expr_values(conn, 'notes', 'id', .int, ['1'], [asc('id')])!.len == 0
	assert !has_driver(conn)
	assert !nulls_largest(conn)
}
