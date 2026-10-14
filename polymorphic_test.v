module vgraph

import db.sqlite as sq
import load
import orm
import sqlite
import time
import v.migrations

// Notes belong to a doc or a pic, as `owner_type` says; pics are soft-deleted.

@[table: 'notes']
struct Note {
	id         int @[primary; sql: serial]
	owner_type ?string
	owner_id   ?int
	body       string
}

fn (n Note) edges() []Edge {
	return [
		Edge{
			name:     'doc'
			kind:     .many_to_one
			to:       'docs'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Doc'
		},
		Edge{
			name:     'pic'
			kind:     .many_to_one
			to:       'pics'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Pic'
		},
	]
}

@[table: 'docs']
struct Doc {
	id    int @[primary; sql: serial]
	title string
}

fn (d Doc) edges() []Edge {
	return [
		Edge{
			name:     'notes'
			kind:     .one_to_many
			to:       'notes'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Doc'
		},
	]
}

@[table: 'pics']
struct Pic {
	id         int @[primary; sql: serial]
	title      string
	deleted_at ?time.Time
}

fn (p Pic) interceptors() []Interceptor {
	return [soft_delete_query('deleted_at')]
}

// Clip declares a third type of note owner, only on its own side.
@[table: 'clips']
struct Clip {
	id int @[primary; sql: serial]
}

fn (c Clip) edges() []Edge {
	return [
		Edge{
			name:     'notes'
			kind:     .one_to_many
			to:       'notes'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Clip'
		},
	]
}

fn poly_schema() !Schema {
	mut s := Schema{}
	s.add[Note]()!
	s.add[Doc]()!
	s.add[Pic]()!
	s.add[Clip]()!
	return s
}

fn poly_db() !sq.DB {
	db := sq.connect(':memory:')!
	sql db {
		create table Note
		create table Doc
		create table Pic
		create table Clip
	}!
	return db
}

// poly_clients returns a client without a driver, and one with the SQLite
// driver, each on a database with docs 1 and 2, pics 1 and 2 (2 deleted) and
// clip 1.
fn poly_clients() ![]Client {
	s := poly_schema()!
	mut out := []Client{}
	for c in [Client.new(poly_db()!, s)!, Client.new(sqlite.new(poly_db()!), s)!] {
		for title in ['a', 'b'] {
			poly_create(c, 'docs', {
				'title': orm.Primitive(title)
			})!
			poly_create(c, 'pics', {
				'title': orm.Primitive(title)
			})!
		}
		poly_create(c, 'clips', map[string]orm.Primitive{})!
		c.update_one(MutationData{
			op:      .update_one
			table:   'pics'
			row_key: '2'
			values:  {
				'deleted_at': orm.Primitive(time.now())
			}
		})!
		out << c
	}
	return out
}

fn note(c Client, typ string, id int) !string {
	return poly_create(c, 'notes', {
		'owner_type': orm.Primitive(typ)
		'owner_id':   id
		'body':       'on ${typ} ${id}'
	})
}

fn notes(c Client) ![]string {
	return load.select_where[Note](c.conn, load.Query{ order: 'id' })!.map('${it.owner_type or {
		'-'
	}} ${it.owner_id or { 0 }}')
}

fn test_polymorphics() {
	s := poly_schema()!
	assert s.polymorphics().map('${it.table}.${it.type_col}/${it.column} ${it.targets}') == [
		"notes.owner_type/owner_id {'Doc': 'docs', 'Pic': 'pics', 'Clip': 'clips'}",
	]
	// a type that names two tables
	mut bad := Schema{}
	bad.add[Note]()!
	bad.add[Doc]()!
	bad.add[Pic]()!
	bad.add[Clip]()!
	bad.add[PicAsDoc]()!
	if _ := bad.validate() {
		assert false
	} else {
		assert err.msg() == 'pic_docs.notes: `notes.owner_type` = `Doc` names both `docs` and `pic_docs`'
	}
}

@[table: 'pic_docs']
struct PicAsDoc {
	id int @[primary; sql: serial]
}

fn (p PicAsDoc) edges() []Edge {
	return [
		Edge{
			name:     'notes'
			kind:     .one_to_many
			to:       'notes'
			column:   'owner_id'
			type_col: 'owner_type'
			type_val: 'Doc'
		},
	]
}

fn test_creates_check_polymorphic_keys() {
	for c in poly_clients()! {
		note(c, 'Doc', 2)!
		note(c, 'Pic', 1)!
		note(c, 'Clip', 1)!
		// no owner at all
		poly_create(c, 'notes', {
			'body': orm.Primitive('alone')
		})!
		for typ, id in {
			'Doc':  9
			'Pic':  2
			'Clip': 2
		} {
			note(c, typ, id) or {
				assert err is ValidationError
				assert err.msg() == '`notes.owner_id`: no `${typ}` has the key `${id}`'
				continue
			}
			assert false, '${typ} ${id}'
		}
		if _ := note(c, 'Video', 1) {
			assert false
		} else {
			assert err.msg() == '`notes.owner_type`: is `Video`, not one of `Clip`, `Doc`, `Pic`'
		}
		if _ := poly_create(c, 'notes', {
			'owner_id': orm.Primitive(1)
			'body':     'no type'
		})
		{
			assert false
		} else {
			assert err.msg() == '`notes.owner_type`: is required with `owner_id`'
		}
		// a deleted pic is there for a client that reads deleted rows
		note(c.skip('soft_delete'), 'Pic', 2)!
		// a bulk create checks each row, and writes none when one fails
		bulk := [1, 9].map(MutationData{
			op:     .create
			table:  'notes'
			values: {
				'owner_type': orm.Primitive('Doc')
				'owner_id':   it
				'body':       'bulk'
			}
		})
		if _ := c.create_bulk(bulk) {
			assert false
		} else {
			assert err.msg() == '`notes.owner_id`: no `Doc` has the key `9`'
		}
		assert notes(c)! == ['Doc 2', 'Pic 1', 'Clip 1', '- 0', 'Pic 2']
	}
}

fn test_updates_check_polymorphic_keys() {
	for c in poly_clients()! {
		first := note(c, 'Doc', 1)!
		note(c, 'Doc', 2)!
		update := fn [c] (key string, values map[string]orm.Primitive) string {
			c.update_one(MutationData{
				op:      .update_one
				table:   'notes'
				row_key: key
				values:  values
			}) or { return err.msg() }
			return 'ok'
		}
		// half a pair takes the other half from the row
		assert update(first, {
			'owner_id': orm.Primitive(9)
		}) == '`notes.owner_id`: no `Doc` has the key `9`'
		assert update(first, {
			'owner_type': orm.Primitive('Pic')
		}) == 'ok'
		assert update(first, {
			'owner_id': orm.Primitive(2)
		}) == '`notes.owner_id`: no `Pic` has the key `2`'
		assert update(first, {
			'owner_type': orm.Primitive('Doc')
			'owner_id':   2
		}) == 'ok'
		assert update(first, {
			'owner_id': orm.Primitive(orm.Null{})
		}) == 'ok'
		assert update(first, {
			'owner_type': orm.Primitive('Video')
		}) == 'ok', 'a null key names no row, whatever the type'
		assert update(first, {
			'owner_id': orm.Primitive(1)
		}) == '`notes.owner_type`: is `Video`, not one of `Clip`, `Doc`, `Pic`'
		assert update(first, {
			'owner_type': orm.Primitive('Doc')
		}) == 'ok'
		// an update of many rows checks each
		if _ := c.update(MutationData{
			op:     .update
			table:  'notes'
			values: {
				'owner_type': orm.Primitive('Pic')
			}
		})
		{
			assert false
		} else {
			assert err.msg() == '`notes.owner_id`: no `Pic` has the key `2`'
		}
		assert notes(c)! == ['Doc 0', 'Doc 2']
		// setting the edge
		set_pic := fn [c, first] (pic string) string {
			c.update_one(MutationData{
				op:      .update_one
				table:   'notes'
				row_key: first
				added:   {
					'pic': [pic]
				}
			}) or { return err.msg() }
			return 'ok'
		}
		assert set_pic('2') == '`notes.owner_id`: no `Pic` has the key `2`'
		assert set_pic('1') == 'ok'
		assert notes(c)! == ['Pic 1', 'Doc 2']
		// a doc that takes a note needs no check: the doc is the row written
		assert c.update_one(MutationData{
			op:      .update_one
			table:   'docs'
			row_key: '1'
			added:   {
				'notes': [first]
			}
		})!
		assert notes(c)! == ['Doc 1', 'Doc 2']
	}
}

fn poly_migration(s Schema) migrations.Migration {
	return migrations.Migration{
		version: 1
		name:    'polymorphic'
		up:      fn [s] (mut ctx migrations.Context) ! {
			for table in ['notes', 'docs', 'pics', 'clips'] {
				create_table(mut ctx, s, table)!
			}
			add_polymorphic_checks(mut ctx, s)!
		}
		down:    fn [s] (mut ctx migrations.Context) ! {
			remove_polymorphic_checks(mut ctx, s)!
		}
	}
}

fn trigger_names(mut db sq.DB) ![]string {
	return db.exec("SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")!.map(it.vals[0])
}

// The triggers of `add_polymorphic_checks` on SQLite, through
// `exec_param_many`: `exec` ignores errors raised while a statement runs.
fn test_polymorphic_checks_on_sqlite() {
	s := poly_schema()!
	mut db := sq.connect(':memory:')!
	mut m := migrations.new(mut db, [poly_migration(s)], dialect: .sqlite)!
	m.migrate()!
	assert trigger_names(mut db)! == ['notes_owner_id_poly_insert', 'notes_owner_id_poly_update']
	insert := 'INSERT INTO notes (owner_type, owner_id, body) VALUES (?, ?, ?)'
	db.exec_param_many('INSERT INTO docs (title) VALUES (?)', ['a'])!
	db.exec_param_many(insert, ['Doc', '1', 'ok'])!
	db.exec_none("INSERT INTO notes (body) VALUES ('alone')")
	for values in [['Doc', '2'], ['Pic', '1'], ['Video', '1']] {
		if _ := db.exec_param_many(insert, [values[0], values[1], 'bad']) {
			assert false, values.str()
		} else {
			assert err.msg().contains('notes.owner_id: no row of the type in owner_type has this key')
		}
	}
	if _ := db.exec_param_many('UPDATE notes SET owner_id = ? WHERE id = 1', ['2']) {
		assert false
	}
	db.exec_param_many('UPDATE notes SET owner_type = ?, owner_id = ? WHERE id = 1', [
		'Doc',
		'1',
	])!
	assert db.exec('SELECT count(*) FROM notes')![0].vals[0] == '2'
	m.rollback(1)!
	assert trigger_names(mut db)! == []
	db.exec_param_many(insert, ['Doc', '2', 'unchecked'])!
}

fn poly_create(c Client, table string, values map[string]orm.Primitive) !string {
	return c.create(MutationData{
		op:     .create
		table:  table
		values: values
	})
}
