module main

// The checks for each Ent relationship kind, run on SQLite by `main_test.v` and
// on PostgreSQL by `pg_test.v`, through the client `vgraph gen` wrote into
// `graph/`.
import orm
import v.migrations
import five07.vgraph
import five07.vgraph.graphql
import five07.vgraph.load
import graph
import models

// Log holds the table of each select a traced connection ran.
@[heap]
struct Log {
mut:
	tables []string
}

// Fixture is a seeded database, its client, and the log of its selects, and a
// client on a vgraph driver for writes.
struct Fixture {
	g   graph.Graph
	w   graph.Graph
	db  orm.Connection
	log &Log
}

// queries returns the tables of the selects run since the last call.
fn (f Fixture) queries() []string {
	mut log := f.log
	tables := log.tables.clone()
	log.tables.clear()
	return tables
}

// initial is the example's one migration: the tables, from their structs, and
// the indexes their edges need.
const initial = migrations.Migration{
	version: 1
	name:    'initial'
	up:      initial_up
	down:    initial_down
}

fn initial_up(mut ctx migrations.Context) ! {
	migrations.create_orm_table[models.User](mut ctx)!
	migrations.create_orm_table[models.Card](mut ctx)!
	migrations.create_orm_table[models.Pet](mut ctx)!
	migrations.create_orm_table[models.Group](mut ctx)!
	migrations.create_orm_table[models.GroupUser](mut ctx)!
	migrations.create_orm_table[models.Follow](mut ctx)!
	migrations.create_orm_table[models.Friendship](mut ctx)!
	migrations.create_orm_table[models.Node](mut ctx)!
	migrations.create_orm_table[models.Category](mut ctx)!
	migrations.create_orm_table[models.Device](mut ctx)!
	migrations.create_orm_table[models.Login](mut ctx)!
	migrations.create_orm_table[models.DeviceGroup](mut ctx)!
	// gadgets have global ids: their table comes from the schema, with an
	// AUTOINCREMENT (SQLite) or BIGSERIAL (PostgreSQL) key
	s := graph.schema()!
	vgraph.create_table(mut ctx, s, 'gadgets')!
	migrations.create_orm_table[models.Like](mut ctx)!
	ctx.execute('CREATE VIEW pet_owners AS SELECT p.id AS id, p.name AS pet_name, p.owner_id AS owner_id, u.name AS owner_name FROM pets p JOIN users u ON u.id = p.owner_id')!
	vgraph.add_edge_indexes(mut ctx, s)!
	vgraph.global_ids(mut ctx, s)!
}

fn initial_down(mut ctx migrations.Context) ! {
	ctx.execute('DROP VIEW pet_owners')!
	migrations.drop_orm_table[models.Like](mut ctx)!
	ctx.drop_table('gadgets')!
	migrations.drop_orm_table[models.DeviceGroup](mut ctx)!
	migrations.drop_orm_table[models.Login](mut ctx)!
	migrations.drop_orm_table[models.Device](mut ctx)!
	migrations.drop_orm_table[models.Category](mut ctx)!
	migrations.drop_orm_table[models.Node](mut ctx)!
	migrations.drop_orm_table[models.Friendship](mut ctx)!
	migrations.drop_orm_table[models.Follow](mut ctx)!
	migrations.drop_orm_table[models.GroupUser](mut ctx)!
	migrations.drop_orm_table[models.Group](mut ctx)!
	migrations.drop_orm_table[models.Pet](mut ctx)!
	migrations.drop_orm_table[models.Card](mut ctx)!
	migrations.drop_orm_table[models.User](mut ctx)!
}

// migrate applies `initial` to `db`, which must have none of its tables.
fn migrate(mut db orm.TransactionalConnection, dialect migrations.Dialect) ! {
	mut m := migrations.new(mut db, [initial], dialect: dialect)!
	m.migrate()!
}

// seed fills the tables that `migrate` created on `db`. It takes `db` as an
// `orm.Connection`: `sql` blocks reject a `TransactionalConnection`
// (regressions/sql_transactional_connection.vv). `driver` is `db` in a vgraph
// driver, for writes.
fn seed(db orm.Connection, driver orm.Connection) !Fixture {
	for name in ['ada', 'bob', 'cy', 'dee'] {
		user := models.User{
			name: name
		}
		sql db {
			insert user into models.User
		}!
	}
	// ada and bob are married: each holds the other's id
	sql db {
		update models.User set spouse_id = 2 where id == 1
		update models.User set spouse_id = 1 where id == 2
	}!
	for card in [models.Card{
		number:   '4242'
		owner_id: 1
	}, models.Card{
		number:   '5555'
		owner_id: 2
	}] {
		sql db {
			insert card into models.Card
		}!
	}
	for pet in [models.Pet{
		name:     'rex'
		owner_id: 1
	}, models.Pet{
		name:     'tom'
		owner_id: 1
	}, models.Pet{
		name: 'stray'
	}] {
		sql db {
			insert pet into models.Pet
		}!
	}
	for name in ['admins', 'devs'] {
		group := models.Group{
			name: name
		}
		sql db {
			insert group into models.Group
		}!
	}
	// admins: ada; devs: ada and bob
	for pair in [[1, 1], [2, 1], [2, 2]] {
		link := models.GroupUser{
			group_id: pair[0]
			user_id:  pair[1]
		}
		sql db {
			insert link into models.GroupUser
		}!
	}
	// ada follows bob and cy; bob follows cy
	for pair in [[1, 2], [1, 3], [2, 3]] {
		follow := models.Follow{
			follower_id: pair[0]
			followee_id: pair[1]
		}
		sql db {
			insert follow into models.Follow
		}!
	}
	// ada and bob are friends, and cy and dee: each friendship in both directions
	for pair in [[1, 2], [2, 1], [3, 4], [4, 3]] {
		friendship := models.Friendship{
			user_id:   pair[0]
			friend_id: pair[1]
		}
		sql db {
			insert friendship into models.Friendship
		}!
	}
	// the list 1 -> 2 -> 3
	for value in [1, 2, 3] {
		node := models.Node{
			value:   value
			next_id: if value < 3 { ?int(value + 1) } else { none }
		}
		sql db {
			insert node into models.Node
		}!
	}
	// root > a > a1, and root > b
	for c in [['root', '0'], ['a', '1'], ['b', '1'], ['a1', '2']] {
		category := models.Category{
			name:      c[0]
			parent_id: if c[1] != '0' { ?int(c[1].int()) } else { none }
		}
		sql db {
			insert category into models.Category
		}!
	}
	// ada has a phone and a laptop, bob a tablet; cy and dee have none
	for d in [[phone, 'phone', '1'], [laptop, 'laptop', '1'], [tablet, 'tablet', '2']] {
		device := models.Device{
			id:       d[0]
			name:     d[1]
			owner_id: d[2].int()
		}
		sql db {
			insert device into models.Device
		}!
	}
	for i, device_id in [phone, phone, tablet] {
		login := models.Login{
			device_id: device_id
			at:        i + 1
		}
		sql db {
			insert login into models.Login
		}!
	}
	// the phone is in admins and devs, the tablet in devs
	for pair in [[phone, '1'], [phone, '2'], [tablet, '2']] {
		link := models.DeviceGroup{
			device_id: pair[0]
			group_id:  pair[1].int()
		}
		sql db {
			insert link into models.DeviceGroup
		}!
	}
	log := &Log{}
	g := graph.Graph.new(vgraph.trace(db, fn [log] (e vgraph.TraceEvent) {
		if e.kind == .select {
			mut l := unsafe { log }
			l.tables << e.table
		}
	}))!
	return Fixture{
		g:   g
		w:   graph.Graph.new(driver)!
		db:  db
		log: log
	}
}

const phone = '6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b'
const laptop = '0a1b2c3d-4e5f-4061-8273-94a5b6c7d8e9'
const tablet = 'f0e1d2c3-b4a5-4697-8879-6a5b4c3d2e1f'

fn names(users []graph.UserNode) []string {
	return users.map(it.user.name)
}

// O2O two types: a user has at most one card, which has one owner.
fn check_o2o_two_types(f Fixture) ! {
	f.queries()
	users := f.g.users().with_card().order_by_id().all()!
	cards := f.g.cards().with_owner().order_by_id().all()!
	assert f.queries() == ['users', 'cards', 'cards', 'users']
	assert users.map(if c := it.card { c.card.number } else { '-' }) == ['4242', '5555', '-', '-']
	assert cards.map(if o := it.owner { o.user.name } else { '-' }) == ['ada', 'bob']
	assert users[0].query_card().first()!.card.number == '4242'
	assert users[2].query_card().all()!.len == 0
	assert cards[1].query_owner().first()!.user.name == 'bob'
}

// O2O same type: each node of a linked list has a next and a previous node.
fn check_o2o_same_type(f Fixture) ! {
	f.queries()
	nodes := f.g.nodes().with_next().with_prev().order_by_id().all()!
	assert f.queries() == ['nodes', 'nodes', 'nodes']
	assert nodes.map(if n := it.next { n.node.value } else { 0 }) == [2, 3, 0]
	assert nodes.map(if p := it.prev { p.node.value } else { 0 }) == [0, 1, 2]
	// walk the list both ways by traversal
	mut forward := []int{}
	mut node := f.g.nodes().where_next_id(2).first()!
	for {
		forward << node.node.value
		node = node.query_next().first() or { break }
	}
	assert forward == [1, 2, 3]
	mut back := []int{}
	for {
		back << node.node.value
		node = node.query_prev().first() or { break }
	}
	assert back == [3, 2, 1]
}

// O2O bidirectional: a spouse is a user whose spouse is this user.
fn check_o2o_bidirectional(f Fixture) ! {
	users := f.g.users().with_spouse().order_by_id().all()!
	assert users.map(if s := it.spouse { s.user.name } else { '-' }) == ['bob', 'ada', '-', '-']
	bob := users[0].query_spouse().first()!
	assert bob.query_spouse().first()!.user.name == 'ada'
	assert users[2].query_spouse().all()!.len == 0
}

// O2M two types: a user has many pets; a pet has at most one owner.
fn check_o2m_two_types(f Fixture) ! {
	users := f.g.users().with_pets(fn (q graph.PetQuery) graph.PetQuery {
		return q.order_by_name_desc()
	}).order_by_id().all()!
	assert users[0].pets.map(it.pet.name) == ['tom', 'rex']
	assert users[1].pets.len == 0
	assert users[0].query_pets().order_by_name().all()!.map(it.pet.name) == ['rex', 'tom']
	pets := f.g.pets().with_owner().order_by_id().all()!
	assert pets.map(if o := it.owner { o.user.name } else { '-' }) == ['ada', 'ada', '-']
	assert pets[0].query_owner().first()!.user.name == 'ada'
	assert pets[2].query_owner().all()!.len == 0, 'a pet with no owner'
	assert f.g.pets().where_owner_id_is_null().first()!.pet.name == 'stray'
}

// O2M same type: a category tree, loaded three levels deep in three queries.
fn check_o2m_same_type(f Fixture) ! {
	f.queries()
	roots := f.g.categories().where_parent_id_is_null().with_children(fn (q graph.CategoryQuery) graph.CategoryQuery {
		return q.order_by_name().with_children()
	}).all()!
	assert f.queries() == ['categories', 'categories', 'categories']
	assert roots.map(it.category.name) == ['root']
	children := roots[0].children
	assert children.map(it.category.name) == ['a', 'b']
	assert children[0].children.map(it.category.name) == ['a1']
	assert children[1].children.len == 0
	assert roots[0].query_children().order_by_name_desc().all()!.map(it.category.name) == [
		'b',
		'a',
	]
	a1 := f.g.categories().where_name('a1').with_parent(fn (q graph.CategoryQuery) graph.CategoryQuery {
		return q.with_parent()
	}).first()!
	parent := a1.parent or { return error('a1 has a parent') }
	assert parent.category.name == 'a'
	grandparent := parent.parent or { return error('a has a parent') }
	assert grandparent.category.name == 'root'
	assert a1.query_parent().first()!.category.name == 'a'
	assert roots[0].query_parent().all()!.len == 0, 'the root has no parent'
}

// M2M two types: a group has many users, who can be in many groups.
fn check_m2m_two_types(f Fixture) ! {
	f.queries()
	groups := f.g.groups().with_users().order_by_id().all()!
	assert f.queries() == ['groups', 'group_users', 'users'], 'the join table, then the users'
	assert groups.map(names(it.users)) == [['ada'], ['ada', 'bob']]
	users := f.g.users().with_groups().order_by_id().all()!
	assert users.map(it.groups.map(it.group.name)) == [['admins', 'devs'], ['devs'], [], []]
	assert names(groups[1].query_users()!.order_by_name_desc().all()!) == ['bob', 'ada']
	assert users[0].query_groups()!.order_by_id().all()!.map(it.group.name) == [
		'admins',
		'devs',
	]
	assert users[3].query_groups()!.all()!.len == 0
}

// M2M same type: following and followers, two edges over one join table.
fn check_m2m_same_type(f Fixture) ! {
	users := f.g.users().with_following(fn (q graph.UserQuery) graph.UserQuery {
		return q.order_by_id()
	}).with_followers().order_by_id().all()!
	assert users.map(names(it.following)) == [['bob', 'cy'], ['cy'], [], []]
	assert users.map(names(it.followers)) == [[], ['ada'], ['ada', 'bob'], []]
	assert names(users[0].query_following()!.order_by_id().all()!) == ['bob', 'cy']
	assert names(users[2].query_followers()!.order_by_id().all()!) == ['ada', 'bob']
}

// M2M bidirectional: friends, stored in both directions, so either side sees
// the other.
fn check_m2m_bidirectional(f Fixture) ! {
	users := f.g.users().with_friends().order_by_id().all()!
	assert users.map(names(it.friends)) == [['bob'], ['ada'], ['dee'], ['cy']]
	assert names(users[3].query_friends()!.all()!) == ['cy']
}

// The one_to_one edges get unique indexes, so the database keeps them one to
// one: it rejects a second card for ada. So does each join table's pair of
// columns: it rejects ada joining admins twice.
fn check_unique_indexes(f Fixture) ! {
	unique := f.g.client.schema.migration_indexes().filter(it.unique).map(it.name)
	assert unique == ['cards_owner_id_idx', 'device_groups_device_id_group_id_idx',
		'follows_followee_id_follower_id_idx', 'friendships_friend_id_user_id_idx',
		'gadgets_serial_no_idx', 'group_users_group_id_user_id_idx', 'likes_gadget_id_user_id_idx',
		'nodes_next_id_idx', 'users_spouse_id_idx']
	second_card := models.Card{
		number:   '9999'
		owner_id: 1
	}
	again := models.GroupUser{
		group_id: 1
		user_id:  1
	}
	mut rejected := 0
	sql f.db {
		insert second_card into models.Card
	} or {
		// SQLite says `UNIQUE constraint failed`, PostgreSQL `violates unique constraint`
		assert err.msg().to_lower().contains('unique')
		rejected++
	}
	sql f.db {
		insert again into models.GroupUser
	} or {
		assert err.msg().to_lower().contains('unique')
		rejected++
	}
	// bob is ada's spouse: cy can't marry him too
	sql f.db {
		update models.User set spouse_id = 2 where id == 3
	} or {
		assert err.msg().to_lower().contains('unique')
		rejected++
	}
	assert rejected == 3, 'a second card for ada, ada in admins twice, and a second spouse for bob, should be rejected'
}

// UUID keys: devices are keyed by strings, and every kind of edge works on them,
// in the same number of queries as on int keys.
fn check_uuid_keys(f Fixture) ! {
	f.queries()
	devices := f.g.devices().with_owner().with_logins().with_groups().order_by_name().all()!
	assert f.queries() == ['devices', 'users', 'logins', 'device_groups', 'groups']
	assert devices.map(it.device.name) == ['laptop', 'phone', 'tablet']
	assert devices.map(if o := it.owner { o.user.name } else { '-' }) == ['ada', 'ada', 'bob']
	assert devices.map(it.logins.map(it.login.at)) == [[], [1, 2], [3]]
	assert devices.map(it.groups.map(it.group.name)) == [[], ['admins', 'devs'], ['devs']]
	// the other direction of each
	users := f.g.users().with_devices(fn (q graph.DeviceQuery) graph.DeviceQuery {
		return q.order_by_name()
	}).order_by_id().all()!
	assert users.map(it.devices.map(it.device.name)) == [['laptop', 'phone'], ['tablet'], [], []]
	logins := f.g.logins().with_device().order_by_at().all()!
	assert logins.map(if d := it.device { d.device.id } else { '-' }) == [phone, phone, tablet]
	groups := f.g.groups().with_devices().order_by_id().all()!
	assert groups.map(it.devices.map(it.device.name).sorted()) == [['phone'], ['phone', 'tablet']]
	// traversals, and predicates on the key
	phone_node := f.g.devices().where_id(phone).first()!
	assert phone_node.query_logins().all()!.len == 2
	assert phone_node.query_owner().first()!.user.name == 'ada'
	assert phone_node.query_groups()!.order_by_id().all()!.map(it.group.name) == [
		'admins',
		'devs',
	]
	assert groups[1].query_devices()!.order_by_name().all()!.map(it.device.id) == [
		phone,
		tablet,
	]
	assert logins[2].query_device().first()!.device.name == 'tablet'
	assert f.g.devices().where_id_in([tablet, laptop]).order_by_name().all()!.map(it.device.name) == [
		'laptop',
		'tablet',
	]
}

// gql runs a GraphQL query on the client's server, and returns the response
// as JSON.
fn gql(f Fixture, query string) !string {
	mut s := f.g.graphql(graph.Resolvers{})!
	return s.execute(graphql.Request{
		query: query
	}, unsafe { nil }).json()
}

// GraphQL: every relationship kind, one select per edge per level, and the
// arguments of lists.
fn check_graphql(f Fixture) ! {
	f.queries()
	// O2O two types, both directions
	assert gql(f, '{ users(orderBy: {field: ID}) { name card { number owner { name } } } }')! == '{"data":{"users":[{"name":"ada","card":{"number":"4242","owner":{"name":"ada"}}},{"name":"bob","card":{"number":"5555","owner":{"name":"bob"}}},{"name":"cy","card":null},{"name":"dee","card":null}]}}'
	assert f.queries() == ['users', 'cards', 'users']
	// O2M same type, three levels in three selects
	assert gql(f, '{ categories(where: {parentIDIsNil: true}) { name children(orderBy: {field: NAME}) { name children { name } } } }')! == '{"data":{"categories":[{"name":"root","children":[{"name":"a","children":[{"name":"a1"}]},{"name":"b","children":[]}]}]}}'
	assert f.queries() == ['categories', 'categories', 'categories']
	// M2M through a join table, and its other side
	assert gql(f, '{ groups(orderBy: {field: ID}) { name users(orderBy: {field: NAME, direction: DESC}) { name groups { name } } } }')! == '{"data":{"groups":[{"name":"admins","users":[{"name":"ada","groups":[{"name":"admins"},{"name":"devs"}]}]},{"name":"devs","users":[{"name":"bob","groups":[{"name":"devs"}]},{"name":"ada","groups":[{"name":"admins"},{"name":"devs"}]}]}]}}'
	assert f.queries() == ['groups', 'group_users', 'users', 'group_users', 'groups']
	// O2M two types with a per-parent limit, filters, counts and pagination
	assert gql(f, '{ usersCount petsCount(where: {ownerIDIsNil: false, nameHasPrefix: "r"}) users(orderBy: {field: ID}, limit: 2) { name pets(orderBy: {field: NAME}, limit: 1) { name } } strays: pets(where: {ownerIDIsNil: true}) { name owner { name } } page: users(orderBy: {field: NAME, direction: DESC}, limit: 2, offset: 1) { id name } }')! == '{"data":{"usersCount":4,"petsCount":1,"users":[{"name":"ada","pets":[{"name":"rex"}]},{"name":"bob","pets":[]}],"strays":[{"name":"stray","owner":null}],"page":[{"id":"3","name":"cy"},{"id":"2","name":"bob"}]}}'
	assert f.queries() == ['users', 'pets', 'users', 'pets', 'pets', 'users']
	// O2O same type and bidirectional, M2M same type and bidirectional
	assert gql(f, '{ nodes(where: {idIn: ["1", "2"]}, orderBy: {field: ID}) { value next { value } prev { value } } users(where: {idNotIn: ["3", "4"]}, orderBy: {field: ID}) { spouse { name } following(orderBy: {field: ID}) { name } followers { name } friends { name } } }')! == '{"data":{"nodes":[{"value":1,"next":{"value":2},"prev":null},{"value":2,"next":{"value":3},"prev":{"value":1}}],"users":[{"spouse":{"name":"bob"},"following":[{"name":"bob"},{"name":"cy"}],"followers":[],"friends":[{"name":"bob"}]},{"spouse":{"name":"ada"},"following":[{"name":"cy"}],"followers":[{"name":"ada"}],"friends":[{"name":"ada"}]}]}}'
	// UUID keys
	assert gql(f, '{ devices(orderBy: {field: NAME}) { id name owner { name } logins(orderBy: {field: AT, direction: DESC}) { at } groups { name } } }')! == '{"data":{"devices":[{"id":"${laptop}","name":"laptop","owner":{"name":"ada"},"logins":[],"groups":[]},{"id":"${phone}","name":"phone","owner":{"name":"ada"},"logins":[{"at":2},{"at":1}],"groups":[{"name":"admins"},{"name":"devs"}]},{"id":"${tablet}","name":"tablet","owner":{"name":"bob"},"logins":[{"at":3}],"groups":[{"name":"devs"}]}]}}'
	assert gql(f, '{ devices(where: {id: "${tablet}"}) { name } }')! == '{"data":{"devices":[{"name":"tablet"}]}}'
	// errors
	assert gql(f, '{ users(where: {id: "abc"}) { name } }')! == '{"errors":[{"message":"invalid ID \\"abc\\"","locations":[{"line":1,"column":3}],"path":["users"]}],"data":null}'
	assert gql(f, '{ users { nope } }')! == '{"errors":[{"message":"Cannot query field \\"nope\\" on type \\"User\\". Did you mean \\"name\\"?","locations":[{"line":1,"column":11}]}]}'
}

const watch = '3c2b1a09-8f7e-4d6c-9b5a-4e3d2c1b0a9f'

fn user_names(g graph.Graph, ids []int) ![]string {
	return g.users().where_id_in(ids).order_by_id().all()!.map(it.user.name)
}

// Writes: each relationship kind through the generated builders, on a vgraph
// driver.
fn check_writes(f Fixture) ! {
	w := f.w
	// O2O two types: a new user, and a card for her; then the card moves
	eve := w.users().create().set_name('eve').save()!
	assert eve.user.id == 5
	card := w.cards().create().set_number('7777').set_owner(eve).save()!
	assert card.card.owner_id == 5
	assert w.users().where_id(5).with_card().first()!.card or { return error('no card') }.card.number == '7777'
	// `cards.owner_id` is not nullable, so a card can't be taken from its owner
	// first: the unique index refuses eve a second one, and nothing changes
	if _ := w.users().update_one_id(5).set_card_id(2).exec() {
		assert false
	}
	assert w.cards().order_by_id().all()!.map(it.card.owner_id) == [1, 2, 5]
	// with her card deleted, bob's moves to her
	card.update().exec()!
	w.cards().delete_one(card).exec()!
	w.users().update_one_id(5).set_card_id(2).exec()!
	assert w.cards().order_by_id().all()!.map(it.card.owner_id) == [1, 5]
	// O2O same type: a node after 3, then 4 set as the next of 2's previous
	four := w.nodes().create().set_value(4).save()!
	w.nodes().update_one_id(3).set_next(four).exec()!
	assert w.nodes().where_id(3).with_next().first()!.next or { return error('no next') }.node.value == 4
	// `prev` is one_to_one, and `nodes.next_id` is nullable: 4 has one previous
	// node, so 3 stops pointing at it, and 1 does
	w.nodes().update_one_id(4).set_prev_id(1).exec()!
	nodes := w.nodes().order_by_id().all()!
	assert nodes.map(it.node.next_id or { 0 }) == [4, 3, 0, 0]
	w.nodes().update_one_id(4).clear_prev().exec()!
	assert w.nodes().where_next_id(4).count()! == 0
	// O2O bidirectional (`bidi`): one write sets both sides
	w.users().update_one_id(3).set_spouse_id(4).exec()!
	assert w.users().where_id_in([3, 4]).order_by_id().all()!.map(it.user.spouse_id or { 0 }) == [
		4,
		3,
	]
	// ada marries cy: bob and dee lose their spouses
	w.users().update_one_id(1).set_spouse_id(3).exec()!
	assert w.users().order_by_id().all()!.map(it.user.spouse_id or { 0 }) == [3, 0, 1, 0, 0]
	w.users().update_one_id(3).clear_spouse().exec()!
	assert w.users().where_id_in([1, 3]).all()!.all(it.user.spouse_id == none)
	// O2M two types: add the stray, remove one, clear
	w.users().update_one_id(2).add_pets_ids(3).exec()!
	assert w.pets().where_owner_id(2).count()! == 1
	ada := w.users().where_id(1).first()!
	ada.update().remove_pets_ids(1).exec()!
	assert w.pets().where_owner_id(1).all()!.map(it.pet.name) == ['tom']
	ada.update().clear_pets().add_pets_ids(1).exec()!
	assert w.pets().where_owner_id(1).all()!.map(it.pet.name) == ['rex']
	// O2M same type: a new category under b, then a1 moved under it
	b2 := w.categories().create().set_name('b2').set_parent_id(3).save()!
	w.categories().update_one(b2).add_children_ids(4).exec()!
	tree := w.categories().where_id(3).with_children(fn (q graph.CategoryQuery) graph.CategoryQuery {
		return q.with_children()
	}).first()!
	assert tree.children.map(it.category.name) == ['b2']
	assert tree.children[0].children.map(it.category.name) == ['a1']
	// M2M two types, from both sides; a deleted group takes its join rows
	w.users().update_one_id(3).add_groups_ids(1, 2).exec()!
	assert user_names(w, w.groups().where_id(1).first()!.query_users()!.all()!.map(it.user.id))! == [
		'ada',
		'cy',
	]
	w.groups().update_one_id(2).remove_users_ids(1).exec()!
	assert w.users().where_id(1).first()!.query_groups()!.all()!.map(it.group.name) == ['admins']
	// only an admin may delete a group (`Group.policy`)
	if _ := w.groups().delete_one_id(1).exec() {
		assert false
	} else {
		assert err is vgraph.PrivacyError
	}
	w.with_ctx(models.Admin{}).groups().delete_one_id(1).exec()!
	assert w.users().where_id_in([1, 3]).with_groups().order_by_id().all()!.map(it.groups.map(it.group.name)) == [
		[]string{},
		['devs'],
	]
	// M2M same type: dee follows ada; ada now has a follower
	w.users().update_one_id(4).add_following_ids(1).exec()!
	assert w.users().where_id(1).first()!.query_followers()!.all()!.map(it.user.name) == ['dee']
	// M2M bidirectional (`bidi`): one write stores the friendship both ways
	w.users().update_one_id(1).add_friends_ids(3).exec()!
	friends := w.users().where_id_in([1, 3]).with_friends(fn (q graph.UserQuery) graph.UserQuery {
		return q.order_by_id()
	}).order_by_id().all()!
	assert friends.map(it.friends.map(it.user.name)) == [['bob', 'cy'], ['ada', 'dee']]
	// UUID keys: a device with its groups, and a login on it
	device := w.devices().create().set_id(watch).set_name('watch').set_owner_id(4).add_groups_ids(2).save()!
	assert device.device.id == watch
	login := w.logins().create().set_device(device).set_at(9).save()!
	assert login.query_device().first()!.device.name == 'watch'
	assert w.devices().where_id(watch).first()!.query_groups()!.all()!.map(it.group.name) == ['devs']
	// an upsert on the key renames the phone, and keeps its key
	renamed := w.devices().create().set_id(phone).set_name('mobile').set_owner_id(1).on_conflict_columns('id').update_new_values().save()!
	assert renamed.device.name == 'mobile'
	assert w.devices().count()! == 4
	if _ := w.devices().create().set_id(phone).set_name('x').set_owner_id(1).on_conflict_columns('id').do_nothing().save() {
		assert false
	} else {
		assert err is graph.NotFoundError
	}
	// bulk creates, in order
	pets := w.pets().create_bulk(w.pets().create().set_name('a'), w.pets().create().set_name('b').set_owner_id(4)).save()!
	assert pets.map(it.pet.name) == ['a', 'b']
	more := w.pets().map_create_bulk(['c', 'd'], fn (b graph.PetCreate, name string) graph.PetCreate {
		return b.set_name(name)
	}).save()!
	assert more.map(it.pet.id) == [pets[1].pet.id + 1, pets[1].pet.id + 2]
	// updates and deletes of many rows count them
	// tom, whom ada's pets were cleared of, and the three created without an owner
	assert w.pets().where_owner_id_is_null().update().set_owner_id(4).exec()! == 4
	assert w.pets().update().where_owner_id(4).where_name_in(['a', 'b']).set_name('ab').exec()! == 2
	assert w.pets().delete().where_name('ab').exec()! == 2
	assert w.pets().where_owner_id(4).order_by_id().all()!.map(it.pet.name) == ['tom', 'c', 'd']
	// a write to a missing row
	if _ := w.users().update_one_id(99).set_name('x').save() {
		assert false
	} else {
		assert err is graph.NotFoundError
	}
	// a failed transaction leaves nothing
	w.tx(fn (tx graph.Graph) ! {
		tx.users().create().set_name('zed').exec()!
		return error('stop')
	}) or { assert err.msg() == 'stop' }
	assert w.users().where_name('zed').count()! == 0
	// the read client sees the writes
	assert f.g.users().count()! == 5
}

// Soft delete and privacy: deleted pets are hidden everywhere, edges and
// GraphQL included, until a graph skips `soft_delete`.
fn check_soft_delete(f Fixture) ! {
	w := f.w
	w.pets().delete_one_id(1).exec()!
	assert w.pets().order_by_id().all()!.map(it.pet.name) == ['tom', 'stray']
	assert w.users().where_id(1).with_pets().first()!.pets.map(it.pet.name) == ['tom']
	assert w.users().where_id(1).first()!.query_pets().count()! == 1
	assert gql(f, '{ pets(orderBy: {field: ID}) { name } usersCount }')! == '{"data":{"pets":[{"name":"tom"},{"name":"stray"}],"usersCount":4}}'
	// a second delete finds nothing; an update leaves it alone
	if _ := w.pets().delete_one_id(1).exec() {
		assert false
	} else {
		assert err is graph.NotFoundError
	}
	assert w.pets().update().set_name('x').where_name('rex').exec()! == 0
	all := w.skip('soft_delete').pets().order_by_id().all()!
	assert all.map(it.pet.name) == ['rex', 'tom', 'stray']
	assert all.map(it.pet.deleted_at != none) == [true, false, false]
	// skipped, a delete is a delete
	assert w.skip('soft_delete').pets().delete().where_deleted_at_is_not_null().exec()! == 1
	assert w.skip('soft_delete').pets().count()! == 2
}

struct UserName {
	name string
}

struct LoginGroup {
	device_id string
	count     int
	sum_at    f64
}

fn ids_of(users []graph.UserNode) []int {
	return users.map(it.user.id)
}

// Queries (6b): edge predicates and traversal from a query for each kind,
// predicates, results, aggregates, orders, locks and named edges. Each runs on
// the client without a driver (`f.g`, whose selects are logged) and on the one
// with a driver (`f.w`).
fn check_queries(f Fixture) ! {
	driver := f.w.client.conn as vgraph.Driver
	on_pg := driver.dialect() == .pg
	for with_driver in [false, true] {
		g := if with_driver { f.w } else { f.g }
		f.queries()
		// O2O two types
		assert names(g.users().has_card().order_by_id().all()!) == ['ada', 'bob']
		if !with_driver {
			// the cards' owners first, then the users
			assert f.queries() == ['cards', 'users']
		}
		assert names(g.users().where(load.not(graph.user_has_card())).order_by_id().all()!) == [
			'cy',
			'dee',
		]
		assert g.cards().has_owner_with(fn (q graph.UserQuery) graph.UserQuery {
			return q.where_name('bob')
		}).all()!.map(it.card.number) == ['5555']
		// O2O same type, and bidirectional
		assert g.nodes().has_prev().order_by_id().ids()! == [2, 3]
		assert g.nodes().where(graph.node_has_next_with(graph.node_value_eq(3))).ids()! == [2]
		assert names(g.users().has_spouse().order_by_id().all()!) == ['ada', 'bob']
		// O2M two types, both ways, and traversal from a query
		assert names(g.users().has_pets().all()!) == ['ada']
		assert g.pets().has_owner().order_by_id().all()!.map(it.pet.name) == ['rex', 'tom']
		f.queries()
		assert g.users().where_name('ada').query_pets().order_by_name().all()!.map(it.pet.name) == [
			'rex',
			'tom',
		]
		if !with_driver {
			assert f.queries() == ['users', 'pets']
		}
		assert names(g.pets().where_name_in(['rex', 'stray']).query_owner().all()!) == ['ada']
		// O2M same type, two levels
		assert g.categories().has_children().order_by_id().all()!.map(it.category.name) == [
			'root',
			'a',
		]
		assert g.categories().where_name('root').query_children().query_children().all()!.map(it.category.name) == [
			'a1',
		]
		// M2M two types, same type, bidirectional
		assert names(g.users().has_groups_with(fn (q graph.GroupQuery) graph.GroupQuery {
			return q.where_name('admins')
		}).all()!) == ['ada']
		assert names(g.groups().where_name('devs').query_users().order_by_id().all()!) == [
			'ada',
			'bob',
		]
		assert names(g.users().has_followers().order_by_id().all()!) == ['bob', 'cy']
		assert names(g.users().where_name('ada').query_following().order_by_id().all()!) == [
			'bob',
			'cy',
		]
		assert names(g.users().where_name('cy').query_friends().all()!) == ['dee']
		// UUID keys
		assert g.devices().has_logins().order_by_name().all()!.map(it.device.name) == [
			'phone',
			'tablet',
		]
		assert g.users().where_name('ada').query_devices().query_logins().count()! == 2
		assert g.groups().where(graph.group_has_devices_with(graph.device_name_eq('tablet'))).all()!.map(it.group.name) == [
			'devs',
		]
		// and, or, not; string predicates
		assert names(g.users().where(load.or(graph.user_name_eq('ada'), graph.user_name_eq('dee'))).order_by_id().all()!) == [
			'ada',
			'dee',
		]
		assert names(g.users().where(load.not(load.or(graph.user_name_eq('ada'), graph.user_id_gt(3)))).order_by_id().all()!) == [
			'bob',
			'cy',
		]
		assert names(g.users().where_name_contains('d').order_by_id().all()!) == ['ada', 'dee']
		assert names(g.users().where_name_has_prefix('b').all()!) == ['bob']
		assert names(g.users().where_name_ne('ada').where_id_not_in([4]).order_by_id().all()!) == [
			'bob',
			'cy',
		]
		if with_driver {
			assert names(g.users().where_name_equal_fold('ADA').all()!) == ['ada']
			assert names(g.users().where_name_contains_fold('E').all()!) == ['dee']
			// `%` is itself, not a wildcard
			assert g.users().where_name_contains('%').count()! == 0
			assert names(g.users().where(load.raw('length(name) = ?', 2)).all()!) == ['cy']
		} else {
			for refused in [
				g.users().where_name_equal_fold('ADA'),
				g.users().where_name_contains('%'),
				g.users().where(load.raw('length(name) = ?', 2)),
				g.users().order_by_name().order_by_id(),
			] {
				if _ := refused.all() {
					assert false
				} else {
					assert err.msg().contains('vgraph driver')
				}
			}
		}
		// results
		assert g.users().where_name('ada').only()!.user.id == 1
		if _ := g.users().only() {
			assert false
		} else {
			assert err is graph.NotSingularError
		}
		assert g.users().order_by_name_desc().ids()! == [4, 3, 2, 1]
		assert g.users().order_by_id_desc().first_id()! == 4
		assert g.users().where_name('cy').only_id()! == 3
		assert g.users().where_name('cy').exist()!
		assert !g.users().where_name('zed').exist()!
		selected := g.users().select('name').where_id(1).first()!
		assert selected.user.name == 'ada'
		assert selected.user.spouse_id == none, 'not read'
		assert g.pets().has_owner().unique().scan[UserName]()!.len == 2
		assert g.users().where_id_lt(3).order_by_id().scan[UserName]()!.map(it.name) == [
			'ada',
			'bob',
		]
		// aggregates
		assert g.logins().sum_at()! == 6
		assert g.logins().min_at()! == 1
		assert g.logins().max_at()! == 3
		assert g.logins().mean_at()! == 2
		assert g.logins().where_at_gt(1).sum_at()! == 5
		if with_driver {
			groups := g.logins().group_by('device_id').aggregate(vgraph.count(), vgraph.sum('at')).all()!
			assert groups.map('${it.key['device_id'] or { orm.Null{} }} ${it.values['count']} ${it.values['sum_at']}') == [
				"Primitive('${phone}') 2.0 3.0",
				"Primitive('${tablet}') 1.0 3.0",
			]
			scanned := g.logins().group_by('device_id').aggregate(vgraph.count(), vgraph.sum('at')).scan[LoginGroup]()!
			assert scanned == [LoginGroup{phone, 2, 3}, LoginGroup{tablet, 1, 3}]
		} else {
			if _ := g.logins().group_by('device_id').all() {
				assert false
			} else {
				assert err.msg().contains('vgraph driver')
			}
		}
		// orders by more than one column, by an edge, nulls last
		if with_driver {
			assert ids_of(g.users().order_by_pets_count_desc().order_by_id().all()!) == [
				1,
				2,
				3,
				4,
			]
			assert ids_of(g.users().order_by_followers_count_desc().order_by_id().all()!) == [
				3,
				2,
				1,
				4,
			]
			assert g.cards().order_by_owner_name_desc().all()!.map(it.card.number) == [
				'5555',
				'4242',
			]
			// users without a card sort as nulls do, which differs by database
			assert ids_of(g.users().order_by_card_number_desc().order_by_id().all()!).filter(it <= 2) == [
				2,
				1,
			]
			assert g.pets().order_by(vgraph.asc('owner_id').nulls_last(), vgraph.asc('id')).all()!.map(it.pet.name) == [
				'rex',
				'tom',
				'stray',
			]
			// a lock needs a transaction, and PostgreSQL
			if _ := g.users().for_update().all() {
				assert false
			} else {
				assert err.msg().contains('transaction')
			}
			g.tx(fn [on_pg] (tx graph.Graph) ! {
				locked := tx.users().where_id(1).for_update().no_wait().all() or {
					assert !on_pg
					assert err.msg().contains('SQLite has no row locks')
					return
				}
				assert on_pg
				assert names(locked) == ['ada']
				assert names(tx.users().where_id(2).for_share().skip_locked().all()!) == ['bob']
			})!
		}
		// named edges, and edges not loaded
		ada := g.users().where_id(1).with_pets().with_named_pets('r', fn (q graph.PetQuery) graph.PetQuery {
			return q.where_name_has_prefix('r')
		}).with_named_pets('none', fn (q graph.PetQuery) graph.PetQuery {
			return q.where_name('zed')
		}).first()!
		assert ada.named_pets['r'].map(it.pet.name) == ['rex']
		assert ada.named_pets['none'].len == 0
		assert ada.pets_or_err()!.len == 2
		if _ := ada.card_or_err() {
			assert false
		} else {
			assert err is graph.NotLoadedError
		}
		cy := g.users().where_id(3).with_card().first()!
		if _ := cy.card_or_err() {
			assert false
		} else {
			assert err is graph.NotFoundError
		}
	}
}

// The schema options of 6d: every field type, JSON, a mixin, declared and
// partial indexes, an edge schema, a required and immutable edge, global ids
// and a view.
fn check_schema(f Fixture) ! {
	w := f.w
	driver := f.w.client.conn as vgraph.Driver
	on_pg := driver.dialect() == .pg
	g1 := w.gadgets().create().set_owner_id(1).set_serial_no('S-1').set_color(.green).set_level(-3).set_weight(500).set_parts(70000).set_big(9_000_000_000).set_ratio(0.5).set_rating(4.5).set_tags_value([
		'new',
	]).save()!
	// a global id: the first table with an i64 serial key counts from 1 << 32
	assert g1.gadget.id == (i64(1) << 32) + 1
	assert w.client.table_of(g1.gadget.id)! == 'gadgets'
	g := w.gadgets().where_id(g1.gadget.id).first()!.gadget
	assert g.serial_no == 'S-1'
	assert g.color == .green
	assert g.level == -3
	assert g.weight == 500
	assert g.parts == 70000
	assert g.big == 9_000_000_000
	assert g.ratio == 0.5
	assert (g.rating or { 0 }) == 4.5
	assert g.score == none && g.active == none
	// the mixin's fields, set by its options
	assert g.created_at.unix() > 0
	assert g.updated_at.unix() - g.created_at.unix() <= 1
	// JSON
	assert w.gadgets().where_id(g.id).first()!.tags_value()! == ['new']
	w.gadgets().update_one_id(g.id).append_tags('used', 'blue').exec()!
	assert w.gadgets().where_id(g.id).first()!.tags_value()! == ['new', 'used', 'blue']
	// predicates, orders and aggregates on the new types
	w.gadgets().create().set_owner_id(2).set_serial_no('S-2').set_color(.red).set_level(2).set_weight(100).set_parts(1).set_big(1).set_ratio(1.5).set_score(7).set_active(true).set_tags('[]').exec()!
	assert w.gadgets().where_color(.red).only()!.gadget.serial_no == 'S-2'
	assert w.gadgets().where_color_in([.green, .blue]).count()! == 1
	assert w.gadgets().where_serial_no(models.Serial('S-1')).count()! == 1
	assert w.gadgets().where_level_lt(0).count()! == 1
	assert w.gadgets().where_big_gt(1).count()! == 1
	assert w.gadgets().where_active(true).count()! == 1
	assert w.gadgets().where_score_is_null().count()! == 1
	assert w.gadgets().sum_weight()! == 600
	assert w.gadgets().order_by_color().all()!.map(it.gadget.serial_no) == ['S-2', 'S-1']
	// a declared unique index
	if _ := w.gadgets().create().set_owner_id(3).set_serial_no('S-1').set_tags('[]').exec() {
		assert false
	}
	// a required edge, and an immutable one
	if _ := w.gadgets().create().set_serial_no('S-3').set_tags('[]').exec() {
		assert false
	} else {
		assert err.msg() == '`gadgets.owner_id`: the edge `owner` is required'
	}
	if _ := w.client.update_one(vgraph.MutationData{
		table:   'gadgets'
		row_key: g.id.str()
		values:  {
			'owner_id': orm.Primitive(2)
		}
	})
	{
		assert false
	} else {
		assert err.msg() == '`gadgets.owner_id`: the edge `owner` is immutable'
	}
	// an edge schema: a like is a row of its own, with its default
	w.users().update_one_id(1).add_liked_gadgets_ids(g.id).exec()!
	likes := w.likes().with_user().with_gadget().all()!
	assert likes.len == 1
	assert likes[0].like.liked_at.unix() > 0
	assert names(w.gadgets().where_id(g.id).first()!.query_likers()!.all()!) == ['ada']
	assert w.users().where_id(1).first()!.query_liked_gadgets()!.ids()! == [g.id]
	// the partial index exists
	query := if on_pg {
		'SELECT indexname FROM pg_indexes WHERE indexname = \$1'
	} else {
		"SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?"
	}
	mut d := driver
	assert d.exec_params(query, ['gadgets_rated_owner_idx'])!.len == 1
	// a view: queries, edges and GraphQL
	owners := f.g.pet_owners().with_owner().order_by_id().all()!
	assert owners.map('${it.owned_pet.pet_name} ${it.owned_pet.owner_name}') == [
		'rex ada',
		'tom ada',
	]
	assert owners.map(if o := it.owner { o.user.id } else { 0 }) == [1, 1]
	assert gql(f, '{ petOwners(orderBy: {field: ID}) { petName owner { name } } }')! == '{"data":{"petOwners":[{"petName":"rex","owner":{"name":"ada"}},{"petName":"tom","owner":{"name":"ada"}}]}}'
	assert gql(f, '{ gadgets(where: {color: RED}) { serialNo color tags level big } }')! == '{"data":{"gadgets":[{"serialNo":"S-2","color":"RED","tags":[],"level":2,"big":1}]}}'
}
