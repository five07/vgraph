// Package models declares one struct per table, with the edges between them.
// Each edge is one of the Ent relationship kinds; see the README.
module models

import five07.vgraph
import five07.vgraph.graphql
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
		// O2O bidirectional: each spouse holds the other's id
		vgraph.Edge{
			name:   'spouse'
			kind:   .many_to_one
			to:     'users'
			column: 'spouse_id'
		},
		// O2M two types
		vgraph.Edge{
			name:   'pets'
			kind:   .one_to_many
			to:     'pets'
			column: 'owner_id'
		},
		// M2M two types
		vgraph.Edge{
			name:       'groups'
			kind:       .many_to_many
			to:         'groups'
			column:     'user_id'
			through:    'group_users'
			through_to: 'group_id'
		},
		// M2M same type, both directions through one join table
		vgraph.Edge{
			name:       'following'
			kind:       .many_to_many
			to:         'users'
			column:     'follower_id'
			through:    'follows'
			through_to: 'followee_id'
		},
		vgraph.Edge{
			name:       'followers'
			kind:       .many_to_many
			to:         'users'
			column:     'followee_id'
			through:    'follows'
			through_to: 'follower_id'
		},
		// M2M bidirectional: a friendship is stored in both directions
		vgraph.Edge{
			name:       'friends'
			kind:       .many_to_many
			to:         'users'
			column:     'user_id'
			through:    'friendships'
			through_to: 'friend_id'
		},
		// O2M to a table with UUID keys
		vgraph.Edge{
			name:   'devices'
			kind:   .one_to_many
			to:     'devices'
			column: 'owner_id'
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

// edges declares a pet's owner, the other side of `User.pets`.
pub fn (p Pet) edges() []vgraph.Edge {
	return [
		vgraph.Edge{
			name:   'owner'
			kind:   .many_to_one
			to:     'users'
			column: 'owner_id'
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

// Admin is the context of a request by an administrator.
pub struct Admin {}

// policy lets only an admin delete groups.
pub fn (g Group) policy() vgraph.Policy {
	return vgraph.Policy{
		mutation: [
			fn (ctx graphql.Context, m vgraph.Mutation) !vgraph.Decision {
				if m.operation() !in [.delete, .delete_one] {
					return .skip
				}
				return if ctx is Admin { .allow } else { .deny }
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
