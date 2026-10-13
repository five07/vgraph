# service

A small JSON REST API in [V](https://vlang.io), backed by SQLite through V's ORM, that
also serves the same data over GraphQL. It has users, articles, posts, and comments
that can be on either an article or a post, with threaded replies. There is no
authentication.

It started as a copy of `rest-api` (commit `9d802d6`) and is the test bed and,
later, the published example for vgraph. See `../../PLAN.md` for the plan.

Built and tested with V master, like vgraph (see the root README). It imports vgraph
as `five07.vgraph`, so link the checkout first: `ln -s <vgraph> ~/.vmodules/five07/vgraph`.

## Running

```sh
v run .                          # build and start on http://localhost:8080
v test .                         # store tests and HTTP-level tests
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

Tables are created at startup if they don't exist, and so are the indexes the edges
need (`ensure_indexes`). There are no migrations yet: after a schema change, delete
the database file.

## Layout

One module per model, as in `../web`. Each has a handler and a `models` submodule
that holds the struct, its validation and its store:

```
main.v, app.v, seed.v      startup, wiring, example data
app/                       Context, config, database, errors, JSON in and out, slugs
graph/                     the typed vgraph client and GraphQL server, generated from the
                           models' edges() and api.graphql; resolvers.v is written by hand
api.graphql                the GraphQL mutations, one per REST endpoint that writes
users/  articles/  posts/  comments/
    <name>.v               the routes
    models/<name>.v        the struct, its edges, request and response shapes, validation
    models/store.v         reads and writes through orm.Connection
comments/service.v         comment operations shared with the articles and posts routes
comments/owners.v          the kinds of records comments can be on
```

## API

Every request and response body is JSON.

| Method | Path | Success |
|--------|------|---------|
| `GET` | `/health` | `200 {"status":"ok"}` |
| `GET` | `/{users,articles,posts,comments}` | `200` list, oldest first |
| `GET` | `/{resource}/:slug` | `200` the record |
| `POST` | `/{resource}` | `201` the new record |
| `PUT` | `/{resource}/:slug` | `200`: replaces every writable field |
| `PATCH` | `/{resource}/:slug` | `200`: changes only the fields sent |
| `DELETE` | `/{resource}/:slug` | `204`: soft delete |
| `GET` | `/users/:slug/{articles,posts,comments}` | `200` what the user wrote |
| `GET` | `/{articles,posts}/:slug/comments` | `200` the comments on it |
| `POST` | `/{articles,posts}/:slug/comments` | `201` a new comment on it |
| `GET` | `/comments?owner_type=Article&owner_slug=…` | `200` the comments on that record |

### Records

| Record | Writable fields | Fixed at create |
|--------|-----------------|-----------------|
| user | `name`, `email` | — |
| article | `title`, `summary`, `body`, `published` | `user_slug` |
| post | `body` | `user_slug` |
| comment | `body` | `user_slug`, `owner_type` (`Article` \| `Post`), `owner_slug`, `parent_slug` |

Responses also carry `slug`, `created_at` and `updated_at`. An article carries
`published_at` while it is published, and a reply carries `parent_slug`.

### Conventions

- **Slugs, not ids.** Each record has a UUID v7 `slug`, which is the only identifier
  the API shows. Records refer to each other by slug (`user_slug`, `owner_slug`,
  `parent_slug`). In the database they refer to each other by integer id, with
  foreign keys. The exception is a comment's owner, which can be in either table, so
  the app checks it instead.
- **Strict bodies.** A key that isn't a field of the request gets
  `400 The following attribute(s) are not supported: [...]`. `slug`, `created_at` and
  `updated_at` are ignored, so a response can be sent back as is.
- **Fixed fields can't change.** `PUT` and `PATCH` reject any of the "fixed at create"
  fields above.
- **Soft delete.** `DELETE` marks a record deleted, and it then gives `404`
  everywhere. Nothing cascades: an article's comments stay in `GET /comments`, but
  can't be reached or added through the deleted article. A deleted user's email
  stays taken.
- **Errors** are `{"error": "<message>"}`: `400` for a bad body or reference, `404`
  for a missing record in the path, `409` for a duplicate email, `500` (with no
  detail) for anything else.
- Emails are trimmed and lowercased; names and titles are trimmed.

## Walkthrough

Every command below runs against a server started with `v run .`. They need `curl`
and `jq`.

```sh
API=http://localhost:8080
json=(-H 'Content-Type: application/json')

# Users
LIN=$(curl -s "${json[@]}" -d '{"name":"Linus","email":"linus@example.com"}' "$API/users" | jq -r .slug)
curl -s "$API/users" | jq -r '.[].name'          # Ada Lovelace, Grace Hopper (seeded), Linus
curl -s "$API/users/$LIN" | jq -c .
curl -s -X PATCH "${json[@]}" -d '{"name":"Linus T."}' "$API/users/$LIN" | jq -c '{name, email}'
curl -s -X PUT "${json[@]}" -d '{"name":"Linus","email":"lt@example.com"}' "$API/users/$LIN" | jq -c '{name, email}'

# Articles
ART=$(curl -s "${json[@]}" -d "{\"user_slug\":\"$LIN\",\"title\":\"Hello\",\"body\":\"V is great.\"}" "$API/articles" | jq -r .slug)
curl -s -X PATCH "${json[@]}" -d '{"published":true}' "$API/articles/$ART" | jq -c '{title, published_at}'
curl -s "$API/articles" | jq -r '.[].title'

# Posts
POST=$(curl -s "${json[@]}" -d "{\"user_slug\":\"$LIN\",\"body\":\"Shipping today.\"}" "$API/posts" | jq -r .slug)
curl -s -X PUT "${json[@]}" -d '{"body":"Shipped."}' "$API/posts/$POST" | jq -c '{body}'

# Comments: through the flat route, or nested under what they're on
C1=$(curl -s "${json[@]}" -d "{\"user_slug\":\"$LIN\",\"owner_type\":\"Article\",\"owner_slug\":\"$ART\",\"body\":\"First!\"}" "$API/comments" | jq -r .slug)
curl -s "${json[@]}" -d "{\"user_slug\":\"$LIN\",\"parent_slug\":\"$C1\",\"body\":\"A reply.\"}" "$API/articles/$ART/comments" | jq -c '{body, parent_slug}'
curl -s "${json[@]}" -d "{\"user_slug\":\"$LIN\",\"body\":\"Nice.\"}" "$API/posts/$POST/comments" | jq -c '{body, owner_type}'
curl -s "$API/articles/$ART/comments" | jq -r '.[].body'                     # First!, A reply.
curl -s "$API/comments?owner_type=Post&owner_slug=$POST" | jq -r '.[].body'  # Nice.
curl -s -X PATCH "${json[@]}" -d '{"body":"First, edited."}' "$API/comments/$C1" | jq -c '{body}'

# What a user wrote
curl -s "$API/users/$LIN/articles" | jq -r '.[].title'
curl -s "$API/users/$LIN/posts" | jq -r '.[].body'
curl -s "$API/users/$LIN/comments" | jq -r '.[] | "\(.owner_type): \(.body)"'

# Errors
curl -s "${json[@]}" -d '{"name":"x","email":"x@example.com","role":"admin"}' "$API/users" | jq -c .
# {"error":"The following attribute(s) are not supported: [role]"}
curl -s "${json[@]}" -d '{"name":"Again","email":"LT@example.com"}' -w ' %{http_code}\n' "$API/users"
# {"error":"the email `lt@example.com` is already taken"} 409
curl -s -w ' %{http_code}\n' "$API/articles/$(uuidgen | tr A-Z a-z)"
# {"error":"article not found"} 404

# Soft delete
curl -s -X DELETE -o /dev/null -w '%{http_code}\n' "$API/articles/$ART"   # 204
curl -s -w ' %{http_code}\n' "$API/articles/$ART/comments"                # article not found 404
curl -s "$API/comments" | jq length                                       # still 6
```

## V notes

Things in V 0.5.2 this project works around; section 5 of `../../PLAN.md` lists them.

- macOS's libsqlite3 is in multi-thread mode, and veb serves requests on several
  threads, so the shared connection is opened with `fullmutex`. New rows are read
  back by slug, because the ORM's `last_insert_rowid()` can race.
- `sqlite.DB.exec` ignores errors raised while a statement runs; use the ORM or
  `exec_param_many` for writes.
- A variable named `update` inside `sql { }` makes V skip the statement silently.
- The struct attribute `@[index: '...']` creates no index on SQLite; `comments`
  creates its index with raw SQL.
- The ORM leaves `@[references]` columns nullable; `sql_type: 'INTEGER NOT NULL'`
  adds the `NOT NULL`.

## GraphQL

`POST /graphql` (or `GET /graphql?query=…` for queries) serves the schema in
`graph/schema.graphql`, which `vgraph gen` writes from the models and `api.graphql`.

- **Reads** come from the generated root fields, one per table, with `where`,
  `orderBy`, `limit` and `offset`, and the edges as fields. Every REST read has a
  GraphQL query that runs the same selects (`test_graphql_runs_the_same_selects_as_rest`):

  ```graphql
  {
    articles(where: {deletedAtIsNil: true}, orderBy: {field: CREATED_AT, direction: DESC}, limit: 10) {
      slug title author { slug name }
      comments(orderBy: {field: ID}) { body author { name } parent { slug } }
    }
    articlesCount(where: {deletedAtIsNil: true})
  }
  ```

- **Writes** are the mutations of `api.graphql`, one per REST endpoint that writes
  (`createArticle`, `updateArticle`, `deleteArticle`, `createArticleComment`, …).
  `graph/resolvers.v` resolves them through the same stores and comment service as
  the routes, so they check and fail the same way. A request's mutations run in one
  transaction, rolled back if one fails.
- **Introspection** answers as graphql-js does (`testdata/introspection.json`), so
  GraphiQL, Apollo Sandbox and code generators can read the schema.

After changing `api.graphql`, run `vgraph gen` again: it adds a stub to
`graph/resolvers.v` for each new field, and leaves the rest of that file alone.

