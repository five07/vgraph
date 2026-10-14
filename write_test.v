module vgraph

import db.sqlite as sq
import graphql
import load
import orm
import sqlite
import time

@[table: 'writers']
struct Writer {
	id         int @[primary; sql: serial]
	name       string
	email      ?string
	score      int
	created_at time.Time
	updated_at time.Time
}

fn (w Writer) edges() []Edge {
	return [
		Edge{
			name:   'stories'
			kind:   .one_to_many
			to:     'stories'
			column: 'writer_id'
		},
		Edge{
			name:   'badge'
			kind:   .one_to_one
			to:     'badges'
			column: 'writer_id'
		},
	]
}

fn (w Writer) fields() []Field {
	return [
		Field{
			name:      'name'
			not_empty: true
			max_len:   10
		},
		Field{
			name:     'email'
			unique:   true
			pattern:  r'^[a-z]+@[a-z]+\.[a-z]+$'
			validate: fn (value orm.Primitive) ! {
				if value is string && value.starts_with('root@') {
					return error('is reserved')
				}
			}
		},
		Field{
			name:    'score'
			min:     0
			max:     100
			default: fn () orm.Primitive {
				return 10
			}
		},
		Field{
			name:        'created_at'
			default_now: true
			immutable:   true
		},
		Field{
			name:        'updated_at'
			default_now: true
			update_now:  true
		},
	]
}

@[table: 'stories']
struct Story {
	id        int @[primary; sql: serial]
	writer_id ?int
	title     string
	views     int @[default: '0']
}

fn (s Story) edges() []Edge {
	return [
		Edge{
			name:   'writer'
			kind:   .many_to_one
			to:     'writers'
			column: 'writer_id'
		},
		Edge{
			name:       'labels'
			kind:       .many_to_many
			to:         'labels'
			column:     'story_id'
			through:    'story_labels'
			through_to: 'label_id'
		},
	]
}

fn (s Story) fields() []Field {
	return [Field{
		name:     'views'
		optional: true
		positive: true
	}]
}

@[table: 'labels']
struct Label {
	id    string @[primary]
	name  string @[unique]
	color string
}

@[table: 'story_labels']
struct StoryLabel {
	id       int @[primary; sql: serial]
	story_id int
	label_id string
}

@[table: 'badges']
struct Badge {
	id        int @[primary; sql: serial]
	writer_id ?int
	name      string
}

fn write_schema() !Schema {
	mut s := Schema{}
	s.add[Writer]()!
	s.add[Story]()!
	s.add[Label]()!
	s.add[Badge]()!
	return s
}

fn write_db() !sq.DB {
	db := sq.connect(':memory:')!
	sql db {
		create table Writer
		create table Story
		create table Label
		create table StoryLabel
		create table Badge
	}!
	return db
}

// clients returns a client without a driver, and one with the SQLite driver,
// each on a database of its own.
fn clients() ![]Client {
	s := write_schema()!
	return [Client.new(write_db()!, s)!, Client.new(sqlite.new(write_db()!), s)!]
}

struct Case {
	values  map[string]orm.Primitive
	message string
}

fn create(c Client, table string, values map[string]orm.Primitive) !string {
	return c.create(MutationData{
		op:     .create
		table:  table
		values: values
	})
}

fn writers(c Client) ![]Writer {
	return load.select_where[Writer](c.conn, load.Query{ order: 'id' })
}

fn stories(c Client) ![]Story {
	return load.select_where[Story](c.conn, load.Query{ order: 'id' })
}

fn test_options_are_reflected() {
	s := write_schema()!
	t := s.table('writers')!
	score := t.column('score')?
	assert score.optional && score.has_default && !score.immutable
	created := t.column('created_at')?
	assert created.immutable && created.has_default && !created.auto_update
	updated := t.column('updated_at')?
	assert updated.auto_update
	id := t.column('id')?
	assert id.serial && id.optional
	assert !t.column('name')?.optional
	assert s.table('labels')!.column('name')?.unique
	assert s.options('writers')['email'].pattern != ''
}

fn test_options_are_checked() {
	mut s := Schema{}
	s.add[BadOptions]()!
	s.validate() or {
		assert err.msg().split_into_lines() == [
			'bad_options.fields: `missing` is not a field of `vgraph.BadOptions`',
			'bad_options.fields: `name`: `default_now` and `update_now` need a time.Time field',
			'bad_options.fields: `name`: `min`, `max` and `positive` need a number field',
			'bad_options.fields: `count`: `not_empty`, `min_len`, `max_len` and `pattern` need a string field',
			'bad_options.fields: `count`: an immutable field has no update default',
			'bad_options.fields: `count` is listed twice',
		]
		return
	}
	assert false
}

@[table: 'bad_options']
struct BadOptions {
	id    int @[primary; sql: serial]
	name  string
	count int
}

fn (b BadOptions) fields() []Field {
	return [
		Field{
			name: 'missing'
		},
		Field{
			name:        'name'
			default_now: true
			positive:    true
		},
		Field{
			name:           'count'
			not_empty:      true
			immutable:      true
			update_now:     false
			update_default: fn () orm.Primitive {
				return 0
			}
		},
		Field{
			name: 'count'
		},
	]
}

fn test_create_applies_defaults_and_returns_the_key() {
	for c in clients()! {
		before := time.now().unix()
		assert create(c, 'writers', {
			'name': orm.Primitive('ada')
		})! == '1'
		assert create(c, 'writers', {
			'name':  orm.Primitive('bob')
			'score': 42
			'email': 'bob@example.com'
		})! == '2'
		rows := writers(c)!
		assert rows.map(it.name) == ['ada', 'bob']
		assert rows.map(it.score) == [10, 42]
		assert rows[0].email == none
		assert (rows[1].email or { '' }) == 'bob@example.com'
		assert rows[0].created_at.unix() >= before
		assert rows[0].updated_at.unix() >= before
	}
}

fn test_create_checks_values() {
	for c in clients()! {
		for case in [
			Case{map[string]orm.Primitive{}, '`writers.name`: is required'},
			Case{{
				'name': orm.Primitive('')
			}, '`writers.name`: is empty'},
			Case{{
				'name': orm.Primitive('a very long name')
			}, '`writers.name`: is longer than 10 bytes'},
			Case{{
				'name':  orm.Primitive('ada')
				'score': 101
			}, '`writers.score`: is more than 100.0'},
			Case{{
				'name':  orm.Primitive('ada')
				'email': 'not an email'
			}, '`writers.email`: does not match `^[a-z]+@[a-z]+\\.[a-z]+$`'},
			Case{{
				'name':  orm.Primitive('ada')
				'email': 'root@example.com'
			}, '`writers.email`: is reserved'},
			Case{{
				'name': orm.Primitive(orm.Null{})
			}, "`writers.name`: can't be null"},
			Case{{
				'name': orm.Primitive(3)
			}, '`writers.name`: is string, not int'},
		] {
			create(c, 'writers', case.values) or {
				assert err is ValidationError
				assert err.msg() == case.message
				continue
			}
			assert false, case.message
		}
		create(c, 'writers', {
			'name': orm.Primitive('ada')
			'age':  3
		}) or {
			assert err.msg() == '`writers` has no column `age`'
			continue
		}
		assert false
	}
}

fn test_update_one() {
	for c in clients()! {
		key := create(c, 'writers', {
			'name': orm.Primitive('ada')
		})!
		first := writers(c)![0]
		time.sleep(1100 * time.millisecond)
		assert c.update_one(MutationData{
			op:      .update_one
			table:   'writers'
			row_key: key
			values:  {
				'name': orm.Primitive('ada l')
			}
			adds:    {
				'score': orm.Primitive(5)
			}
		})!
		row := writers(c)![0]
		assert row.name == 'ada l'
		assert row.score == 15
		assert row.created_at.unix() == first.created_at.unix()
		assert row.updated_at.unix() > first.updated_at.unix()
		// no such row
		assert !c.update_one(MutationData{
			op:      .update_one
			table:   'writers'
			row_key: '99'
			values:  {
				'name': orm.Primitive('x')
			}
		})!
		for case in [
			Case{{
				'created_at': orm.Primitive(time.now())
			}, '`writers.created_at`: is immutable'},
			Case{{
				'id': orm.Primitive(5)
			}, "`writers.id`: is the key, which can't change"},
			Case{{
				'name': orm.Primitive('')
			}, '`writers.name`: is empty'},
		] {
			c.update_one(MutationData{
				op:      .update_one
				table:   'writers'
				row_key: key
				values:  case.values
			}) or {
				assert err.msg() == case.message
				continue
			}
			assert false, case.message
		}
	}
}

fn test_update_and_delete_count_rows() {
	for c in clients()! {
		for name in ['ada', 'bob', 'cy'] {
			create(c, 'writers', {
				'name': orm.Primitive(name)
			})!
		}
		assert c.update(MutationData{
			op:     .update
			table:  'writers'
			conds:  [load.ne('name', 'cy')]
			values: {
				'score': orm.Primitive(50)
			}
		})! == 2
		assert writers(c)!.map(it.score) == [50, 50, 10]
		assert c.update(MutationData{
			op:     .update
			table:  'writers'
			conds:  [load.eq('name', 'nobody')]
			values: {
				'score': orm.Primitive(1)
			}
		})! == 0
		assert c.delete(MutationData{
			op:    .delete
			table: 'writers'
			conds: [load.ge('score', 50)]
		})! == 2
		assert writers(c)!.map(it.name) == ['cy']
		assert c.delete_one(MutationData{
			op:      .delete_one
			table:   'writers'
			row_key: '3'
		})!
		assert !c.delete_one(MutationData{
			op:      .delete_one
			table:   'writers'
			row_key: '3'
		})!
	}
}

fn test_edges_of_every_kind() {
	for c in clients()! {
		ada := create(c, 'writers', {
			'name': orm.Primitive('ada')
		})!
		for id, name in {
			'l1': 'red'
			'l2': 'green'
			'l3': 'blue'
		} {
			create(c, 'labels', {
				'id':    orm.Primitive(id)
				'name':  name
				'color': name
			})!
		}
		// many_to_one through its column, and many_to_many on create
		story := c.create(MutationData{
			op:     .create
			table:  'stories'
			values: {
				'title':     orm.Primitive('one')
				'writer_id': ada.int()
			}
			added:  {
				'labels': ['l1', 'l2']
			}
		})!
		other := create(c, 'stories', {
			'title': orm.Primitive('two')
		})!
		assert labels_of(c, story)! == ['l1', 'l2']
		// one_to_many: add, remove, clear
		bob := c.create(MutationData{
			op:     .create
			table:  'writers'
			values: {
				'name': orm.Primitive('bob')
			}
			added:  {
				'stories': [other]
				'badge':   [create(c, 'badges', {
					'name': orm.Primitive('gold')
				})!]
			}
		})!
		assert stories(c)!.map(it.writer_id or { 0 }) == [1, 2]
		assert c.update_one(MutationData{
			op:      .update_one
			table:   'writers'
			row_key: bob
			removed: {
				'stories': [other]
			}
			added:   {
				'stories': [story]
			}
		})!
		assert stories(c)!.map(it.writer_id or { 0 }) == [2, 0]
		assert c.update_one(MutationData{
			op:      .update_one
			table:   'writers'
			row_key: bob
			cleared: ['stories', 'badge']
		})!
		assert stories(c)!.map(it.writer_id or { 0 }) == [0, 0]
		assert load.select_where[Badge](c.conn, load.Query{})![0].writer_id == none
		// many_to_many: clear then add, and remove
		assert c.update_one(MutationData{
			op:      .update_one
			table:   'stories'
			row_key: story
			cleared: ['labels']
			added:   {
				'labels': ['l3', 'l2']
			}
		})!
		assert labels_of(c, story)! == ['l2', 'l3']
		assert c.update_one(MutationData{
			op:      .update_one
			table:   'stories'
			row_key: story
			removed: {
				'labels': ['l3']
			}
		})!
		assert labels_of(c, story)! == ['l2']
		// many_to_one cleared
		assert c.update_one(MutationData{
			op:      .update_one
			table:   'stories'
			row_key: story
			added:   {
				'writer': [ada]
			}
		})!
		assert stories(c)![0].writer_id or { 0 } == 1
		assert c.update_one(MutationData{
			op:      .update_one
			table:   'stories'
			row_key: story
			cleared: ['writer']
		})!
		assert stories(c)![0].writer_id == none
		// deleting a story deletes its join rows
		assert c.delete_one(MutationData{
			op:      .delete_one
			table:   'stories'
			row_key: story
		})!
		assert load.select_where[StoryLabel](c.conn, load.Query{})!.len == 0
	}
}

fn labels_of(c Client, story string) ![]string {
	mut ids := load.select_where[StoryLabel](c.conn, load.Query{
		conds: [load.eq('story_id', story.int())]
	})!.map(it.label_id)
	ids.sort()
	return ids
}

fn test_a_failed_edge_write_rolls_the_create_back() {
	for c in clients()! {
		create(c, 'badges', {
			'name': orm.Primitive('gold')
		})!
		create(c, 'badges', {
			'name': orm.Primitive('silver')
		})!
		c.create(MutationData{
			op:     .create
			table:  'writers'
			values: {
				'name': orm.Primitive('ada')
			}
			added:  {
				'badge': ['1', '2']
			}
		}) or {
			assert err.msg() == '`writers.badge` is one_to_one: set one target, not 2'
			assert writers(c)!.len == 0
			continue
		}
		assert false
	}
}

fn test_transactions() {
	for c in clients()! {
		mut tx := c.begin()!
		create(tx, 'writers', {
			'name': orm.Primitive('ada')
		})!
		// a write inside joins the transaction
		create(tx, 'writers', {
			'name': orm.Primitive('bob')
		})!
		tx.rollback()!
		assert writers(c)!.len == 0
		tx = c.begin()!
		create(tx, 'writers', {
			'name': orm.Primitive('cy')
		})!
		tx.commit()!
		assert writers(c)!.map(it.name) == ['cy']
	}
}

// Requester is the context of a GraphQL request, in `test_graphql_transaction`.
struct Requester {
	name string
}

// A GraphQL request's mutations (Q103): `GraphqlTransaction` begins a
// transaction, and a client given the context it returns runs in it, with the
// request's own context.
fn test_graphql_transaction() {
	for c in clients()! {
		assert c.can_begin()
		t := GraphqlTransaction{
			client: c
		}
		ctx := t.begin(Requester{'ada'})!
		assert ctx is TxContext
		inner := c.with_ctx(ctx)
		assert inner.in_tx
		if inner.ctx is Requester {
			assert inner.ctx.name == 'ada'
		} else {
			assert false, "the request's own context"
		}
		create(inner, 'writers', {
			'name': orm.Primitive('ada')
		})!
		t.rollback(ctx)!
		assert writers(c)!.len == 0
		again := t.begin(Requester{'bob'})!
		create(c.with_ctx(again), 'writers', {
			'name': orm.Primitive('bob')
		})!
		t.commit(again)!
		assert writers(c)!.map(it.name) == ['bob']
	}
}

fn test_create_bulk() {
	for c in clients()! {
		keys := c.create_bulk([
			MutationData{
				op:     .create
				table:  'writers'
				values: {
					'name': orm.Primitive('ada')
				}
			},
			MutationData{
				op:     .create
				table:  'writers'
				values: {
					'name':  orm.Primitive('bob')
					'email': 'bob@example.com'
				}
			},
		])!
		assert keys == ['1', '2']
		assert writers(c)!.map(it.name) == ['ada', 'bob']
		// one bad row: none are stored
		c.create_bulk([
			MutationData{
				op:     .create
				table:  'writers'
				values: {
					'name': orm.Primitive('cy')
				}
			},
			MutationData{
				op:    .create
				table: 'writers'
			},
		]) or {
			assert err.msg() == '`writers.name`: is required'
			assert writers(c)!.len == 2
			continue
		}
		assert false
	}
}

fn upsert(c Client, id string, name string, color string, action OnConflict) !string {
	return c.create(MutationData{
		op:               .create
		table:            'labels'
		values:           {
			'id':    orm.Primitive(id)
			'name':  name
			'color': color
		}
		conflict_columns: ['name']
		on_conflict:      action
	})
}

fn test_upsert() {
	both := clients()!
	if _ := upsert(both[0], 'l1', 'red', 'red', .update_new_values) {
		assert false
	} else {
		assert err.msg() == '`labels`: an upsert needs a vgraph driver (five07.vgraph.sqlite or five07.vgraph.pg)'
	}
	c := both[1]
	assert upsert(c, 'l1', 'red', 'red', .update_new_values)! == 'l1'
	// the stored row takes the new color, and keeps its key
	assert upsert(c, 'l9', 'red', 'crimson', .update_new_values)! == 'l1'
	assert upsert(c, 'l7', 'red', 'pink', .ignore)! == 'l1'
	assert upsert(c, 'l8', 'red', 'pink', .do_nothing)! == ''
	rows := load.select_where[Label](c.conn, load.Query{})!
	assert rows.map('${it.id}=${it.name}:${it.color}') == ['l1=red:crimson']
	create(c, 'labels', {
		'id':    orm.Primitive('l2')
		'name':  'red'
		'color': 'red'
	}) or {
		assert err.msg().contains('UNIQUE')
		return
	}
	assert false
}

fn test_the_driver_runs_sql_with_parameters() {
	mut d := sqlite.new(write_db()!)
	rows := d.exec_params('SELECT ? + 1, ?, NULL', ['41', 'a'])!
	assert rows.len == 1
	assert rows[0].map(it or { 'null' }) == ['42', 'a', '']
	// an error has SQLite's message and code, not the statement
	if _ := d.exec_params('INSERT INTO missing VALUES (?)', ['secret']) {
		assert false
	} else {
		assert err.msg() == 'no such table: missing'
		assert err.code() == 1
	}
	conn := orm.Connection(d)
	assert conn is Driver
	assert orm.Connection(write_db()!) !is Driver
}

// Threads that share a driver take turns at transactions, which SQLite has one
// of per connection: every write of every thread is stored.
fn test_threads_share_a_driver() {
	db := sq.connect_full(':memory:', [.readwrite, .create, .fullmutex], '')!
	sql db {
		create table Writer
	}!
	c := Client.new(sqlite.new(db), write_schema()!)!
	mut threads := []thread !string{}
	for i in 0 .. 20 {
		threads << spawn create(c, 'writers', {
			'name': orm.Primitive('w${i}')
		})
	}
	mut keys := []string{}
	for t in threads {
		keys << t.wait()!
	}
	assert keys.len == 20 && load.unique(keys).len == 20
	assert writers(c)!.len == 20
	// and a transaction of one thread holds back another's until it ends
	mut tx := c.begin()!
	create(tx, 'writers', {
		'name': orm.Primitive('in tx')
	})!
	other := spawn create(c, 'writers', {
		'name': orm.Primitive('after')
	})
	tx.rollback()!
	other.wait()!
	assert writers(c)!.map(it.name).filter(it in ['in tx', 'after']) == ['after']
}

fn test_unique_fields_get_an_index() {
	s := write_schema()!
	assert s.migration_indexes().map('${it.name} ${it.columns} ${it.unique}') == [
		"badges_writer_id_idx ['writer_id'] true",
		"stories_writer_id_idx ['writer_id'] false",
		"story_labels_label_id_story_id_idx ['label_id', 'story_id'] true",
		"story_labels_story_id_idx ['story_id'] false",
		"writers_email_idx ['email'] true",
	]
}

@[heap]
struct WriteEvents {
mut:
	items []string
}

fn (e &WriteEvents) add(item string) {
	mut events := unsafe { e }
	events.items << item
}

// Plain is a connection with no transactions: only `orm.Connection`.
struct Plain {
mut:
	db sq.DB
}

fn (mut p Plain) select(config orm.SelectConfig, data orm.QueryData, where orm.QueryData) ![][]orm.Primitive {
	return p.db.select(config, data, where)
}

fn (mut p Plain) insert(table orm.Table, data orm.QueryData) ! {
	p.db.insert(table, data)!
}

fn (mut p Plain) update(table orm.Table, data orm.QueryData, where orm.QueryData) ! {
	p.db.update(table, data, where)!
}

fn (mut p Plain) delete(table orm.Table, where orm.QueryData) ! {
	p.db.delete(table, where)!
}

fn (mut p Plain) create(table orm.Table, fields []orm.TableField) ! {
	p.db.create(table, fields)!
}

fn (mut p Plain) drop(table orm.Table) ! {
	p.db.drop(table)!
}

fn (mut p Plain) last_id() int {
	return p.db.last_id()
}

fn (mut p Plain) execute(query string) ![]orm.Row {
	return p.db.execute(query)
}

// On a connection without transactions, a write's statements run one by one,
// and its `on_commit` and `on_rollback` callbacks follow the write's own
// success or failure. Outside a write, `on_commit` runs at once.
fn test_writes_without_transactions() {
	c := Client.new(&Plain{
		db: write_db()!
	}, write_schema()!)!
	assert !c.can_begin()
	events := &WriteEvents{}
	c.use_on('writers', Hook{
		run: fn [events] (next Mutate) Mutate {
			return fn [events, next] (ctx graphql.Context, mut m Mutation) ! {
				name := (m.field_value('name') or { orm.Primitive('') }) as string
				m.on_commit(fn [events, name] () {
					events.add('commit ${name}')
				})
				m.on_rollback(fn [events, name] () {
					events.add('rollback ${name}')
				})
				next(ctx, mut m)!
			}
		}
	})
	create(c, 'writers', {
		'name':  orm.Primitive('ada')
		'email': 'ada@example.com'
	})!
	// too long a name, checked after the hooks
	create(c, 'writers', {
		'name': orm.Primitive('bob the builder')
	}) or { events.add('failed') }
	c.on_commit(fn [events] () {
		events.add('at once')
	})
	c.on_rollback(fn [events] () {
		events.add('never')
	})
	assert events.items == ['commit ada', 'rollback bob the builder', 'failed', 'at once']
	assert writers(c)!.map(it.name) == ['ada']
}

// The SQLite driver runs the ORM's transactions too, as `v.migrations` does.
fn test_the_sqlite_driver_runs_orm_transactions() {
	mut d := sqlite.new(write_db()!)
	c := Client.new(d, write_schema()!)!
	for commit in [false, true] {
		d.orm_begin()!
		d.insert(orm.Table{ name: 'writers' }, orm.QueryData{
			fields: ['name', 'score', 'created_at', 'updated_at']
			data:   [orm.Primitive('ada'), orm.Primitive(1), orm.Primitive(time.now()),
				orm.Primitive(time.now())]
		})!
		if commit {
			d.orm_commit()!
		} else {
			d.orm_rollback()!
		}
		assert writers(c)!.len == if commit { 1 } else { 0 }
	}
}
