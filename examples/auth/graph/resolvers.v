// Resolvers resolves the fields that this project's .graphql files add to the
// schema. `vgraph gen` wrote this file, and adds a method here for each new
// field; it never changes what is already here. Give `Resolvers` whatever
// its methods need, such as the graph. A method reads and writes through
// `graph.with_ctx(ctx)`: in a mutation, that is the request's transaction.
module graph

import context
import time
import five07.vgraph.graphql
import auth

// Resolvers has what `me` and `login` need: the graph, and the key and
// lifetime of the tokens `login` issues.
pub struct Resolvers {
pub:
	g      Graph
	secret []u8
	ttl    time.Duration = time.hour
}

// query_me resolves `Query.me`: `me: User`.
pub fn (r Resolvers) query_me(ctx context.Context, _ graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	viewer := auth.viewer_of(ctx)
	if viewer.anonymous() {
		return parents.map(graphql.null)
	}
	user := r.g.with_ctx(ctx).users().where_id(viewer.id).first() or {
		return parents.map(graphql.null)
	}
	return parents.map(graphql.obj(user))
}

// mutation_login resolves `Mutation.login`: `login(email: String!, password: String!): String!`.
// It reads the user through a privileged graph, which skips privacy rules:
// whoever is asking, the email and the hash decide. Either one wrong gives the
// same error, so it doesn't tell which emails have accounts.
pub fn (r Resolvers) mutation_login(ctx context.Context, info graphql.FieldInfo, parents []graphql.Source) ![]graphql.Resolved {
	email := info.arg('email').as_string().trim_space()
	user := r.g.with_ctx(ctx).privileged().users().where_email(email).first() or {
		return error('wrong email or password')
	}
	if !auth.check_password(info.arg('password').as_string(), user.user.password) {
		return error('wrong email or password')
	}
	token := auth.issue(user.user.id, user.user.admin, r.ttl, time.now(), r.secret)
	return parents.map(graphql.Resolved(graphql.Value(token)))
}
