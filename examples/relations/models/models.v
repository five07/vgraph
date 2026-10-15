// Package models declares one struct per table, with the edges between them.
// Each edge is one of the Ent relationship kinds; see the README.
module models

import context
import five07.vgraph
import time

// User is in nearly every kind of relationship.
@[table: 'users']
pub struct User {
pub:
	id        int @[primary; sql: serial]
	name      string
	spouse_id ?int
}

// edges declares a user's card (O2O two types), spouse (O2O bidirectional),
// pets (O2M two types), groups (M2M two types), following and followers (M2M
// same type), friends (M2M bidirectional), and devices, which have UUID keys.
pub fn (u User) edges() []vgraph.Edge {
	return [
		// O2O two types: the card holds the user's id
		vgraph.Edge{
			name:   'card'
			kind:   .one_to_one
			to:     'cards'
			column: 'owner_id'
		},
		// O2O bidirectional: each spouse holds the other's id. `unique` makes it
		// one to one (a unique index on `spouse_id`), and `bidi` sets both sides
		vgraph.Edge{
			name:   'spouse'
			kind:   .many_to_one
			to:     'users'
			column: 'spouse_id'
			unique: true
			bidi:   true
		},
		// O2M two types
		vgraph.Edge{
			name:   'pets'
			kind:   .one_to_many
			to:     'pets'
			column: 'owner_id'
			ref:    'owner'
		},
		// M2M two types
		vgraph.Edge{
			name:       'groups'
			kind:       .many_to_many
			to:         'groups'
			column:     'user_id'
			through:    'group_users'
			through_to: 'group_id'
			ref:        'users'
		},
		// M2M same type, both directions through one join table
		vgraph.Edge{
			name:       'following'
			kind:       .many_to_many
			to:         'users'
			column:     'follower_id'
			through:    'follows'
			through_to: 'followee_id'
			ref:        'followers'
		},
		vgraph.Edge{
			name:       'followers'
			kind:       .many_to_many
			to:         'users'
			column:     'followee_id'
			through:    'follows'
			through_to: 'follower_id'
			ref:        'following'
		},
		// M2M bidirectional: a friendship is stored in both directions, which a
		// write does
		vgraph.Edge{
			name:       'friends'
			kind:       .many_to_many
			to:         'users'
			column:     'user_id'
			through:    'friendships'
			through_to: 'friend_id'
			bidi:       true
		},
		// O2M to a table with UUID keys
		vgraph.Edge{
			name:   'devices'
			kind:   .one_to_many
			to:     'devices'
			column: 'owner_id'
		},
		// gadgets: every other field type (6d)
		vgraph.Edge{
			name:   'gadgets'
			kind:   .one_to_many
			to:     'gadgets'
			column: 'owner_id'
			ref:    'owner'
		},
		// an edge schema: a like is a row of its own, with a time
		vgraph.Edge{
			name:       'liked_gadgets'
			kind:       .many_to_many
			to:         'gadgets'
			column:     'user_id'
			through:    'likes'
			through_to: 'gadget_id'
		},
	]
}

// Card belongs to one user, who has at most one card.
@[table: 'cards']
pub struct Card {
pub:
	id       int @[primary; sql: serial]
	number   string
	owner_id int
}

// edges declares a card's owner, the other side of `User.card`.
pub fn (c Card) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'owner'
			kind:   .many_to_one
			to:     'users'
			column: 'owner_id'
		},
	]
}

// Pet has at most one owner, who can have many pets. Deleting a pet only marks
// it deleted: see `hooks` and `interceptors`.
@[table: 'pets']
pub struct Pet {
pub:
	id         int @[primary; sql: serial]
	name       string
	owner_id   ?int
	deleted_at ?time.Time
}

// hooks turns a pet's delete into setting `deleted_at`.
pub fn (p Pet) hooks() []vgraph.Hook {
	return [vgraph.soft_delete_hook('deleted_at')]
}

// interceptors leaves deleted pets out of every query.
pub fn (p Pet) interceptors() []vgraph.Interceptor {
	return [vgraph.soft_delete_query('deleted_at')]
}

// edges declares a pet's owner, the other side of `User.pets`. GraphQL can
// order pets by their owner's name.
pub fn (p Pet) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:        'owner'
			kind:        .many_to_one
			to:          'users'
			column:      'owner_id'
			ref:         'pets'
			order_field: 'name'
		},
	]
}

// Group has many users, who can be in many groups. Only an admin may delete one:
// see `policy`.
@[table: 'groups']
pub struct Group {
pub:
	id   int @[primary; sql: serial]
	name string
}

// Admin marks a request by an administrator, as a value in its context.
pub struct Admin {}

const admin_key = 'admin'

// as_admin returns a context for a request by an administrator.
pub fn as_admin() context.Context {
	return context.with_value(context.background(), admin_key, Admin{})
}

// is_admin reports whether `ctx` is an administrator's.
pub fn is_admin(ctx context.Context) bool {
	if value := ctx.value(admin_key) {
		return value is Admin
	}
	return false
}

// otel records a span per query, write and edge load of groups, and of their
// hooks, interceptors and privacy rules, when the app gives a tracer provider.
pub fn (g Group) otel() vgraph.Otel {
	return vgraph.Otel{
		level: .full
	}
}

// policy lets only an admin delete groups.
pub fn (g Group) policy() vgraph.Policy {
	return vgraph.Policy{
		mutation: [
			fn (ctx context.Context, m vgraph.Mutation) !vgraph.Decision {
				if m.operation() !in [.delete, .delete_one] {
					return .skip
				}
				return if is_admin(ctx) { .allow } else { .deny }
			},
		]
	}
}

// edges declares a group's users, the other side of `User.groups`, and its
// devices, the other side of `Device.groups`.
pub fn (g Group) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:       'users'
			kind:       .many_to_many
			to:         'users'
			column:     'group_id'
			through:    'group_users'
			through_to: 'user_id'
			ref:        'groups'
		},
		vgraph.Edge{
			name:       'devices'
			kind:       .many_to_many
			to:         'devices'
			column:     'group_id'
			through:    'device_groups'
			through_to: 'device_id'
		},
	]
}

// GroupUser links a group and a user.
@[table: 'group_users']
pub struct GroupUser {
pub:
	id       int @[primary; sql: serial]
	group_id int
	user_id  int
}

// Follow says that `follower_id` follows `followee_id`.
@[table: 'follows']
pub struct Follow {
pub:
	id          int @[primary; sql: serial]
	follower_id int
	followee_id int
}

// Friendship says that `user_id` and `friend_id` are friends. Each friendship
// is stored twice, once in each direction.
@[table: 'friendships']
pub struct Friendship {
pub:
	id        int @[primary; sql: serial]
	user_id   int
	friend_id int
}

// Node is an item of a linked list: O2O same type.
@[table: 'nodes']
pub struct Node {
pub:
	id      int @[primary; sql: serial]
	value   int
	next_id ?int
}

// graphql renames the type and its root field in GraphQL: `Node` and `nodes`
// are the Node interface's, which gadgets implement.
pub fn (n Node) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		type_name:   'ListNode'
		query_field: 'listNodes'
	}
}

// edges declares a node's next node, and the previous node, which holds this
// node's id as its `next_id`.
pub fn (n Node) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'next'
			kind:   .many_to_one
			to:     'nodes'
			column: 'next_id'
		},
		vgraph.Edge{
			name:   'prev'
			kind:   .one_to_one
			to:     'nodes'
			column: 'next_id'
		},
	]
}

// Category is a tree: O2M same type.
@[table: 'categories']
pub struct Category {
pub:
	id        int @[primary; sql: serial]
	name      string
	parent_id ?int
}

// edges declares a category's parent and children.
pub fn (c Category) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'parent'
			kind:   .many_to_one
			to:     'categories'
			column: 'parent_id'
		},
		vgraph.Edge{
			name:   'children'
			kind:   .one_to_many
			to:     'categories'
			column: 'parent_id'
		},
	]
}

// Device is keyed by a UUID: a string, stored as `uuid` on PostgreSQL. It has
// edges of every kind, so each runs on a string key.
@[table: 'devices']
pub struct Device {
pub:
	id       string @[primary; sql_type: 'uuid']
	name     string
	owner_id int
}

// edges declares a device's owner (the other side of `User.devices`), its logins,
// which hold its UUID, and its groups, through a join table with a UUID column
// and an int column.
pub fn (d Device) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'owner'
			kind:   .many_to_one
			to:     'users'
			column: 'owner_id'
		},
		vgraph.Edge{
			name:   'logins'
			kind:   .one_to_many
			to:     'logins'
			column: 'device_id'
		},
		vgraph.Edge{
			name:       'groups'
			kind:       .many_to_many
			to:         'groups'
			column:     'device_id'
			through:    'device_groups'
			through_to: 'group_id'
		},
	]
}

// Login is one sign-in from a device.
@[table: 'logins']
pub struct Login {
pub:
	id        int    @[primary; sql: serial]
	device_id string @[sql_type: 'uuid']
	at        int
}

// edges declares a login's device, the other side of `Device.logins`.
pub fn (l Login) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'device'
			kind:   .many_to_one
			to:     'devices'
			column: 'device_id'
		},
	]
}

// DeviceGroup links a device and a group.
@[table: 'device_groups']
pub struct DeviceGroup {
pub:
	id        int    @[primary; sql: serial]
	device_id string @[sql_type: 'uuid']
	group_id  int
}

// Color is a gadget's color: an enum, stored as an integer.
pub enum Color {
	red
	green
	blue
}

// Serial is a gadget's serial number: an alias of string.
pub type Serial = string

// Stamps is a mixin: the times every table that embeds it has, set by their
// field options.
pub struct Stamps {
pub:
	created_at time.Time
	updated_at time.Time
}

// fields sets the times on create and update.
pub fn (s Stamps) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:        'created_at'
			default_now: true
			immutable:   true
		},
		vgraph.Field{
			name:        'updated_at'
			default_now: true
			update_now:  true
		},
	]
}

// Gadget has every field type the others don't: sized and unsigned integers,
// `f32`, an enum, an alias, options, JSON, and a mixin. Its `i64` key is a
// globally unique id (see `migrate`).
@[table: 'gadgets']
pub struct Gadget {
	Stamps
pub:
	id        i64 @[primary; sql: serial]
	owner_id  int
	serial_no Serial
	color     Color
	level     i8
	weight    u16
	parts     u32
	big       u64
	ratio     f32
	rating    ?f64
	score     ?i64
	active    ?bool
	tags      string
}

// fields: `tags` holds a JSON list of strings; and GraphQL's description of
// `level`, deprecation of `ratio` and name for ordering by `serial_no`.
pub fn (g Gadget) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name: 'tags'
			json: '[]string'
		},
		vgraph.Field{
			name:    'level'
			comment: 'How far up the gadget is, from -128 to 127.'
		},
		vgraph.Field{
			name:       'ratio'
			deprecated: 'Use `rating`.'
		},
		vgraph.Field{
			name:        'serial_no'
			order_field: 'SERIAL'
		},
	]
}

// graphql: gadgets have global ids, so they are Nodes, and their lists are
// Relay connections.
pub fn (g Gadget) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		node:  true
		relay: true
	}
}

// edges declares a gadget's owner, which every gadget has, and which doesn't
// change, and the users who like it, through `Like`.
pub fn (g Gadget) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:      'owner'
			kind:      .many_to_one
			to:        'users'
			column:    'owner_id'
			ref:       'gadgets'
			required:  true
			immutable: true
		},
		vgraph.Edge{
			name:       'likers'
			kind:       .many_to_many
			to:         'users'
			column:     'gadget_id'
			through:    'likes'
			through_to: 'user_id'
			ref:        'liked_gadgets'
		},
	]
}

// indexes: serial numbers are unique, and rated gadgets are looked up by owner.
pub fn (g Gadget) indexes() []vgraph.Index {
	return [
		vgraph.Index{
			columns: ['serial_no']
			unique:  true
		},
		vgraph.Index{
			name:    'gadgets_rated_owner_idx'
			columns: ['owner_id']
			where:   'rating IS NOT NULL'
		},
	]
}

// Like is the join row of `User.liked_gadgets`: an edge schema, with a time
// of its own.
@[table: 'likes']
pub struct Like {
pub:
	id        int @[primary; sql: serial]
	user_id   int
	gadget_id i64
	liked_at  time.Time
}

// fields sets when a like happened.
pub fn (l Like) fields() []vgraph.Field {
	return [vgraph.Field{
		name:        'liked_at'
		default_now: true
	}]
}

// edges declares a like's user and gadget.
pub fn (l Like) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'user'
			kind:   .many_to_one
			to:     'users'
			column: 'user_id'
		},
		vgraph.Edge{
			name:   'gadget'
			kind:   .many_to_one
			to:     'gadgets'
			column: 'gadget_id'
		},
	]
}

// OwnedPet reads the view `pet_owners`: each pet with an owner, and the
// owner's name.
@[table: 'pet_owners'; vgraph: 'view']
pub struct OwnedPet {
pub:
	id         int
	pet_name   string
	owner_id   int
	owner_name string
}

// edges declares an owned pet's owner.
pub fn (p OwnedPet) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'owner'
			kind:   .many_to_one
			to:     'users'
			column: 'owner_id'
		},
	]
}
