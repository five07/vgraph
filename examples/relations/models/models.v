// Package models declares one struct per table, with the edges between them.
// Each edge is one of the Ent relationship kinds; see the README.
module models

import five07.vgraph

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
// same type) and friends (M2M bidirectional).
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

// Pet has at most one owner, who can have many pets.
@[table: 'pets']
pub struct Pet {
pub:
	id       int @[primary; sql: serial]
	name     string
	owner_id ?int
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

// Group has many users, who can be in many groups.
@[table: 'groups']
pub struct Group {
pub:
	id   int @[primary; sql: serial]
	name string
}

// edges declares a group's users, the other side of `User.groups`.
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
