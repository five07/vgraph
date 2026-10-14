# auth

A GraphQL API whose requests carry a JSON Web Token. `login` checks a password
and issues the token; each request then runs as the viewer its token names, and
the models' privacy rules and hooks decide what that viewer may read and write.

vgraph doesn't authenticate anyone. It passes a value of the app's, here
`auth.Viewer`, as the request's context to every hook and privacy rule, and the
app decides what it means.

```sh
JWT_SECRET='change me: at least 32 bytes of secret' v run .   # http://localhost:8080/graphql
v test .
```

The database is in memory (`DB_PATH` for a file), seeded with an admin, **Ada**
(`ada@example.com` / `ada-password`), and a member, **Bob** (`bob@example.com` /
`bob-password`), whose post 1 is published and post 2 a draft. `SEED=false`
starts empty, `PORT` changes the port, and `BCRYPT_COST` the cost of password
hashes (10; the tests use 4).

## The rules

| Who                    | Reads posts           | Creates posts                 | Changes posts | Users                                   |
|------------------------|-----------------------|-------------------------------|---------------|-----------------------------------------|
| No one (no token)      | published             | no                            | no            | signs up; reads names                   |
| A member               | published, and theirs | as themselves only            | theirs        | changes their own account, not `admin`  |
| An admin               | all                   | as anyone                     | all           | anything, `admin` included              |

Where each lives:

- **Privacy rules** decide whether an operation runs at all
  (`models/models.v`, `policy()`). `visible_posts` narrows every query of posts
  by viewer, so lists, counts, `node` and the `posts` of a user all agree.
  `allow_admin` lets an admin make any write, `deny_anonymous` turns away writes
  without a token, and `user_writes` lets anyone sign up and a user update only
  their own account.
- **A rule that reads other rows** is registered on the graph at startup
  (`main.v`, `owner_only`), since the models can't import the generated graph:
  a member may update or delete only posts whose author they are. It reads the
  authors through `g.privileged()`, which skips privacy rules, so it sees other
  members' drafts too. Rules registered on the graph run before the model's, so
  it leaves admins and the anonymous to those.
- **Hooks** change a write by who makes it: the same mutation runs one way for
  an admin and another for a member.
  - `set_author`: a member's new post is theirs, whatever the input says, and
    naming someone else fails; an admin may post as anyone, and is the author
    when the input names none.
  - `admin_only`: only an admin may grant `admin`, or change it.
  - `hash_password`: a new password must be 8 bytes or more, and is stored as a
    bcrypt hash. The field's own checks run after the hooks, on the hash, so the
    hook checks the length.
- **Sensitive fields:** `email` and `password` are `sensitive`, so they're in the
  inputs but never in the `User` type, filters or orders.

The seed runs as an admin viewer of its own (`g.with_ctx(auth.Viewer{admin:
true})`), so the same rules and hooks check it: making Ada an admin and posting
as Bob are admin writes.

## Tokens

`auth/jwt.v` is HS256 (RFC 7519) in about a hundred lines of V's own
`crypto.hmac`, `crypto.sha256` and `encoding.base64`, rather than a package. A
token's claims are the user's id (`sub`), whether they're an admin, and when it
was issued and expires (an hour). `verify` refuses any algorithm but HS256
(`none` above all), compares the signature in constant time, and checks the
expiry. The key is `JWT_SECRET`, which must be at least 32 bytes.

The HTTP handler (`serve_graphql`) reads `Authorization: Bearer <token>`. No
header is the anonymous viewer. A token that doesn't verify is a 401 with
`WWW-Authenticate: Bearer error="invalid_token"`, before the request runs: a
client with an expired token learns it at once, rather than seeing less data.

The token carries `admin`, so a change of role takes effect at the next login.
An app that must revoke at once would read the user on each request instead.

## Walkthrough

These are the responses of the running server, trimmed.

As no one, only published posts show, and writing a post is denied:

```sh
curl -s localhost:8080/graphql -H 'Content-Type: application/json' \
  -d '{"query": "{ posts { edges { node { title author { name } } } } }"}'
```

```json
{"data":{"posts":{"edges":[{"node":{"title":"Hello","author":{"name":"Bob"}}}]}}}
```

```sh
curl -s localhost:8080/graphql -H 'Content-Type: application/json' \
  -d '{"query": "mutation { createPost(input: {title: \"Hi\", body: \"x\"}) { id } }"}'
```

```json
{"errors":[{"message":"privacy: create of `posts` denied","path":["createPost"]}],"data":null}
```

Log in as Bob, and keep the token:

```sh
BOB=$(curl -s localhost:8080/graphql -H 'Content-Type: application/json' \
  -d '{"query": "mutation { login(email: \"bob@example.com\", password: \"bob-password\") }"}' \
  | sed 's/.*"login":"\([^"]*\)".*/\1/')
```

Bob sees his draft too, and posts as himself, but not as Ada:

```sh
curl -s localhost:8080/graphql -H 'Content-Type: application/json' -H "Authorization: Bearer $BOB" \
  -d '{"query": "{ me { name } posts { edges { node { id title publishedAt } } } }"}'
```

```json
{"data":{"me":{"name":"Bob"},"posts":{"edges":[
  {"node":{"id":"1","title":"Hello","publishedAt":"2026-10-14T13:21:12.000Z"}},
  {"node":{"id":"2","title":"Draft","publishedAt":null}}]}}}
```

```sh
curl -s localhost:8080/graphql -H 'Content-Type: application/json' -H "Authorization: Bearer $BOB" \
  -d '{"query": "mutation { createPost(input: {title: \"Mine\", body: \"x\"}) { id author { name } } }"}'
# {"data":{"createPost":{"id":"3","author":{"name":"Bob"}}}}

curl -s localhost:8080/graphql -H 'Content-Type: application/json' -H "Authorization: Bearer $BOB" \
  -d '{"query": "mutation { createPost(input: {title: \"As Ada\", body: \"x\", authorID: \"1\"}) { id } }"}'
# {"errors":[{"message":"`posts.author_id`: only an admin can post as another user", ...}]}
```

Ada, an admin, may post as Bob: the same hook, another viewer.

```sh
ADA=...   # login as ada@example.com / ada-password
curl -s localhost:8080/graphql -H 'Content-Type: application/json' -H "Authorization: Bearer $ADA" \
  -d '{"query": "mutation { createPost(input: {title: \"For Bob\", body: \"x\", authorID: \"2\"}) { id author { name } } }"}'
# {"data":{"createPost":{"id":"4","author":{"name":"Bob"}}}}
```

Anyone signs up. Cy, a new member, sees only published posts, can't edit Bob's,
and can't make themselves an admin; Ada can:

```sh
curl -s localhost:8080/graphql -H 'Content-Type: application/json' \
  -d '{"query": "mutation { createUser(input: {name: \"Cy\", email: \"cy@example.com\", password: \"cy-password\"}) { id name admin } }"}'
# {"data":{"createUser":{"id":"3","name":"Cy","admin":false}}}

# as Cy
#   mutation { updatePost(id: "1", input: {title: "Mine now"}) { title } }
#   -> privacy: update_one of `posts` denied
#   mutation { updateUser(id: "3", input: {admin: true}) { admin } }
#   -> `users.admin`: only an admin can change it
# as Ada
#   mutation { updateUser(id: "3", input: {admin: true}) { name admin } }
#   -> {"data":{"updateUser":{"name":"Cy","admin":true}}}
```

A token that doesn't verify stops the request:

```sh
curl -s -i localhost:8080/graphql -H 'Content-Type: application/json' -H 'Authorization: Bearer abc.def.ghi' \
  -d '{"query": "{ me { name } }"}'
```

```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer error="invalid_token"

{"errors":[{"message":"malformed token"}]}
```

`main_test.v` sends each of these, and more, over HTTP.

## Layout

```
main.v               the server: config, migration, seed, the owner_only rule,
                     and the handler that reads the token
models/models.v      User and Post, their privacy rules and hooks
schema/auth.graphql  the hand-written fields: `me` and `login`
graph/               the client and GraphQL server, from `vgraph gen`;
                     resolvers.v holds `me` and `login`
auth/                tokens (jwt.v), the viewer and password hashes (viewer.v)
```

After changing a model or `schema/auth.graphql`, run `v run ../../cmd/vgraph gen`
here.
