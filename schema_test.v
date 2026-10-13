module vgraph

import db.sqlite
import sqlite as vsqlite
import orm
import time
import v.migrations

enum Mood {
	calm
	busy = 5
}

type Handle = string

struct Times {
	made_at time.Time
}

fn (t Times) fields() []Field {
	return [Field{
		name:        'made_at'
		default_now: true
	}]
}

fn (t Times) hooks() []Hook {
	return [Hook{
		name: 'times'
		run:  fn (next Mutate) Mutate {
			return next
		}
	}]
}

@[table: 'kinds']
struct Kinds {
	Times
	id     i64 @[primary; sql: serial]
	handle Handle
	mood   Mood
	tiny   i8
	small  ?u16
	ratio  f32
	notes  string
	flag   ?bool
}

fn (k Kinds) fields() []Field {
	return [Field{
		name: 'notes'
		json: '[]string'
	}]
}

fn (k Kinds) indexes() []Index {
	return [Index{
		columns: ['handle']
		unique:  true
	}, Index{
		name:    'kinds_calm_idx'
		columns: ['tiny']
		where:   'mood = 0'
	}]
}

fn test_types_and_mixins_are_reflected() {
	mut s := Schema{}
	s.add[Kinds]()!
	s.validate()!
	t := s.table('kinds')!
	assert t.columns.map('${it.name}:${it.typ}') == ['Times.made_at:time.Time', 'id:i64',
		'handle:string', 'mood:enum', 'tiny:i8', 'small:?u16', 'ratio:f32', 'notes:string', 'flag:?bool']
	assert t.column('Times.made_at')?.embedded == 'Times'
	assert t.column('Times.made_at')?.has_default, "the mixin's options apply"
	assert t.column('handle')?.type_name == 'Handle'
	assert t.column('mood')?.type_name == 'Mood'
	assert t.column('mood')?.enum_values == ['calm', 'busy']
	assert t.column('notes')?.json_type == '[]string'
	assert t.hooks == 1, "the mixin's hooks"
	assert t.indexes.len == 2
	assert s.migration_indexes().map(it.name) == ['kinds_handle_idx']
	assert s.partial_indexes().map('${it.index.name} ${it.where}') == ['kinds_calm_idx mood = 0']
	// reads and writes on every type
	mut db := sqlite.connect(':memory:')!
	mut m := migrations.new(mut db, [
		migrations.Migration{
			version: 1
			name:    'kinds'
			up:      fn [s] (mut ctx migrations.Context) ! {
				create_table(mut ctx, s, 'kinds')!
				add_edge_indexes(mut ctx, s)!
			}
			down:    fn (mut ctx migrations.Context) ! {}
		},
	], dialect: .sqlite)!
	m.migrate()!
	c := Client.new(vsqlite.new(db), s)!
	key := c.create(MutationData{
		table:  'kinds'
		values: {
			'handle': orm.Primitive('ada')
			'mood':   int(Mood.busy)
			'tiny':   i8(-2)
			'small':  u16(60000)
			'ratio':  f32(0.25)
			'notes':  '["a"]'
		}
	})!
	assert c.update_one(MutationData{
		table:   'kinds'
		row_key: key
		appends: {
			'notes': '["b"]'
		}
	})!
	row := select_kinds(c)![0]
	assert row.handle == 'ada'
	assert row.mood == .busy
	assert row.tiny == -2
	assert (row.small or { 0 }) == 60000
	assert row.ratio == 0.25
	assert row.notes == '["a","b"]'
	assert row.flag == none
	assert row.made_at.unix() > 0
}

fn select_kinds(c Client) ![]Kinds {
	return load_kinds(c.conn)
}

fn load_kinds(conn orm.Connection) ![]Kinds {
	return sql conn {
		select from Kinds
	}!
}

@[table: 'peers']
struct Peer {
	id      int @[primary; sql: serial]
	peer_id ?int
	rank    int
}

fn (p Peer) edges() []Edge {
	return [
		Edge{
			name:        'peer'
			kind:        .many_to_one
			to:          'peers'
			column:      'peer_id'
			ref:         'missing'
			required:    false
			order_field: 'nope'
		},
		Edge{
			name:   'rank_of'
			kind:   .many_to_one
			to:     'peers'
			column: 'rank'
			ref:    'peer'
		},
		Edge{
			name:        'followers'
			kind:        .one_to_many
			to:          'peers'
			column:      'peer_id'
			bidi:        true
			required:    true
			unique:      true
			order_field: 'rank'
		},
		Edge{
			name:   'partner'
			kind:   .many_to_one
			to:     'peers'
			column: 'peer_id'
			bidi:   true
		},
	]
}

fn (p Peer) fields() []Field {
	return [Field{
		name: 'rank'
		json: 'int'
	}]
}

// graphql asks for Node, which needs an i64 key.
fn (p Peer) graphql() GraphqlTable {
	return GraphqlTable{
		node: true
	}
}

fn (p Peer) indexes() []Index {
	return [Index{
		columns: ['nope']
	}]
}

fn test_new_options_are_checked() {
	mut s := Schema{}
	s.add[Peer]()!
	s.validate() or {
		assert err.msg().split_into_lines() == [
			'peers.fields: `rank`: `json` needs a string field, which holds the JSON',
			'peers.graphql: `node` needs an i64 serial key, which `global_ids` gives a range to',
			'peers.indexes: `nope` is not a column',
			'peers.peer: `ref` names `peers.missing`, which does not exist',
			'peers.peer: `order_field` names `peers.nope`, which does not exist',
			'peers.rank_of: `ref` names `peers.peer`, which is not its other side',
			'peers.followers: `unique` is for a many_to_one edge; a one_to_one edge is unique already',
			'peers.followers: `bidi` is for a many_to_one or many_to_many edge to its own table',
			'peers.followers: `required` is for a many_to_one edge',
			'peers.followers: `order_field` is for a many_to_one or one_to_one edge',
			'peers.partner: a `bidi` many_to_one edge pairs rows one to one: set `unique`',
		]
		return
	}
	assert false
}

@[table: 'listing'; vgraph: 'view']
struct Listing {
	id   int
	name string
}

fn test_views_have_no_writes() {
	mut s := Schema{}
	s.add[Listing]()!
	assert s.table('listing')!.view
	c := Client.new(sqlite.connect(':memory:')!, s)!
	c.create(MutationData{
		table:  'listing'
		values: {
			'name': orm.Primitive('x')
		}
	}) or {
		assert err.msg() == '`listing` is a view: it has no writes'
		return
	}
	assert false
}

@[table: 'first_ids']
struct FirstId {
	id   i64 @[primary; sql: serial]
	name string
}

@[table: 'second_ids']
struct SecondId {
	id   i64 @[primary; sql: serial]
	name string
}

// global_id_migrations returns two migrations: the first creates `first_ids`
// and gives it global ids, and the second adds `second_ids`, as a later
// release of an app would.
fn global_id_migrations() ![]migrations.Migration {
	mut first := Schema{}
	first.add[FirstId]()!
	mut both := Schema{}
	both.add[SecondId]()!
	both.add[FirstId]()!
	return [
		migrations.Migration{
			version: 1
			name:    'first'
			up:      fn [first] (mut ctx migrations.Context) ! {
				create_table(mut ctx, first, 'first_ids')!
				global_ids(mut ctx, first)!
			}
			down:    fn (mut ctx migrations.Context) ! {}
		},
		migrations.Migration{
			version: 2
			name:    'second'
			up:      fn [both] (mut ctx migrations.Context) ! {
				create_table(mut ctx, both, 'second_ids')!
				global_ids(mut ctx, both)!
			}
			down:    fn (mut ctx migrations.Context) ! {}
		},
	]
}

fn test_global_ids_keep_their_ranges() {
	mut db := sqlite.connect(':memory:')!
	mut m := migrations.new(mut db, global_id_migrations()!, dialect: .sqlite)!
	m.migrate()!
	mut both := Schema{}
	both.add[SecondId]()!
	both.add[FirstId]()!
	// without a driver, a new i64 key can't be read back
	if _ := Client.new(db, both)!.create(MutationData{
		table:  'first_ids'
		values: {
			'name': orm.Primitive('a')
		}
	})
	{
		assert false
	} else {
		assert err.msg().contains('needs a vgraph driver')
	}
	c := Client.new(vsqlite.new(db), both)!
	first := c.create(MutationData{
		table:  'first_ids'
		values: {
			'name': orm.Primitive('a')
		}
	})!
	second := c.create(MutationData{
		table:  'second_ids'
		values: {
			'name': orm.Primitive('b')
		}
	})!
	// `first_ids` kept the range it got first, though `second_ids` is
	// registered before it now
	assert first.i64() == (i64(1) << 32) + 1
	assert second.i64() == (i64(2) << 32) + 1
	assert c.table_of(first.i64())! == 'first_ids'
	assert c.table_of(second.i64())! == 'second_ids'
	// a table the ORM created has no AUTOINCREMENT
	mut plain := sqlite.connect(':memory:')!
	sql plain {
		create table FirstId
	}!
	mut s := Schema{}
	s.add[FirstId]()!
	mut bad := migrations.new(mut plain, [
		migrations.Migration{
			version: 1
			name:    'plain'
			up:      fn [s] (mut ctx migrations.Context) ! {
				global_ids(mut ctx, s)!
			}
			down:    fn (mut ctx migrations.Context) ! {}
		},
	], dialect: .sqlite)!
	bad.migrate() or {
		assert err.msg().contains('global ids need its key to be AUTOINCREMENT')
		return
	}
	assert false
}
