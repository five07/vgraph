module auth

import encoding.base64
import os
import time

const secret = 'a secret of 32 bytes, at least..'.bytes()

fn test_a_token_round_trips() {
	now := time.unix(1_800_000_000)
	token := issue(7, true, time.hour, now, secret)
	assert token.split('.').len == 3
	claims := verify(token, secret, now.add(59 * time.minute))!
	assert claims == Claims{
		sub:   7
		admin: true
		iat:   1_800_000_000
		exp:   1_800_003_600
	}
}

fn test_bad_tokens() {
	now := time.unix(1_800_000_000)
	token := issue(7, false, time.hour, now, secret)
	parts := token.split('.')
	forged := base64.url_encode_str('{"sub":7,"admin":true,"iat":1800000000,"exp":1800003600}')
	none_alg := base64.url_encode_str('{"alg":"none","typ":"JWT"}')
	for bad, reason in {
		token:                               'token expired'
		'${parts[0]}.${forged}.${parts[2]}': 'invalid signature'
		'${none_alg}.${parts[1]}.':          'unsupported algorithm none'
		'not a token':                       'malformed token'
		'a.b.c':                             'malformed token'
	} {
		at := if reason == 'token expired' { now.add(time.hour) } else { now }
		if _ := verify(bad, secret, at) {
			assert false, bad
		} else {
			assert err.msg() == reason
		}
	}
	// another key
	if _ := verify(token, 'another secret'.bytes(), now) {
		assert false
	} else {
		assert err.msg() == 'invalid signature'
	}
}

fn test_passwords() {
	os.setenv('BCRYPT_COST', '4', true)
	hash := hash_password('correct horse')!
	assert hash.starts_with('$2')
	assert check_password('correct horse', hash)
	assert !check_password('wrong horse', hash)
}
