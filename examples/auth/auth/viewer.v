module auth

import context
import crypto.bcrypt
import os

// Viewer is who a request runs as: a user, an admin, or no one (`id` 0). The
// HTTP handler makes one from the request's token and puts it in the
// request's context (`with_viewer`), which the GraphQL server passes to hooks
// and privacy rules.
pub struct Viewer {
pub:
	id    i64
	admin bool
}

// viewer_key_cell exists for its address, which is the context key of the
// viewer: no other module can make the same key.
const viewer_key_cell = u8(1)

fn viewer_key() context.Key {
	return voidptr(&viewer_key_cell)
}

// with_viewer returns `ctx` running as `v`.
pub fn with_viewer(ctx context.Context, v Viewer) context.Context {
	return context.with_value(ctx, viewer_key(), v)
}

// viewer_of returns the viewer of the context `ctx`: the anonymous one when
// it has none, such as a write the app makes itself.
pub fn viewer_of(ctx context.Context) Viewer {
	if value := ctx.value(viewer_key()) {
		if value is Viewer {
			return value
		}
	}
	return Viewer{}
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
