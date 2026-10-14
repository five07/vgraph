# service

A small GraphQL API in [V](https://vlang.io), backed by SQLite, that runs on vgraph
alone: its schema, queries, writes and checks all come from the models. It has
users, articles, posts, and comments that can be on either an article or a post,
with threaded replies. There is no authentication.

It started as a copy of the `rest-api` REST service (commit `9d802d6`), and has been
vgraph's test bed since. Phase 7 of `../../PLAN.md` replaced its REST API, handlers
and stores with what vgraph generates.

Built and tested with V master, like vgraph (see the root README). It imports vgraph
as `five07.vgraph`, so link the checkout first: `ln -s <vgraph> ~/.vmodules/five07/vgraph`.

## Running

```sh
v run .                          # build and start on http://localhost:8080
v test .                         # the API's tests, over HTTP
v run ../../cmd/vgraph gen .     # regenerate graph/ after changing a model's edges()
```

Settings come from a `.env` file in the working directory, when there is one. Real
environment variables override it. Copy `.env.example` to start one.

| Key | Default | Meaning |
|-----|---------|---------|
| `DB_PATH` | `:memory:` | SQLite database file. `:memory:` starts empty on every run. |
| `PORT` | `8080` | Port to listen on. |
| `SEED` | `true` | Load example data at startup when the database has no users. |
| `DB_DRIVER` | `sqlite` | Only `sqlite` is supported for now. |

Startup runs the pending migrations of `migrations/` through V's `v.migrations`,
which records them in `schema_migrations`. The first, `1 initial`, creates the
tables from the schema (`vgraph.create_table`), the indexes their edges need
(`vgraph.add_edge_indexes`) and each table's range of global ids
(`vgraph.global_ids`). The second, `2 polymorphic_checks`, adds the triggers
that check a comment's `owner_type` and `owner_id` in the database too
(`vgraph.add_polymorphic_checks`), for writes made outside the app. A schema
change is a new migration. A database file from
before Phase 7, with slugs and integer ids, doesn't fit: delete it.

## Layout

```
main.v, app.v, seed.v      startup, wiring, example data
hooks.v                    the hook that checks a new reply's parent: it reads
                           other tables through `graph`, which `models` can't
                           import
models/                    one file per model: the struct, its edges, field
                           options, hooks and GraphQL options; `stamps.v` has the
                           Stamps mixin and what the models share
migrations/                the database migrations, run at startup
app/                       config, database, request context, JSON for /health
graph/                     the typed vgraph client and GraphQL server, generated
                           from the models; resolvers.v is the project's (empty)
```

## API

`POST /graphql`, or `GET /graphql?query=…` for queries, serves the schema in
`graph/schema.graphql`, which `vgraph gen` writes from the models with entgql's
conventions. `GET /health` answers `{"status":"ok"}`.

- **Ids.** Every record has a global id (`ID`), unique across the four tables, so
  `node(id:)` finds any of them and `nodes(ids:)` several. Records refer to each
  other by id (`userID`, `ownerID`, `parentID`), with foreign keys in the database;
  a comment's owner can be in either table, so a hook checks it instead.
- **Lists** are Relay connections: `users`, `articles`, `posts` and `comments` at
  the root, and the edges between them (`articles` of a user, `comments` and
  `replies`), with `first` / `after`, `last` / `before`, `where`, `orderBy` and
  `totalCount`. Each model turns them on; see [Lists or connections](#lists-or-connections).
- **Writes** are the generated mutations: `create<Type>(input:)`,
  `update<Type>(id:, input:)` and `delete<Type>(id:)`, which returns the id. A
  request's mutations run in one transaction: if one fails, none is stored.
- **Introspection** answers as graphql-js does (`testdata/introspection.json`), so
  GraphiQL, Apollo Sandbox and code generators can read the schema.

### Lists or connections

Each table chooses, in its model's `graphql()` method, how its lists page. The
choice applies to every list of that table: the root field, and every edge that
leads to it. A table gets one style or the other, never both, and the choice is
made when `graph/` is generated, not per query.

```v
pub fn (u User) graphql() vgraph.GraphqlTable {
	return vgraph.GraphqlTable{
		node:  true
		relay: true // Relay connections; leave it out (false) for plain lists
	}
}
```

| | `relay: true` (this example) | `relay: false` (the default) |
|-|-|-|
| Root field | `users(first, after, last, before, where, orderBy): UserConnection!` | `users(where, orderBy, limit, offset): [User!]!` |
| Edge field | `articles(...): ArticleConnection!` | `articles(where, orderBy, limit, offset): [Article!]` |
| Count | `totalCount` on the connection | `usersCount(where): Int!` at the root |
| Paging | cursors: `after` continues from the last row | `offset` skips rows |
| Query | `{ users { edges { node { name } } } }` | `{ users { name } }` |

All four models here set `relay: true`, so `{ users { name } }` fails against this
example as it stands. To try plain lists for a table:

1. remove `relay: true` from its model in `models/`;
2. regenerate: `v run ../../cmd/vgraph gen .`;
3. restart the server, and query the plain list.

`main_test.v` and `testdata/introspection.json` expect connections, so the
tests fail until both are changed to match. The introspection result is recorded
from graphql-js (`../../graphql/testdata/README.md`). The walkthrough below uses
connections too.

### Records

| Type | Fields a create sets | An update can change | Fixed at create |
|------|----------------------|----------------------|-----------------|
| `User` | `name`, `email` | `name`, `email` | — |
| `Article` | `title`, `summary`, `body`, `publishedAt` | the same, `clearPublishedAt` | `userID` |
| `Post` | `body` | `body` | `userID` |
| `Comment` | `body` | `body` | `userID`, `ownerType` (`Article` \| `Post`), `ownerID`, `parentID` |

Every record also has `id`, `createdAt` and `updatedAt`, which only the server
sets. An article is published while it has a `publishedAt`.

### Rules

Each is in the models, so every write follows it, whoever makes it:

- Names, titles and summaries are trimmed; emails are trimmed and lowercased, and
  unique. A name is at most 100 bytes, an email 254 and has an `@`, a title 200, a
  summary 500; bodies can't be blank, and are at most 20,000 bytes (articles),
  2,000 (posts) or 5,000 (comments). Field options check them (`fields()`), after
  the hooks that normalize (`hooks()`).
- A comment's owner exists and isn't deleted, and is of the type `ownerType`
  names: vgraph checks this on every write that sets `ownerType` or `ownerID`,
  from the polymorphic `article` and `post` edges, such as
  `` `comments.owner_id`: no `Article` has the key `4294967297` ``. A reply is on
  its parent's owner (`hooks.v`).
- **Soft delete.** A delete sets `deletedAt`, and the record is then left out of
  every query: lists, counts, `node`. Lists on edges (a user's articles, an
  article's comments, a comment's replies) leave it out too. A record that refers
  to it still shows it: an article by a deleted user keeps its `author`, a comment
  on a deleted article its `article`. Nothing cascades, and a deleted user's email
  stays taken.
- **Errors** are GraphQL errors, at the field that failed, with vgraph's message,
  such as `` `articles.title`: is empty ``, or the database's, without its SQL,
  such as `UNIQUE constraint failed: users.email`.

## Walkthrough

Every command below runs against a server started with `v run .`. They need `curl`
and `jq`.

```sh
API=http://localhost:8080/graphql
gql() { jq -n --arg q "$1" '{query: $q}' | curl -s -H 'Content-Type: application/json' -d @- "$API"; }

# Users: the seeded ones, and a new one
gql '{ users { edges { node { id name } } } }' | jq -r '.data.users.edges[].node.name'
LIN=$(gql 'mutation { createUser(input: {name: "Linus", email: " Linus@Example.com"}) { id } }' | jq -r .data.createUser.id)
gql "{ node(id: \"$LIN\") { ... on User { name email createdAt } } }" | jq -c .data.node
gql "mutation { updateUser(id: \"$LIN\", input: {name: \"Linus T.\"}) { name email } }" | jq -c .data

# Articles, published by setting publishedAt
ART=$(gql "mutation { createArticle(input: {userID: \"$LIN\", title: \"Hello\", body: \"V is great.\"}) { id } }" | jq -r .data.createArticle.id)
gql "mutation { updateArticle(id: \"$ART\", input: {publishedAt: \"2026-10-13T12:00:00Z\"}) { title publishedAt } }" | jq -c .data
gql '{ articles(orderBy: {field: TITLE}) { totalCount edges { node { title author { name } } } } }' | jq -c '.data.articles'

# Posts
POST=$(gql "mutation { createPost(input: {userID: \"$LIN\", body: \"Shipping today.\"}) { id } }" | jq -r .data.createPost.id)

# Comments, and a reply
C1=$(gql "mutation { createComment(input: {userID: \"$LIN\", ownerType: \"Article\", ownerID: \"$ART\", body: \"First!\"}) { id } }" | jq -r .data.createComment.id)
gql "mutation { createComment(input: {userID: \"$LIN\", ownerType: \"Article\", ownerID: \"$ART\", parentID: \"$C1\", body: \"A reply.\"}) { parent { body } } }" | jq -c .data
gql "mutation { createComment(input: {userID: \"$LIN\", ownerType: \"Post\", ownerID: \"$POST\", body: \"Nice.\"}) { post { body } } }" | jq -c .data
gql "{ node(id: \"$ART\") { ... on Article { comments { edges { node { body replies { totalCount } } } } } } }" | jq -c .data.node

# What a user wrote, two at a time
gql "{ node(id: \"$LIN\") { ... on User { articles { totalCount } posts { totalCount } comments(first: 2) { edges { node { body } } pageInfo { hasNextPage endCursor } } } } }" | jq -c .data.node

# Errors
gql "mutation { createUser(input: {name: \"Again\", email: \"LINUS@example.com\"}) { id } }" | jq -r '.errors[0].message'
# UNIQUE constraint failed: users.email
gql "mutation { createArticle(input: {userID: \"$LIN\", title: \" \", body: \"x\"}) { id } }" | jq -r '.errors[0].message'
# `articles.title`: is empty

# Soft delete
gql "mutation { deleteArticle(id: \"$ART\") }" | jq -c .data
gql '{ articles { totalCount } }' | jq -c .data                   # one fewer
gql "{ node(id: \"$C1\") { ... on Comment { article { title } } } }" | jq -c .data.node   # still shows it
```

## V notes

Things in V 0.5.2 this project works around; section 5 of `../../PLAN.md` lists them.

- macOS's libsqlite3 is in multi-thread mode, and veb serves requests on several
  threads, so the shared connection is opened with `fullmutex`. vgraph's SQLite
  driver lets one thread's transaction finish before another's starts.
- `sqlite.DB.exec` ignores errors raised while a statement runs; vgraph's driver
  uses `exec_param_many`, which reports them.
