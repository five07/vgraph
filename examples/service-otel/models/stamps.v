module models

import context
import orm
import time
import five07.vgraph

// Stamps is a mixin: the times of every model that embeds it, set by its field
// options when a row is created and updated.
pub struct Stamps {
pub:
	created_at time.Time
	updated_at time.Time
}

// fields sets `created_at` on create, and `updated_at` on create and update;
// GraphQL's inputs leave them out, as the server owns them.
pub fn (s Stamps) fields() []vgraph.Field {
	return [
		vgraph.Field{
			name:            'created_at'
			default_now:     true
			immutable:       true
			graphql_skip_in: server_owned
		},
		vgraph.Field{
			name:            'updated_at'
			default_now:     true
			update_now:      true
			graphql_skip_in: server_owned
		},
	]
}

// server_owned leaves a field out of GraphQL's inputs: only the server sets it.
pub const server_owned = [vgraph.GraphqlSkip.create_input, .update_input]

// deleted_at is the option of a model's `deleted_at`, which only a delete
// sets.
pub const deleted_at = vgraph.Field{
	name:            'deleted_at'
	graphql_skip_in: server_owned
}

// normalize returns a hook that runs `f` on the values a create or an update
// sets, before the checks of the fields' options, such as to trim a title.
pub fn normalize(f fn (mut m vgraph.Mutation)) vgraph.Hook {
	return vgraph.Hook{
		name: 'normalize'
		on:   [.create, .update_one, .update]
		run:  fn [f] (next vgraph.Mutate) vgraph.Mutate {
			return fn [f, next] (ctx context.Context, mut m vgraph.Mutation) ! {
				f(mut m)
				next(ctx, mut m)!
			}
		}
	}
}

// soft_delete_query returns the interceptor that leaves rows whose
// `deleted_at` is set out of queries, but not out of edge loads, so a record
// still shows the deleted author, article or post it refers to. Lists on edges
// leave deleted rows out with `Edge.soft_del`.
pub fn soft_delete_query() vgraph.Interceptor {
	return vgraph.Interceptor{
		...vgraph.soft_delete_query('deleted_at')
		edges: false
	}
}

// trim returns a hook that trims the spaces around the string values a create
// or an update sets in `columns`.
pub fn trim(columns ...string) vgraph.Hook {
	return normalize(fn [columns] (mut m vgraph.Mutation) {
		for column in columns {
			if value := m.field_value(column) {
				if value is string {
					m.set_field_value(column, value.trim_space())
				}
			}
		}
	})
}

// not_blank checks that a string isn't empty or only spaces, as a field's
// `validate`.
pub fn not_blank(value orm.Primitive) ! {
	if value is string && value.trim_space() == '' {
		return error('is blank')
	}
}
