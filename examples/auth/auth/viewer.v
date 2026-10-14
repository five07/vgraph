module auth

import crypto.bcrypt
import os
import five07.vgraph.graphql

// Viewer is who a request runs as: a user, an admin, or no one (`id` 0). The
// HTTP handler makes one from the request's token, and the GraphQL server
// passes it to hooks and privacy rules as the request's context.
pub struct Viewer {
pub:
	id    i64
	admin bool
}

// viewer_of returns the viewer of the context `ctx`: the anonymous one when
// it isn't a `Viewer`, such as a write the app makes itself.
pub fn viewer_of(ctx graphql.Context) Viewer {
	return if ctx is Viewer { ctx } else { Viewer{} }
}

// anonymous reports whether no one is logged in.
pub fn (v Viewer) anonymous() bool {
	return v.id == 0
}

// hash_password returns the bcrypt hash of `password`. Its cost comes from
// `BCRYPT_COST` (10 when unset): the tests lower it.
pub fn hash_password(password string) !string {
	cost := (os.getenv_opt('BCRYPT_COST') or { '10' }).int()
	return bcrypt.generate_from_password(password.bytes(), cost)
}

// check_password reports whether `password` is the one `hash` was made from.
pub fn check_password(password string, hash string) bool {
	bcrypt.compare_hash_and_password(password.bytes(), hash.bytes()) or { return false }
	return true
}
