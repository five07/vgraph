# vgraph: plan to v0.1.0

## 0. Context for agents

**What vgraph is.** An [Ent](https://entgo.io)-style graph layer for V, published
(once VPM allows) as `five07.vgraph` from `github.com/five07/vgraph`. Models are plain
V structs whose `edges()`, `fields()`, `hooks()`, `interceptors()`, `policy()`,
`indexes()` and `graphql()` methods declare the schema. `vgraph gen` writes a typed
client (queries, eager loads, traversals, write builders) and a GraphQL server with
entgql's conventions. Edges load in one query per edge per level, never one per row.

**Where it stands (2026-10-13).** Phases 0–7 are done on `develop`: batched loading,
the generator, non-int keys, a GraphQL implementation of its own, migration helpers
for `v.migrations`, Ent parity (writes, hooks, interceptors, privacy, the query API,
schema options, global ids, entgql's Node, connections and mutations), and
`examples/service` running on vgraph alone. Their plan, results and every decision
(Q1–Q120) are in git history: `git show bb105cd:PLAN.md`, the last version before
this rewrite. Comments in the code that cite `PLAN.md, Q<n>` with `n` up to 120 refer
to that version. This plan's questions start at Q121.

**Layout.**
- `edge.v`, `schema.v`, `field.v`, `client.v`, `driver.v`, `mutation.v`, `write.v`,
  `hooks.v`, `trace.v`, `gql.v`, `migrate.v`: the `vgraph` module.
- `load/`: batched selects, conditions, the keys-first plan for SQL the ORM can't
  run, per-parent windows, keyset cursors.
- `graphql/`: lexer, parser, validator, executor, introspection, HTTP handler,
  Relay helpers. It never imports vgraph, so it can move to `five07.graphql`.
- `gen/`, `cmd/vgraph/`: the generator (`vgraph gen`, `vgraph describe`).
- `sqlite/`, `pg/`: drivers that run vgraph's own parameterized SQL.
- `examples/relations/`: every Ent relationship kind and schema option, tested on
  SQLite and PostgreSQL. `examples/service/`: a GraphQL API on vgraph alone.
  `examples/pagination/`: lists and Relay connections, paged at the root and per
  parent (G5). `examples/auth/`: JWT logins, privacy rules and hooks by viewer
  (G6).
- `regressions/`: one small program per V compiler bug vgraph works around, or
  meets (10 so far).

**How to work here.**
- **Never commit.** The user makes every commit, on `develop`; `main` gets merges.
- **Decisions go in this file**, as numbered **Q** with a **Default** and an empty
  `> A:` line the user fills in. Read the answers before starting a goal; record
  each goal's result under it, with what was decided along the way.
- **V:** built against V master `53dd72c` (CI's `V_COMMIT`), which has
  `v.migrations`. Generics across modules and comptime are where compiler bugs have
  been: prefer generated code to generics, and add a `regressions/` program for each
  new bug.
- **Tests:** `v test .` (SQLite; about 80 seconds). PostgreSQL:
  `v -d vgraph_pg test pg_test.v examples/relations/pg_test.v`, with `PGHOST`,
  `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE`; the tests drop and recreate their
  tables, so use a throwaway database. graphql-js: `graphql/testdata/check_schema.js`,
  with `graphql@16.11.0` from npm on `NODE_PATH`.
- **After changing the generator or a model:** run `v run cmd/vgraph gen` on
  `examples/service`, `examples/relations`, `examples/pagination` and
  `examples/auth`; CI fails when the checked-in output is
  stale. A change to `examples/service`'s schema needs `testdata/introspection.json`
  re-recorded from graphql-js (`graphql/testdata/README.md`).
- **CI** (`.github/workflows/ci.yml`) runs only on pushes to `main`: `v fmt -verify`,
  `v vet`, generated code up to date, `v test`, PostgreSQL, graphql-js. It hasn't run
  yet: `develop` hasn't been merged.
- **Style:** doc comments on every `pub` item (`v vet` checks them); plain, short
  sentences in comments and docs that say what a thing does and why.

## 1. Goals for v0.1.0

From `TODO.md` (2026-10-13), which this plan replaces; after v0.1.0, new work comes
from GitHub issues. Each goal lists its tasks, then its questions.

**Order.** quality first, then features, then docs and the
release: G1 N+1 audit → G2 coverage → G3 polymorphic foreign keys → G4 schema check →
G5 pagination example → G6 auth example → G7 OpenTelemetry → G8 Federation → G9 docs
→ G10 README sections → G11 issue templates → G13 release. G12 (fixes in V) runs
alongside, and doesn't hold up the release. G14 (a spike: select only the requested
fields) goes where Q139 puts it.


### G1. No N+1 queries, verified

Every read path should run a fixed number of selects, whatever the number of rows.
`examples/relations` and `examples/service` assert the selects of many queries, but
not of every path.

Tasks:
- a test helper that runs a query on small and larger data, and asserts the selects
  are the same list (as `examples/service`'s
  `test_queries_run_a_fixed_set_of_selects` does);
- run it over each path: root lists, every edge kind (`with_<edge>`, nested and
  named), traversals, edge predicates, counts, aggregates, `node` / `nodes`,
  connections at the root and nested (with `totalCount`), per-parent limits, privacy
  and interceptor subqueries, and the GraphQL resolvers of each;
- fix what grows, and list the paths in the README.

**Q122. Writes too?** A bulk create on SQLite is one insert per row (its `RETURNING`
doesn't promise the rows' order), a create's edge writes are a statement per edge,
and hooks run per row. **Default:** reads are fixed; writes are documented as
statements per row or per edge, and the audit only checks that they don't grow with
rows they don't touch. The other choice is batching SQLite's bulk writes too.
> A: No, writes (or any queries post-write in a transaction) are not included

**Result (2026-10-13): done; nothing grew, so nothing needed fixing.**
- `examples/relations/selects.v` (`test_fixed_selects`, on SQLite and PostgreSQL):
  18 cases, each run on four clients: on the ORM's connection and on a driver, each
  plain and with an interceptor on pets and a privacy rule on users that add edge
  predicates (so subqueries, or keys-first selects without a driver). It records
  each case's statements, grows every table (20 users, each with a card, three pets
  with one soft-deleted, a group, a device with two logins and two groups, a gadget
  with likers, follows, friends, a spouse every other user, a list node and a
  category), and asserts the same statements in the same order. Cases: root
  results, every edge kind, a three-level nesting, named edges, limits per parent,
  traversals from a query and a node, edge predicates, counts and aggregates,
  `group_by` and edge orders (driver only), and GraphQL: every edge field, counts
  and filters, limits per parent, root and nested connections, edge orders, and
  `node` / `nodes` over every gadget id.
- `examples/service`'s test gained a post's polymorphic comments, every user edge
  as a nested connection, `where` with edge predicates, and `nodes` over every id of
  all four tables; its growth now adds users, posts and replies too.
- A case that loops (`query_pets()` per user) fails it: 4 selects become 24.
- One thing to know when writing cases: an edge whose keys come back empty skips
  its row select, so a case must reach rows on every edge on the seed too, or it
  runs more statements after growth. That is fewer, never more, so not an N+1.
- The README's "No N+1 queries" section lists the paths, and what isn't covered
  (writes, per Q122; the app's own resolvers).

**Q137. Long key lists.** An edge load puts every parent key in one `IN (...)`, and
nothing splits it: past the database's limit on parameters (65,535 on PostgreSQL,
32,766 on SQLite since 3.32) the select fails. **Default:** split the keys into
chunks of 10,000 inside `select_in` and `link_pairs`, so a load stays one select per
edge up to 10,000 parents, and one more per 10,000 after that. A per-parent limit's
keys-first statement is split the same way. The other choices: (a) PostgreSQL's
`= ANY($1)` with one array parameter (no limit, but the ORM path can't send arrays,
so it needs the driver), or (b) document the limit and leave it.
> A: agreed, 10k chunks is a good size.

**Result (2026-10-13): done; tests not yet written (to come with G2's or its own).**
- `load.max_keys` (10,000) and `chunks` (`load/keys.v`). Split by parent:
  `select_in` (and so `load_one`, `load_many`), `select_each`'s keys-first window
  statement, `link_pairs`, `link_each` (both paths), `count_each`, `count_through`,
  `expr_values`. Split by key, order restored with `in_order`: the rows-by-key
  statement after any keys-first plan (`rows_by_keys`, also used by `select_into`).
  Up to 10,000 keys, the statements are the same as before.
- Order across parts: a split by parent keeps each parent's order exact, since a
  parent's rows all come from one statement. An ordered load of targets *by key*
  (many to many, `load_through`, and `link_each` without a driver) can't be split
  by key without losing the order across parts, so the pairs are split into groups
  of whole parents with at most 10,000 distinct targets each
  (`load.parent_groups`), one ordered select per group; a target shared by two
  groups is read twice. A single parent with more than 10,000 targets keeps them
  in one statement, as before: it works up to the database's cap.
- `select_in` therefore doesn't split an ordered load by `T`'s key; `load_one`
  drops the order (its rows go in a map) so it can split. The generated
  many_to_one loader still passes the edge query's order, so a load of more than
  10,000 distinct targets with an order is one statement, as before.
- The generated many-to-many loader loops over `load.parent_groups(pairs)`;
  `examples/relations/graph` is regenerated.
- Not split: conditions the app builds with a long list (`in_keys`, `in_ints`,
  …, the GraphQL `nodes` ids), a node's `query_<edge>` through a join table, the
  key lists `resolve` makes of subqueries without a driver, and writes (Q122).
  A cap applies to a whole statement, so these would need one array or JSON
  parameter (choice (a)) rather than parts.

### G2. Coverage

**Q123. How it's measured, and the bar.** V master has `v -cov` (line coverage of
tests). **Default:** measure the `vgraph`, `load`, `graphql`, `gen`, `sqlite` and `pg`
modules with it, keep the report out of git, add tests where whole features turn out
untested, and record the numbers here. No CI gate for v0.1.0: the number is a guide,
not a target. The other choice is a minimum, such as 80%, that CI enforces.
> A: default

**Result (2026-10-13): done.** Measured with `v -no-skip-unused -coverage` over
`v test .` and the PostgreSQL tests, read with `v cover` (commands in the README's
Development section). V counts points (statements and branches), not lines. Before
and after the tests G2 added:

| module       | before | after |
|--------------|-------:|------:|
| `vgraph`     | 90.5%  | 96.1% |
| `load`       | 89.4%  | 91.1% |
| `graphql`    | 86.8%  | 91.0% |
| `gen`        | 81.5%  | 81.5% |
| `sqlite`     | 65.4%  | 80.8% |
| `pg`         | 68.8%  | 68.8% |
| `cmd/vgraph` | 56.8%  | 56.8% |
| all          | 85.8%  | 89.0% |

Features no test ran, now tested:
- the GraphQL limits on depth and size (Q31's `max_depth`, `max_selections`),
  through inline and named fragments and cycles;
- the HTTP handler's errors: a body that isn't JSON or an object, a non-string
  `operationName`, non-object `variables`, a malformed query string or `variables`
  on GET, and other methods (405 with `Allow: GET, POST`);
- variables holding input objects, lists, enums and `@oneOf` inputs, with their
  defaults and every coercion error; the messages match graphql-js 16.11.0's;
- every problem `validate_schema` reports (22 more), each checked against
  graphql-js 16.11.0's message for the same SDL;
- a hook's view of a write (`table_name`, `changed_columns`, `added_ids`,
  `removed_ids`, `edge_cleared`), and stacked `only_if`;
- tracing of every statement kind on the ORM's connection (updates, deletes, table
  creates and drops, raw SQL, transactions; savepoints pass through unreported), and
  failures;
- writes on a connection without transactions, with their `on_commit` and
  `on_rollback`, and the SQLite driver's ORM transactions;
- `vgraph.mean`, `min_of`, `max_of` and `desc`, `nulls_first`, `has_suffix`, and
  `not_in` on strings and `i64` keys.

What's left uncovered is mostly error branches (a database or driver failing
mid-statement). `gen` and `cmd/vgraph` read low because `cmd/vgraph/gen_test.v` runs
the generator in a subprocess, which isn't instrumented; the generated examples and
CI's check that they're up to date cover it. `pg` is the driver's error branches.

Found along the way: under `-coverage`, a `u16` field read back as 0 on PostgreSQL.
The cause is in V, not coverage: `orm.Primitive(*unsafe { &u16(&data) })` in
`db.pg` compiles to a pointer to a local that dangles once the function returns
(`regressions/sum_type_deref_cast.vv`). vgraph now reads `u16` columns as `i64`, as
it already did `u32` and `u64`; G12 has the fix for V.

### G3. Polymorphic foreign keys

A polymorphic edge (`owner_type` / `owner_id`) can't have a database foreign key, so
nothing in vgraph checks that `owner_id` names a row of the table `owner_type` names.
`examples/service` checks it with a hook of its own (`hooks.v`).

**Q124. What vgraph does.** **Default:** (a) and (b).
- (a) The write engine checks it: a create or update that sets a polymorphic
  many_to_one edge's column reads the target by key, through the target table's root
  query (so a soft-deleted target counts as missing), and fails with a
  `ValidationError` when there is none. `examples/service`'s hook then keeps only the
  reply's parent check.
- (b) The migration helpers add database triggers that check it on insert and update,
  on SQLite and PostgreSQL, for apps that also write outside vgraph:
  `vgraph.add_polymorphic_checks(mut ctx, schema)`.
- (c) Only (a).
> A: default

**Result (2026-10-14): done, (a) and (b).**
- `Schema.polymorphics()` (`schema.v`): each polymorphic column pair
  (`table`, `column`, `type_col`) with the table each type value names, from the
  edges on both sides: a many_to_one edge's target, and the table of a
  one_to_many or one_to_one edge to the holder. So a type declared only on the
  target's side (a `Clip` with notes, but no `clip` edge on notes) counts.
  `validate` now reports a type value that names two tables.
- (a) `write.v`: `check_polymorphic` runs after the other checks, before the
  SQL, on a create (both the hooks and the no-hooks bulk paths), an update, and
  `added` on a polymorphic many_to_one edge. It reads the target by key through
  `prepare_query`, so the target's privacy rules and interceptors apply:
  soft-deleted is missing, `skip('soft_delete')` or `privileged()` see it, and a
  query rule that denies makes the write a `PrivacyError`. An update that sets
  half a pair reads the other half from each stored row (`select_row`). Errors are
  `ValidationError`s: `` `notes.owner_id`: no `Doc` has the key `9` ``,
  `` `notes.owner_type`: is `Video`, not one of `Clip`, `Doc`, `Pic` ``, or
  `` `notes.owner_type`: is required with `owner_id` ``. A null key passes. One select per row written,
  per pair it sets (writes are per row anyway, Q122).
- (b) `migrate.v`: `add_polymorphic_checks` / `remove_polymorphic_checks`. SQLite:
  `BEFORE INSERT` and `BEFORE UPDATE OF <type_col>, <column>` triggers
  (`<table>_<column>_poly_insert`, `_update`) that `RAISE(ABORT, ...)`.
  PostgreSQL: a plpgsql function and one `BEFORE INSERT OR UPDATE OF` trigger,
  both `<table>_<column>_poly`, raising SQLSTATE 23503. The condition is
  `NEW.column IS NOT NULL AND NOT EXISTS (SELECT 1 FROM t1 WHERE NEW.type = 'A'
  AND t1.key = NEW.column UNION ALL ...)`, so an unknown or null type with a key
  fails. They see stored rows: a soft-deleted target still counts, and deleting a
  target leaves its references (Q124 asked for insert and update only).
- `examples/service`: the hook keeps only the reply's parent check
  (`check_parent`); the owner errors are vgraph's now. A second migration,
  `2 polymorphic_checks`, adds the triggers, and the startup test checks them.
- Tests: `polymorphic_test.v` (creates, bulk, updates of one and many rows, the
  edge setter, a soft-deleted target, the SQLite triggers up and down; on both
  clients), `pg_test.v` (the triggers in the migration test, and the write
  check through the driver). `v test .`, PostgreSQL, `v fmt -verify` pass; the
  generated examples are unchanged.

### G4. Schema discovery and validation

**Q125. What this means.** **Default:** (a) now; (b) after v0.1.0, if an issue asks.
- (a) `vgraph check <project>`: compares a database (its URL in an environment
  variable) with the schema, and reports what differs: missing tables or columns,
  types, nullability, the indexes edges need, foreign keys, global-id ranges. It reads
  SQLite's `sqlite_master` and pragmas, and PostgreSQL's `information_schema`. Useful
  in CI after migrations, and before a deploy.
- (b) Discovery: read an existing database and write V models with `edges()` from its
  foreign keys, as Ent's `entimport` does.
> A: Sorry, this was my fault for the ambiguity. What I mean is Introspection - https://graphql.org/learn/introspection/

**Where introspection stands (2026-10-14).** It works: `__schema`, `__type` and
`__typename` answer as graphql-js 16.11.0 does, and `examples/service` checks the
full introspection query against a recording from graphql-js
(`testdata/introspection.json`). What's missing is around it:
- **Descriptions.** A field can have one (`Field.comment`), and so can
  `@deprecated` (`Field.deprecated`). Tables, edges, enum values and the
  mutations' arguments can't, so the generated types have only the Relay and
  entgql boilerplate descriptions ("An edge in a connection."). The service's
  schema has no descriptions of its own.
- **Turning it off.** `server.validation.no_introspection = true` rejects
  introspection queries with graphql-js's message, but it is for the whole
  server, the generated server doesn't expose it, and no doc mentions it.
- **Tools.** Nothing serves GraphiQL. The schema SDL is only the file
  `vgraph gen` writes; nothing serves it over HTTP.
- **Coverage.** Only `examples/service`'s schema is checked against graphql-js.
  `examples/relations`, which has every edge kind and schema option, isn't.

**Q140. What G4 does.** **Default:** (a), (b), (c) and (e); not (d).
- (a) **Descriptions:** add `comment` to `GraphqlTable` (the object type),
  `Edge` (its field) and enum values (on `Field`, by value), and pass them to
  the generated SDL, so introspection returns them. Give the service's models
  descriptions, and re-record `testdata/introspection.json`.
- (b) **Turning it off, per request:** a `Server.introspection` field taking
  `fn (ctx Context) bool`. When it returns false, the request is validated with
  `no_introspection`. Unset, introspection is allowed, as today. The app sets it
  on the server that `g.graphql(r)` returns, so G6's example can allow it only
  for an `admin` claim, or a production config can turn it off.
  `graphql.no_introspection_for_all` is the function that always returns false.
  `__typename` stays allowed, as graphql-js does.
- (c) **Coverage:** record `examples/relations`' introspection from graphql-js,
  as the service's is, and check it in its tests; extend
  `check_schema.js` to rebuild each schema from its introspection
  (`buildClientSchema`) and compare it with the SDL, so a description or a
  default value lost on the way shows up.
- (d) **GraphiQL:** `graphql.graphiql_page(endpoint)` returns an HTML page that
  loads GraphiQL from a CDN, and the service serves it at `GET /graphiql` when
  a config flag allows it. It isn't in the default because it adds a page that
  pulls third-party scripts; Apollo Sandbox and other tools can read the
  schema through introspection already.
- (e) **Docs:** a README section: what introspection answers, how to describe
  types and fields, how to turn it off in production, and `schema.graphql` for
  tools that read SDL.

The first reading of Q125, a `vgraph check` that compares a database with the
schema, would move to after v0.1.0, if an issue asks for it.
> A: Introspection is working; make sure it's in `docs/` (G9), but for now just a
> simple addition to the top-level README.

**Result (2026-10-14): done, as the answer says; (a)–(d) not taken.**
- The README's GraphQL section has an "Introspection" part: what the server
  answers, a `__type` query, where descriptions and `@deprecated` come from,
  `graph/schema.graphql` for SDL tools, and turning it off with
  `server.validation = graphql.ValidateOptions{no_introspection: true}` (checked
  by hand: `__schema` fails with graphql-js's message, `__typename` still works).
- G9's GraphQL guide covers introspection (added to its list).
- A `vgraph check` against a database waits until after v0.1.0, if an issue asks.

### G5. Pagination example

GraphQL lists already page two ways: `limit` / `offset` lists, and, per table with
`relay: true`, Relay connections (`first` / `after`, `last` / `before`, `edges`,
`node`, `cursor`, `pageInfo`, `totalCount`). What's missing is an example, and docs
that compare them (<https://graphql.org/learn/pagination/>).

Tasks: `examples/pagination`, with two tables, one with connections and one with
lists, a seed of a few hundred rows, tests that page through both (forwards,
backwards, ordered by a field, nested per parent), and a README that says when to use
which, with the queries a client sends.

**Q126. `offset` on connections?** The `TODO.md` item lists "first, after, offset".
**Default:** no: a connection pages by cursor, as Relay and entgql do, and offset
pages are what lists are for. The other choice adds `offset` to connections.
> A: default

**Result (2026-10-14): done.** `examples/pagination`:
- Two tables linked many to many through `book_authors`: authors are lists
  (`limit` / `offset`), books are Relay connections (`relay: true`). So each kind
  shows at the root and nested under the other: `author.books` is a connection
  per author, `book.authors` a list per book. 40 authors and 300 books, made by
  formulas (`catalog/catalog.v`), so the checks work out each page's rows rather
  than hard-coding them; about four books a year, so an order by year has ties
  that the key breaks.
- `main.v` serves it on veb from an in-memory SQLite database (`v run .`,
  `PORT`). The data and the checks are modules of their own (`catalog/`,
  `checks/`), so the server builds without "unused function" notices.
- Checks (`checks/checks.v`, run by `main_test.v` on SQLite and `pg_test.v` on
  PostgreSQL): lists paged with several sizes, ascending and descending, with a
  filter and `authorsCount`; connections forwards and backwards, by key and by
  year both ways, with a filter, `totalCount`, `first: 0` and a bad cursor;
  per parent, each author's first books with `totalCount` and `hasNextPage`, one
  author's books walked both ways by cursor, and each book's second author by
  `limit` / `offset`; the statements of a page the same at any size and place; and
  a write between two pages, which repeats a row through `offset` and not through
  a cursor.
- The README compares the two (a table of when to use which), with the queries a
  client sends and the responses, captured from the running server. It notes that
  cursors only work with the order they came from (`invalid cursor` otherwise),
  that `hasPreviousPage` is false when paging forwards (and `hasNextPage`
  backwards), as the Relay spec allows, that `totalCount` is a second query, and
  that an order other than the key needs a driver.
- CI: the generated-code check, graphql-js's schema check and the PostgreSQL job
  include the example. The root README links all three examples.

**Q141. Page-size arguments.** Found while writing the example: a negative
`first` or `last` is an error (`` `first` on a connection cannot be less than
zero. ``), but `limit: -1` on a list returns every row, and a negative `offset`
is passed on as it is. Nothing caps a page's size either. **Default:** a negative
`limit` or `offset` is an error with the same wording as `first`'s, in the
generated resolvers (a generator change, so all three examples are regenerated);
caps wait for G6, whose example shows a request check, and the docs say how. The
other choice adds a cap now: `max_page` on `GraphqlTable`, and a schema-wide
default in the generated server, which clamps `first`, `last` and `limit`, or
fails the request.
> A: Both: negatives return errors, and page sizes get configurable defaults.
> Add them before moving on; hold the full test suite until after G6.

**Result (2026-10-14): done.**
- `graphql` module (`relay.v`): `PageSize{default_size, max_size}` (0 is no
  bound) with `check()`. `page_args(args, size)` refuses `first` / `last` past
  the maximum (`` `first` on a connection cannot be more than 100. ``), and with
  neither, pages `first: default` (or the maximum). `list_args(args, size)` does
  the same for lists, and refuses a negative `limit` or `offset`
  (`` `limit` on a list cannot be less than zero. ``, same wording as `first`).
  `size` is `@[params]`, so `page_args(args)` still compiles.
- `vgraph`: `GraphqlTable.default_page` and `max_page`, per table (`validate`
  reports negatives, or a default past the maximum), and `GraphqlOptions`, for
  every other table. `Schema.page_sizes(opts)` resolves them by table: the
  table's own value wins, each of the two on its own.
- Generator: `g.graphql(r, default_page: 20, max_page: 50)` (the options are
  optional); it resolves the sizes once, failing on bad ones, and each root and
  nested list and connection passes its target table's size. All three examples
  regenerated.
- A maximum with no default is also the size of a page that asks for none, so
  the maximum always holds. Without either, nothing changes.
- `examples/pagination`: books have `max_page: 100` in their model, the server
  runs with `default_page: 20, max_page: 50`, and `check_page_sizes` covers the
  negatives (root and nested), the defaults and maximums (root and per parent),
  the table's override, and options that can't hold. The README's "Page sizes"
  section, and the root README's GraphQL list, document them.
- Tests run (the full suite is held until after G6, as asked): `schema_test.v`
  (validation, `page_sizes`), `graphql/`, `examples/service`,
  `examples/relations/main_test.v`, `examples/pagination/main_test.v`,
  `cmd/vgraph/gen_test.v`: all pass. PostgreSQL not run: nothing in the change
  touches SQL.

### G6. Auth example: a JWT and access rules

**Q127. The example.** **Default:** `examples/auth`, on veb:
- a `login` mutation (hand-written, in the example's `.graphql` file) checks a
  password (a `sensitive` field, hashed in a hook) and returns an HS256 JWT, signed
  with a secret from the environment;
- the HTTP handler reads `Authorization: Bearer <token>`, verifies it, and passes a
  `Viewer` context; no token is an anonymous viewer, a bad or expired one an error;
- privacy policies: anyone reads published posts, only their author drafts; only the
  author updates or deletes a post; an `admin` claim may do anything; a hook sets the
  author from the viewer on create;
- tests for each rule over HTTP, and a README walkthrough with `curl`.
> A: Agreed, just make sure that hooks are demonstrated for privleged vs non-privleged users.

**Q128. The JWT code.** **Default:** in the example, about 100 lines with
`crypto.hmac`, `crypto.sha256` and `encoding.base64`, since vgraph doesn't do
authentication. The other choices: a small `five07.vgraph.auth` module, or a VPM
package.
> A: just scaffold what is needed in the example. I don't want to rely on external VPM deps but have a look at `https://vpm.vlang.io/packages/deatil.vjwt` for fitness.

**Result (2026-10-14): done.** `examples/auth`, on veb and SQLite:
- `deatil.vjwt` (looked at, per Q128): HS256 and the time claims are there, but
  it is a VPM dependency, with no version history or sign of maintenance, and an
  example in its docs that doesn't run. `auth/jwt.v` is ~100 lines on
  `crypto.hmac`, `crypto.sha256`, `encoding.base64` and `json2` (V master
  removed `json`): `sign`, `issue`, `verify` (HS256 only, so `alg: none` is
  refused; constant-time compare; expiry), checked against Python's `hmac` by
  hand. `auth/viewer.v`: `Viewer`, `viewer_of(ctx)`, and bcrypt from
  `crypto.bcrypt`, its cost from `BCRYPT_COST` (the tests use 4).
- Models: users (`email` and `password` sensitive; `admin` defaults to false)
  and posts (relay). Privacy: `visible_posts` (published, own drafts, all for an
  admin), `allow_admin`, `deny_anonymous`, `user_writes` (anyone signs up, a user
  updates only their own account, else admin only). Hooks, the same write by
  different viewers (Q127's answer): `set_author` (a member posts as themselves,
  naming another fails; an admin posts as anyone), `admin_only` (only an admin
  grants or changes `admin`), `hash_password` (length check, then bcrypt).
- `main.v`: `JWT_SECRET` (at least 32 bytes), `Authorization: Bearer`; no
  header is anonymous, a token that doesn't verify a 401 with
  `WWW-Authenticate`. `owner_only`, registered on the graph, reads post authors
  through `g.privileged()`. The seed runs as an admin viewer, through the same
  rules. Page sizes: `default_page: 20, max_page: 100`.
- `schema/auth.graphql`: `me` and `login`, resolved in `graph/resolvers.v`;
  `login` reads through a privileged graph, and gives one error for a wrong
  email or password.
- Found along the way: rules registered on the graph run before the model's,
  so an app rule that should defer to `allow_admin` has to skip admins itself.
  The README says so.
- Tests: `auth/jwt_test.v`; `main_test.v` over HTTP: login, tokens (expired,
  forged, malformed, `Basic`), reading by viewer (lists, counts, edges, nested
  connections, sensitive fields absent), creating, changing, users (signup,
  roles, own account, deletes, password change), stored hashes, config. SQLite
  only: the rules add plain conditions, which the other examples run on
  PostgreSQL.
- README: the rules table, where each lives, tokens, and a curl walkthrough
  from the running server. CI checks the example's generated code and schema.

### G7. OpenTelemetry

`vgraph.trace` reports each statement (kind, table, duration, failure; no values).
V has no OpenTelemetry SDK.

**Q129. Shape.** **Default:** a module, `five07.vgraph.otel`, so the core gets no
dependency:
- a span per statement, from `vgraph.trace`, with the semantic conventions'
  `db.system`, `db.operation.name` and `db.collection.name`, and no values; a span per
  GraphQL request and resolver (`graphql.operation.type`, `graphql.operation.name`),
  from a hook the `graphql` module's executor gains;
- the parent span from the request's `traceparent` header (W3C Trace Context), passed
  on through `with_ctx`;
- an OTLP/HTTP exporter (JSON), batched, to a collector URL;
- tests against a fake collector, and a check by hand against the OpenTelemetry
  Collector in Docker.
> A: I like that idea. We'll hold this idea until we create the `five07.vgraph.otel` package - it looks like no package exists.

**Skipped for now (2026-10-14):** held until `five07.vgraph.otel` exists, per the
answer; the user moved on to G9–G11. `vgraph.trace` stays the hook it builds on.

### G8. Federation v2 subgraphs

**Q130. Scope.** **Default:** a `vgraph gen --federation` flag makes the schema an
Apollo Federation v2 subgraph:
- `extend schema @link(url: "https://specs.apollo.dev/federation/v2.x", import: [...])`;
- each `node` table is an entity, `@key(fields: "id")`, and `_entities` resolves
  representations by id, one query per table, as `nodes` does;
- `_service { sdl }` returns the schema with its applied directives
  (`print_schema_with`), with `_Any`, `_Entity` and `_service` added;
- tested by composing `examples/service` with a second small subgraph through
  `@apollo/composition` from npm in CI, and once by hand behind Apollo Router.
> A: agreed

**Skipped for now (2026-10-14):** the user moved on to G9–G11. The docs list
Federation among what vgraph doesn't do yet.

### G9. Docs

**Q131. Where and what.** **Default:**
- a `docs/` folder of Markdown guides, linked from the README: getting started;
  schema (fields, edges, options, mixins, views, global ids); queries; writes; hooks,
  interceptors and privacy; transactions; GraphQL (schema, connections, mutations,
  options, operations folders, introspection, federation); migrations; drivers; tracing and
  OpenTelemetry; differences from Ent;
- the README cut down to an overview, a quick start and links;
- API docs from doc comments (`v doc`), built in CI without warnings;
- the guides' code taken from, or compiled in, the tests and examples, so it can't
  drift.
> A: agreed

**Result (2026-10-14): done.**
- `docs/`: an index (`README.md`) and eleven guides: getting started, schema,
  queries, writes, transactions, hooks/interceptors/privacy, GraphQL (schema,
  server, lists and connections, page sizes, filters, mutations, Node, options,
  your own fields, operations folders, introspection, the `graphql` module),
  migrations, drivers, tracing, differences from Ent. OpenTelemetry and
  Federation are left out (G7, G8 skipped), and named under "not there yet".
- Code that can't drift: `docs/snippets/`, a project with a blog (users,
  articles, comments, tags; a mixin, an enum, soft deletes, Nodes, a connection,
  a hand-written `search` field), whose tests run every snippet. A guide's ```v
  block follows `<!-- snippet: <path>#<name> -->` and must equal the region
  between `// snippet: <name>` and `// end snippet` (a path alone is the whole
  file, as for `schema/blog.graphql`). `docs_test.v` fails on a difference or an
  unmarked ```v block, in `docs/*.md` and the README; `UPDATE_SNIPPETS=1`
  rewrites the blocks instead. 42 blocks are checked.
- The README is an overview, a quick start (three snippets), what vgraph does,
  links to the guides and examples, Contributing and Credits (G10): 676 lines to
  about 220. Everything it said moved to a guide.
- API docs: `.vdocignore` leaves out `examples/`, `docs/`, `regressions/` and
  `cmd/`, so `v doc -f html -m` builds the six library modules; CI builds them
  (it fails on a doc that doesn't build; `v doc` prints no warnings of its own,
  and `v vet` already checks doc comments).
- CI: `docs/snippets` in the generated-code check and graphql-js.
- Found along the way: a V compiler bug. In a generic function of a module that
  imports `v.migrations`, a field whose type is the caller's enum named `Status`
  passes `$if field.typ is $struct` (`migrations.Status` is a struct), so
  `Schema.add` took an app's `Status` enum for a relation and dropped the column.
  `regressions/comptime_enum_struct_name/` shows it; `schema.v` now tests for an
  enum first; `schema_test.v` checks it (and fails without the fix).

### G10. README: Contributing and Credits

**Q132. Content.** **Default:**
- **Contributing:** the development setup (the `~/.vmodules/five07/vgraph` link,
  tests, PostgreSQL, graphql-js), branches (`develop` for work, `main` for releases),
  regenerating the examples, a `regressions/` program for each compiler bug, doc
  comments and style, and issues and PRs through GitHub (G11);
- **Credits:** Ent and entgql (the design and names vgraph follows), graphql-js (the
  reference its GraphQL module is tested against), the GraphQL and Relay specs, V, its
  ORM and `v.migrations`, and `rest-api`, which `examples/service` started from.
  Anyone else to name?
> A: graphql.org and vlang.io

**Result (2026-10-14): done.** In the README:
- Contributing: issues and PRs (the forms of G11), setup (V commit, the
  `~/.vmodules/five07/vgraph` link), tests (SQLite, PostgreSQL, graphql-js,
  coverage), layout, branches, regenerating the examples and `docs/snippets`,
  the snippet workflow, a `regressions/` program per V bug, style.
- Credits: Ent and entgql, graphql-js, graphql.org with the GraphQL and Relay
  specs, V (vlang.io), its ORM and `v.migrations`, and `rest-api` (not linked:
  it has no public home that I know of).

### G11. GitHub issue templates

**Q133. Which.** **Default:** adapted from `vlang/v`'s `.github/ISSUE_TEMPLATE/`:
- a bug report: V version and commit, vgraph version, database and driver, the model
  and the query that fail, the SQL `vgraph.trace` shows, expected and actual;
- a feature request: what it's for, and the Ent or entgql feature it maps to, if any;
- `config.yml`: blank issues off, and a link to the docs;
- a pull request template: tests, regenerated examples, docs;
- labels as in `vlang/v` where they fit (`bug`, `feature request`, `docs`), and
  `upstream` for a V bug.
> A: agreed

**Result (2026-10-14): done.** `.github/ISSUE_TEMPLATE/`: `bug_report.yml` (what
happened, expected, model, query, the SQL from `vgraph.trace`, V and vgraph
versions, database, connection, `v doctor`), `feature_request.yml` (what it's for,
the proposal, the Ent or entgql feature), `docs.yml`, and `config.yml` (blank
issues off; links to the guides and to V's issues). `.github/pull_request_template.md`:
tests, generated code, docs and snippets, fmt and vet, regressions. The forms set
the labels `bug`, `feature request` and `docs`; with `upstream`, they must be
created on the repository (GitHub ignores a form's label that doesn't exist).

### G12. Fixes in V

vgraph works around these; fixing them in V lets it drop code.
- **`orm.RawConnection`:** an optional interface (`exec_raw(query, params
  []Primitive) ![][]Primitive`, `dialect()`) that the SQLite, PostgreSQL and MySQL
  drivers implement through their typed bind paths (`sqlite_stmt_binder`,
  `pg_stmt_binder`), so raw SQL gets typed parameters, NULL and typed results. Then
  vgraph's `sqlite` and `pg` adapters can go.
- **`[]u8` columns:** the ORM can bind one, but can't create one on SQLite (`Unknown
  type`) or read one back (`sqlite_select_column`, `db.pg`). Then vgraph can add bytes
  fields.
- **`db.pg` and `u16` / `u32` / `u64`:** decoded wrongly (`*unsafe { &u32(&data) }`
  after `str.int()`); vgraph reads them as `i64`, `u16` too since G2. Worse, V compiles
  `orm.Primitive(*unsafe { &u16(&data) })` to a pointer to the local `data`, which
  dangles once `val_to_primitive` returns (`regressions/sum_type_deref_cast.vv`,
  found in G2): a `u16` field reads back as 0 whenever the stack is reused, as under
  `v -coverage`. The fix in `db.pg` is to convert (`u16(str.u64())`), not reinterpret;
  the fix in V, to copy the value into the sum type.
- **The 10 compiler bugs in `regressions/`**, the latest an enum named as an
  imported module's struct (`comptime_enum_struct_name/`).

**Q134. How far.** **Default:** an issue for each, with a fix PR where the fix is
clear (the `db.pg` decode, `[]u8` on SQLite), and `RawConnection` proposed in an issue
first. vgraph drops a workaround only once its fix is in the V commit it pins. None
holds up v0.1.0.
> A: agreed, but we'll touch back on this last

### G14. Spike: select only the fields a request asks for

Today every select reads every column of the struct: `{ users { pets { name } } }`
runs `SELECT id, name, owner_id, deleted_at FROM pets WHERE owner_id IN (...)`. The
spike: from the GraphQL selection set, read only the columns it needs, here
`SELECT id, name, owner_id FROM pets WHERE owner_id IN (...)`. The client already has
part of this: `select('name')` reads the named columns and the key, and leaves the
rest at zero.

The columns a level needs, beyond its selected fields:
- the key, always (cursors, `node`, the next level's `IN`);
- the foreign key of the edge it was loaded through (`owner_id`), to group rows by
  parent, and those of the edges selected below it (`pet { owner }` needs
  `owner_id`); a polymorphic edge's type column too;
- the columns of `orderBy`, which connection cursors encode;
- a field a model maps to another name or computes, and a fragment's fields on each
  type (`... on Gadget`).

Tasks: map a selection set to columns in the generated resolvers, pass them through
`with_<edge>` and connections, and measure the gain on a wide table (time and bytes
read, SQLite and PostgreSQL). Write up what works, what it costs, and whether to
ship it.

**Q138. What may read a column the request didn't select?** Hooks only run on
writes, but privacy rules, interceptors and hand-written resolvers (`Resolvers`)
receive the rows, and could read any field. **Default:** narrow only the rows the
generated resolvers return to GraphQL; a model or table that declares a policy,
interceptor or hand-written resolver that reads rows opts in with
`graphql: {select_all: true}`, or the spike finds which fields each reads. The
other choice is narrowing everywhere, documented as "rows in a resolver have only
the requested columns".
> A:

**Q139. When.** **Default:** after G2 (coverage), before the features, so it lands
with its tests while the read paths are fresh from G1; it ships in v0.1.0 only if
the spike says yes and its tests pass. The other choice is after v0.1.0.
> A:

### G13. Release v0.1.0

Carried over from the old plan (its Q13 and Q119).

**Q135. Steps.** **Default:**
1. merge `develop` into `main`, so CI runs for the first time, and fix what fails;
2. pin V: a `0.5.x` release that includes `v.migrations` when there is one; else keep
   the master commit, and say so in the README and `v.mod`;
3. check the README and docs against the code, and set `v.mod`'s version;
4. tag `v0.1.0` on `main`;
5. submit to VPM once its GitHub login works again, with the `vlang` and
   `vlang-package` topics on the repository; until then, install from GitHub.
> A: yes, I am kinda waiting on `0.5.3` first

**Q136. Exit criteria for each goal.** **Default:** its tasks are done, or moved on
purpose with a reason; tests on SQLite and PostgreSQL where it touches the database;
`v fmt -verify`, `v vet`, the generated examples up to date and graphql-js all pass;
the README or docs describe it; its result is recorded under the goal.
> A: agreed
