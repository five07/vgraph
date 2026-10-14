// Package auth holds what the example needs to know who is asking: HS256
// JSON Web Tokens (RFC 7519) made with V's own crypto, the viewer a request
// runs as, and password hashes. vgraph doesn't authenticate: it passes the
// viewer to hooks and privacy rules as the request's context.
module auth

import crypto.hmac
import crypto.sha256
import encoding.base64
import json2
import time

// Claims are what a token says: whose it is (`sub`, a user id), whether they
// are an admin, and when it was issued and expires, in Unix seconds.
pub struct Claims {
pub:
	sub   i64
	admin bool
	iat   i64
	exp   i64
}

struct Header {
	alg string
	typ string
}

const header = base64.url_encode_str('{"alg":"HS256","typ":"JWT"}')

// TokenError is the error of a token that can't be trusted: malformed,
// signed with another key or algorithm, or expired.
pub struct TokenError {
	Error
pub:
	reason string
}

// msg says what is wrong with the token.
pub fn (e TokenError) msg() string {
	return e.reason
}

// sign returns a token for `claims`, signed with `secret`.
pub fn sign(claims Claims, secret []u8) string {
	body := '${header}.${base64.url_encode_str(json2.encode(claims))}'
	return '${body}.${base64.url_encode(signature(body, secret))}'
}

// issue returns a token for the user `id`, valid for `ttl` from `now`.
pub fn issue(id i64, admin bool, ttl time.Duration, now time.Time, secret []u8) string {
	return sign(Claims{
		sub:   id
		admin: admin
		iat:   now.unix()
		exp:   now.add(ttl).unix()
	}, secret)
}

// verify returns the claims of `token`, after checking its algorithm, its
// signature against `secret` (in constant time) and its expiry against `now`.
pub fn verify(token string, secret []u8, now time.Time) !Claims {
	parts := token.split('.')
	if parts.len != 3 {
		return TokenError{
			reason: 'malformed token'
		}
	}
	h := json2.decode[Header](base64.url_decode_str(parts[0])) or {
		return TokenError{
			reason: 'malformed token'
		}
	}
	// a token picks its algorithm, so refuse any but ours (`none` above all)
	if h.alg != 'HS256' {
		return TokenError{
			reason: 'unsupported algorithm ${h.alg}'
		}
	}
	want := signature('${parts[0]}.${parts[1]}', secret)
	if !hmac.equal(base64.url_decode(parts[2]), want) {
		return TokenError{
			reason: 'invalid signature'
		}
	}
	claims := json2.decode[Claims](base64.url_decode_str(parts[1])) or {
		return TokenError{
			reason: 'malformed token'
		}
	}
	if claims.sub <= 0 || claims.exp == 0 {
		return TokenError{
			reason: 'malformed token'
		}
	}
	if now.unix() >= claims.exp {
		return TokenError{
			reason: 'token expired'
		}
	}
	return claims
}

fn signature(body string, secret []u8) []u8 {
	return hmac.new(secret, body.bytes(), sha256.sum, sha256.block_size)
}
