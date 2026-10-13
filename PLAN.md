# vgraph: research and plan

An Ent-style ([entgo.io](https://entgo.io)) graph layer for V: edges declared once,
loaded in batches and traversed through a typed API, with schema changes applied
through V's own `v.migrations` module. It would be published on VPM as
`five07.vgraph`.

Questions are marked **Q** with a `> A:` line for your answer. Anything I've assumed is
marked **Default**.

---

## 1. Reference: V modules and VPM

### Links

| What | Where |
|------|-------|
| VPM, the package registry | <https://vpm.vlang.io> |
| Submit a package (GitHub login) | <https://vpm.vlang.io/new> |
| VPM's own source | <https://github.com/vlang/vpm> |
| Docs: creating modules | <https://docs.vlang.io/modules.html> |
| Docs: package management and publishing | <https://docs.vlang.io/package-management.html> (see "Publish package") |
| VPM guide: version ranges, lockfile | <https://github.com/vlang/v/blob/master/cmd/tools/vpm/README.md> |
| Standard library docs | <https://modules.vlang.io> |
| V ORM README (relations, `include`, joins) | <https://github.com/vlang/v/blob/master/vlib/orm/README.md> |

The same docs are in your checkout. It is V master at `53dd72c` (2026-10-12), which
reports itself as `V 0.5.2` but is 86 commits past the `0.5.2` tag (see Q13):
`~/Projects/vlang/v/doc/docs.md` ("Modules" around line 4285, "Package management"
around line 7664, "Publish package" around line 7912), `cmd/tools/vpm/README.md`, and
`vlib/orm/README.md`.

### What matters for a package

- **Module vs package:** a *module* is one folder of `.v` files sharing a `module`
  name. A *package* is one or more modules with a `v.mod` at the top, which also
  anchors imports (`import vgraph.load` resolves against the folder holding `v.mod`).
- **Names:** `snake_case`, and the docs say under 10 characters (`vgraph` is 6). VPM
  lowercases a name and turns `-` into `_` when installing.
- **Starting a project:** `v new --lib vgraph` creates `v.mod`, a library template
  and a git repository. `--agents-md` also writes an `AGENTS.md` contributor file.
- **`v.mod` fields:** `name`, `description`, `version`, `license`, `dependencies` (a
  string list, which may carry semver ranges such as `'vsl@^0.1.47'`), and optional
  `base_url` (the source folder) and `subdirs`.
- **Lockfile:** `v install` inside a project writes `v.mod.lock`. Commit it, and use
  `v install --locked` in CI.
- **Install locations:** `~/.vmodules` by default (`VMODULES` overrides it), or
  `v install --local` to install beside the project's own modules.
- **Publishing:**
  1. push a public GitHub repo with `v.mod` at its root;
  2. submit it at <https://vpm.vlang.io/new>, logged in with GitHub;
  3. it is then installed as `<github-user>.vgraph`.

  **The VPM entry can't be edited after submission, so check the name and repo URL
  first.** Tag the repo `vlang` and `vlang-package` on GitHub so it shows up in searches.
- **Releases:** semver tags (`v0.1.0`). VPM's version ranges select tags, and
  prereleases need an explicit prerelease constraint.
- **API docs:** `v doc` generates them from doc comments, so every `pub` item needs
  one, as in `rest-api`.

## 2. Prior art (checked 2026-10-12)

- **On VPM:** `v search` for `orm`, `graph`, `vgraph` and `dataloader` found no
  graph or edge-loading library. `vgraph` is unclaimed. The only near matches:
  - `luizfonseca.graphql`: a GraphQL *parser* only, work in progress, last updated
    about 3 years ago. It might serve as the parsing half of a GraphQL layer later.
  - `ghostnear.storm` / `ghostnear.vstorm`: an app framework for `gg` GUIs, unrelated.
- **V's ORM** (vlib, V 0.5.2) is relational:
  - has-many through `[]Child @[fkey: 'parent_id']`;
  - belongs-to through a struct-typed field;
  - implicit loading of those relations in `sql { }` blocks, or opt-in
    `include()` / `then_include()` in the `orm.new_query[T]` function API;
  - `join` / `left join` inside `sql { }`;
  - `@[references]` foreign keys.
  - **Gaps:** relation loading runs **one query per parent row** (stated in its
    README), there are no edge declarations, no generated client, and no polymorphic
    relations.
- **V's migrations** (`vlib/v/migrations`, added to master 2026-10-10, so **not** in
  the `0.5.2` tag): ordered, reversible migrations registered in V code
  (`migrations.new(mut db, [Migration{version, name, up, down}], Config{dialect: .sqlite})`),
  with `create_table`, `add_column`, `add_index` (normal and unique), `add_foreign_key`,
  `create_orm_table[T]`, and `migrate` / `rollback` / `redo` / `status`, for SQLite,
  Postgres and MySQL. Its tests pass on your local compiler. It doesn't diff a schema
  against the database or generate migration files: migrations are written by hand.
  The [announcement](https://vlang.veery.blog/post/25/introducing-orm-migrations-in-v)
  calls it `v3.migrations`; on master it is now `import v.migrations`.
- **Ent's model, which vgraph borrows:** a schema with `Fields()` and `Edges()`
  ([edges docs](https://entgo.io/docs/schema-edges)), a generator (`entc`) that writes
  a typed client, eager loading with `With<Edge>()` batched per level, traversal with
  `Query<Edge>()`, and migrations through [Atlas](https://atlasgo.io). vgraph uses
  `v.migrations` in place of Atlas (Q10).

## 3. Goals

1. **Batched edge loading:** loading an edge for N parents takes one query, not N. This
   is the core of the library, and what GraphQL resolvers need.
2. **Declared edges:** relationships are described once and checked when the program
   starts (`Client.new` validates every edge against the structs).
3. **Typed traversal and queries:** `client.articles().with_comments().all()!` and
   `article.query_comments().query_author().all()!`, through code generation.
4. **Built on `orm.Connection`**, so any adapter the ORM has (SQLite, Postgres, MySQL)
   works.
5. **GraphQL** (Phase 4): a schema, parser, validator, executor and HTTP handler of
   its own, in a module that can move to `five07.graphql` (Q19–Q24).
6. **Parity with Ent and entgql** (Q19, Q26): every Ent feature is planned. The ones
   vgraph lacks, the write API included, are Phase 6; the inventory is there.

**Non-goals for v1:** a migration engine of its own (Q10: `v.migrations` runs them),
Ent's Gremlin driver and its extensions other than entgql (Q37). Those are listed in
§8 for later.
*(2026-10-13: hooks, privacy and GraphQL execution were non-goals; Q19 and Q26 moved
them into scope.)*

## 4. Design

### Edges

As built in Phase 2 (`edge.v`):

```v ignore
pub enum EdgeKind {
	one_to_many  // Article.comments: the target table holds this record's id
	one_to_one   // User.card: as one_to_many, but at most one (added in Phase 3)
	many_to_one  // Comment.author: this table holds the target's id
	many_to_many // Article.tags: through a join table
}

pub struct Edge {
pub:
	name       string   @[required] // 'comments'
	kind       EdgeKind @[required]
	to         string   @[required] // target table: 'comments'
	column     string   @[required] // 'owner_id', 'user_id'; for many_to_many, the join column for this record
	type_col   string   // polymorphic: 'owner_type'
	type_val   string   // polymorphic: 'Article'
	through    string   // many_to_many: the join table
	through_to string   // many_to_many: the join column for the target
	soft_del   string   // optional: 'deleted_at', filtered as IS NULL (Q7)
}
```

Changes from the first draft:
- **No `polymorphic` kind.** `type_col` / `type_val` work on both directions: on a
  `one_to_many` edge they filter the targets (`Article.comments`), and on a
  `many_to_one` edge they filter the records followed (`Comment.article`).
- **No `from` field.** `Schema.add[T]()` knows the declaring table.
- **`through_to` is new.** A join table has two key columns.
- **`one_to_one` is new** (Phase 3, after reviewing Ent's relationship kinds). It is
  the side without the foreign key; its index is unique (`migration_indexes`, Phase 5).

Ent's relationship kinds map onto these four. `examples/relations` declares and
tests each one:

| Ent | vgraph |
|-----|--------|
| O2O two types (user, card) | `one_to_one` + `many_to_one` |
| O2O same type (linked list next/prev) | self `many_to_one` + self `one_to_one` |
| O2O bidirectional (spouse) | self `many_to_one` with `unique` and `bidi` (6d): a unique index, and both rows written |
| O2M two types (user, pets) | `one_to_many` + `many_to_one` |
| O2M same type (tree) | self `one_to_many` + self `many_to_one` |
| M2M two types (groups, users) | `many_to_many` on both sides, join columns swapped |
| M2M same type (following, followers) | two self `many_to_many` edges, join columns swapped |
| M2M bidirectional (friends) | self `many_to_many`, each pair stored both ways by the app |

vgraph only reads, so a bidirectional edge is the app's job to write both ways.

`example` declares `users → articles/posts/comments`, `articles/posts → author`,
`articles/posts → comments` (polymorphic), and `comments → author/parent/article/post`
plus `replies`.

### Layers, in build order

| Layer | What | How | Phase |
|-------|------|-----|-------|
| `vgraph.load` | `load_one[C, P](conn, children, fk)`, `load_many[P, C](conn, parents, fk)`, `load_through` (join table): one `WHERE col IN (…)` per edge, de-duplicated ids | compile-time reflection (`$for field in T.fields`) plus `orm.Connection.select` (Q17) | 1–2 |
| `vgraph` (`Schema`, `Client`) | each entity declares `fn (Article) edges() []vgraph.Edge` (Q4); `Schema.add[T]()` reflects it; `Client.new` checks every edge; `client.load_one` / `load_many` load by edge name | plain V, checked at startup | 2 |
| `vgraph gen` | a CLI that reads the schema and writes `client/*.v`: typed `with_<edge>()`, `query_<edge>()`, field predicates | code generation, like `entc` | 3 |
| `graphql` | lexer, parser, validator, executor, introspection, HTTP handler | our own, in a module that never imports vgraph, so it can become `five07.graphql` (Q20, Q24) | 4 |
| `vgraph gen` GraphQL output | the SDL and the V resolvers for every table, batched through the generated client | code generation, like `entgql` (Q21) | 4 |
| migration helpers | turn declared edges into `v.migrations` steps: an index on every edge column, foreign keys, the join tables for many-to-many | helpers that return `migrations.Index` / `ForeignKey` / `Table`; `v.migrations` runs them | 5 (Q10) |
| Ent parity | the write API, transactions, field options, hooks, interceptors, privacy, the rest of Ent's query API, and entgql's generated mutations and connections | the core, `load` and the generator | 6 (Q26) |

**Why split reflection and code generation:** V's compile-time reflection reads fields
and attributes, which is enough for generic loading. It **can't create methods**, so
typed traversals (`.query_comments()`) and predicates (`article.title_contains('V')`)
need a generator, which is the same reason Ent has `entc`.

**SQL:** `sql { }` blocks are fixed at compile time. Even `dynamic select` only switches
whole conditions on or off; the column names stay fixed. So vgraph can't use them for an
edge column it only knows at runtime. Two routes work (Phase 0 tested both), and Q17
chooses between them:
- `orm.new_query[T](conn).where('${col} IN ?', ids)`, the ORM's function API. It is
  **deprecated**: it leaves the standard library after 2027-08-17 (notices now,
  warnings from 2027-02-18; [vlang/v#27001](https://github.com/vlang/v/issues/27001)).
- `orm.Connection.select(SelectConfig, QueryData, where)`, the driver interface every
  adapter implements, with vgraph mapping the rows back into `T` through `$for`. It
  isn't deprecated, but vgraph then maps every field type itself.

Either way, vgraph avoids `@[fkey]` and the ORM's implicit relation loading, which makes
N+1 queries.

## 5. V 0.5.2 risks, from building `rest-api`

| Found in rest-api | What it means for vgraph | Mitigation |
|-------------------|--------------------------|------------|
| Generics across modules: codegen bugs `../web` works around; a false "unused function" notice | vgraph is mostly generics, so it will hit more | build against your local V master for now and pin a `0.5.x` release before `v0.1.0` (Q13); keep a `regressions/` test folder with one small test per compiler bug, each reported upstream with a fix PR where we can (Q11) |
| `@[index]` creates no index on SQLite | edge columns need indexes | `ctx.add_index` in a `v.migrations` migration (raw `CREATE INDEX IF NOT EXISTS` only before Phase 5) |
| `sqlite.DB.exec` ignores errors raised while a statement runs | silent failures in hand-written SQL | always `exec_param_many`, or the ORM |
| a variable named `update` inside `sql { }` silently skips the statement | — | mostly avoided by not using `sql { }`; a lint rule |
| the ORM's `last_insert_rowid()` races across threads | inserts return the wrong id | look rows up by a unique key; transactions |
| macOS libsqlite3 is in multi-thread mode | crashes under concurrency | document `connect_full(..., [.fullmutex])`; test with concurrent requests |
| `@[references]` columns are nullable | — | `sql_type: 'INTEGER NOT NULL'` |
| `orm.new_query` (the function API) leaves vlib after 2027-08-17 | the plan's query layer goes away | build on `orm.Connection.select` (Q17) |

Phase 0 checks the reflection that the loader depends on before anything else is built.

## 6. Phases

**Phase 0: reflection spike** (in this repo, under `spike/`, about a day).
Confirm that, on your local V master (Q13), a generic function in one module can:
- read `T`'s fields and attributes;
- run `orm.new_query[C](conn)` with a `where … in […]` condition built at runtime;
- group the rows by a column whose name it only knows at runtime.

Also write a short README.md for your first commit on `main` (this repo has none
yet).

*Exit:* a test that loads comments for 3 articles in one query.

*Result (2026-10-12, done):* `spike/` passes on local master `53dd72c`. A generic
`load_many[P, C]` in the `load` module reads `@[primary]`, `@[sql: 'col']` and
`@[table]` through `$for`, queries `owner_id IN (…)` once for 3 articles (one of them
repeated), and groups the rows by a column named at runtime. A `CountingConnection`
(Q16) asserts the query count. No compiler workarounds were needed. Both query routes
in Q17 pass the same test.

**Phase 1: dogfood in `example/`.** Copy `rest-api` into `example/` in this repo (Q14).
It becomes the test bed for each feature and, later, the published example. Then:
1. before changing anything, run its tests and record a baseline of the SQL each
   endpoint runs (Q16);
2. replace `slugs_of` + `app.distinct` + the `Owner` registry's loading with
   `vgraph.load`, in-tree at first (Q15).

`~/Projects/vlang/rest-api` itself is left alone.

*Exit:* every `example` test still passes, and the traced SQL shows the same number of
queries or fewer than the baseline.

*Result (2026-10-12, done):* `example/` holds `rest-api` at `9d802d6`, renamed. Its
loading now runs through `example/vgraph/load` (`load_one`, `load_many`, polymorphic
via `Poly`), built on `orm.Connection.select` (Q17). `slugs_of` (four stores),
`app.distinct` and the registry's slug loading are gone; the registry keeps `id_of`.
`test_read_endpoints_query_counts` asserts the selects of 15 read endpoints, and gives
the same list before and after the swap (`rest-api` already batched). All 11 test files
pass. One compiler bug turned up: `vgraph/regressions/comptime_generic_call.vv`.

**Phase 2: standalone package.** Add `v.mod` (`name: 'vgraph'`, MIT) to this repo's root;
`v new --lib` would make a new folder, so copy what it generates instead. Move the
`Edge` and `schema` layers there, with a SQLite test suite and a Postgres CI job (Q3).
Before publishing, pin to a `0.5.x` release that includes `v.migrations` (Q13), and
record it in the README and CI. Then publish `v0.1.0` to VPM from
`github.com/five07/vgraph`.
*Exit:* `v install five07.vgraph` works in a fresh project, and `example` imports it.

*Result (2026-10-12, built; not yet published):*
- **Package:** `v.mod` (with `repo_url`) and the template's `.editorconfig` and
  `.gitattributes` are at the root.
- **`vgraph` module:** `Edge`, `Schema` and `Client` (`edge.v`, `schema.v`,
  `client.v`). `load/` moved up from `example/vgraph/load`. Inside the package the
  root imports it as plain `import load`: `import vgraph.load` fails in the repo's own
  tests, and `import five07.vgraph.load` only works through the `~/.vmodules` link.
- **`example`:** imports `five07.vgraph` through `~/.vmodules/five07/vgraph` (a link
  to this repo), declares `edges()` on its four models, and loads through
  `vgraph.Client`. Its query-count test is unchanged.
- **Tests:** `vgraph_test.v` (schema, validation, every edge kind),
  `load/load_test.v` (soft delete, join tables), and `pg_test.v` on PostgreSQL. All
  14 test files pass, `pg_test.v` against a local PostgreSQL 18.
- **CI:** `.github/workflows/ci.yml` runs `v fmt -verify`, `v vet` on the package,
  `v test` on SQLite, and `pg_test.v` against a `postgres:16` service, with V built
  at `53dd72c`. It hasn't run yet: it first runs on push.
- **Your decisions (2026-10-12):**
  - CI runs only on pushes to `main`, which include merges.
  - Keep building on V master. Until a release includes `v.migrations`,
    `Client.ensure_indexes()` (`migrate.v`) creates the indexes edges need with
    `CREATE INDEX IF NOT EXISTS`, and `example` uses it in place of its hand-written
    index. Phase 5 replaces it.
  - The whole plan is finished on `develop` before merging to `main` and tagging
    `v0.1.0`. VPM submission waits on VPM's OAuth problem.
  - The exit test (`v install five07.vgraph` in a fresh project) runs once the
    package is on VPM.
- `pg_test.v` runs only with `-d vgraph_pg`. `started_postgres` turned it on
  whenever any PostgreSQL process was running locally.

**Phase 3: generator.** First, the schema comparison from Q4: write the `example`
entities both as (a) `edges()` methods and as (c) a schema file, and choose one before
building `vgraph gen` on it. Then `vgraph gen` writes the typed client, and `example`
switches to it.
*Exit:* `example` uses no hand-written loading code.

*Result (2026-10-12, done; Q18 chose (a)):*
- **`vgraph gen [folder] [--out graph]`** (`cmd/vgraph`, logic in `gen/`) finds the
  structs with `edges()` by scanning the sources. It writes and runs a loader
  program in `.vgraph-gen/`, which registers them, validates the schema and prints
  it as JSON. It then writes `graph.v` plus one file per table, removes stale
  generated files (it never touches files without its header), and runs `v fmt`.
  Schema problems are reported as such, with exit code 1.
- **Generated API per table:**
  - typed predicates by column type (`where_<field>`, `_lt/_le/_gt/_ge`, `_in`,
    `_like`, `_is_null/_is_not_null`), plus `where(load.Cond...)` for anything else;
  - `order_by_<field>[_desc]`, `limit`;
  - `with_<edge>(configure ...)` for nested eager loads, one query per edge;
  - `all`, `first` (`NotFoundError`), and `nodes(rows)` to load edges onto rows
    you already have;
  - on each node, `query_<edge>()` for traversal (`!` for many_to_many, which
    reads the join table first).
- **Support code:**
  - `load` gained `Cond` / `Query` / `select_where` (conditions, order, limit),
    `link_pairs` and `unique`;
  - `Schema` keeps columns in field order, with their V field names and types, and
    tables in registration order.
- **`example`:** uses `example/graph/`, generated and checked in. Its comment,
  article and post views load through it. The `Owner` registry is down to `id_of`.
  The query-count test is unchanged: the same selects, in the same order. The
  stores keep their own root queries (`find_by_user` and similar), which are queries
  rather than edge loading.
- **Tests:** `gen/gen_test.v` (discovery, naming, the loader) and
  `cmd/vgraph/gen_test.v`, which generates a client for a throwaway project with a
  join table, a polymorphic edge in both directions, a nullable self-edge and soft
  deletes, and runs that project's tests against it, query counts included. All 16
  test files pass, PostgreSQL included.
- **CI:** CI fails if `example/graph` isn't what `vgraph gen` produces from the
  current models.
- **Compiler bugs found:** a second one, `regressions/shadowed_fn_call.vv`: a
  variable named like the function it calls generates invalid C on master.
- **Relationship coverage (added after review):** `one_to_one` was missing, so the
  user side of O2O came out as a list. Added to the core, the runtime `Client`,
  unique indexes and the generator (`?&Node`, first row wins).
  `examples/relations` has a test for each of Ent's eight kinds. The generator now
  rejects table and edge names its output needs for itself.

*Schema comparison (2026-10-12), for Q18: chose (a).* `example` had the same schema
both ways, (a) `edges()` on each model and (c) a `schema.toml`, with a test that they
declared identical edges. Both were removed once (a) was chosen.

| | (a) `edges()` methods | (c) `schema.toml` |
|---|---|---|
| Where | next to each struct | one file for the whole graph |
| Checked | kinds and names by the compiler; columns at `Client.new` | names when parsed; columns at `Client.new` (if a runtime `Schema` is built from it) |
| Fields for predicates | reflection, from the real structs | must be listed again in the file, or taken from the structs anyway |
| How `vgraph gen` reads it | writes a small program that imports the models and dumps the reflected schema as JSON, runs it (a few seconds), and generates from the JSON | parses the file: fast, no compile, if fields are listed |
| Runtime without gen | works today (`Schema.add[T]()`) | needs a loader that maps tables to structs, so in practice still `add[T]()` |
| Non-V tools (GraphQL, migrations) | read the JSON that gen dumps | read the file directly |

Either way the generated client is the same. Sketch, for `articles`:

```v ignore
// example/graph/articles.v, generated
pub fn (g Graph) articles() ArticleQuery
pub fn (q ArticleQuery) where_slug(slug string) ArticleQuery          // field predicates
pub fn (q ArticleQuery) with_author() ArticleQuery                     // eager loads, batched
pub fn (q ArticleQuery) with_comments(f fn (CommentQuery) CommentQuery) ArticleQuery
pub fn (q ArticleQuery) all() ![]ArticleNode
pub fn (q ArticleQuery) only() !ArticleNode
pub struct ArticleNode {
pub:
	article  article_models.Article
	author   ?UserNode      // set by with_author()
	comments []CommentNode  // set by with_comments()
}
pub fn (n ArticleNode) query_comments() CommentQuery                  // traversal
```


**Phase 3.1: Ent relationships, and `examples/`** (2026-10-12, done).
- **Layout:** `example/` moved to `examples/service/`, renamed `service`. Earlier
  phases call it `example`.
- **New example:** `examples/relations/` covers every Ent relationship kind (table
  under Design).
- **Shared checks:** the checks live in `checks.v`, so the same nine run on SQLite
  (`main_test.v`) and on PostgreSQL (`pg_test.v`, `-d vgraph_pg`). Both pass.
- **What the checks cover:** for each kind, eager loading (`with_<edge>`, nested
  where it applies), every generated traversal (`query_<edge>`, 14 of 14), the
  queries run (one per edge, two through a join table), and missing targets
  (`none` and empty lists). For `one_to_one`, the unique index rejects a second
  card for the same user.
- **CI:** the PostgreSQL job runs both PostgreSQL tests. The generated-code check
  covers both examples.

**Phase 3.2: non-int keys** (Q43). Before GraphQL, because Phase 4's generated
resolvers sit on the load API. `load` keys everything by the key's string form
internally (`map[string]`) and accepts `int`, `i64` and `string` primary and foreign
keys; `Schema.validate` checks that an edge column's type matches its target's key.
The generated client stays typed: `where_id(value string)` on a UUID table. No third
generic key parameter, since generics are where the compiler bugs in `regressions/`
came from. A UUID is a `string` field (`TEXT`, or `uuid` through `sql_type` on
PostgreSQL), as V has no UUID type.
*Exit:* `examples/relations` gains a UUID-keyed table with edges in both directions,
tested on SQLite and PostgreSQL, and everything else passes unchanged.

*Result (2026-10-13, done):*
- **`load`:** keys travel as strings (`load/keys.v`): `key_column` reads an `int`,
  `i64` or `string` key (or an option of one) as its `str()`, `key_type` finds a
  column's type, and `in_keys` turns string keys back into `[]int`, `[]i64` or
  `[]string` for the `IN` query. `load_one` / `load_many` / `load_through`, and
  `Client`'s, return `map[string]`. `link_pairs` takes both columns' key types.
  `in_i64s` is new; `int_column` is gone.
- **Validation:** an edge's column must have the type of the key it holds, and a key
  must be an `int`, `i64` or `string`. `ColumnKind` gained `i64`.
- **Generator:** the generated loads key their maps by `.str()`, join-table reads
  pass both key types, and `i64` columns get `where_<field>_in`. The generated API is
  unchanged for int keys; on a UUID table it is `where_id(value string)`.
- **`examples/relations`:** `devices` is keyed by a UUID (`uuid` on PostgreSQL), with
  edges of every kind to and from it (`test_uuid_keys`). `load_test.v` and
  `vgraph_test.v` cover `i64` and string keys and the new validation.
- **Tests:** all 16 test files pass, and both PostgreSQL tests against PostgreSQL 18.
  `examples/service`'s query counts are unchanged.
- **Compiler bug found:** a third, `regressions/generic_result_map_arg.vv`: a generic
  function returning `![]T`, given an array literal of the wrong element type and
  followed by `.map(...)`, compiles without the type error and segfaults.

**Phase 4: GraphQL.** Without it, vgraph can't serve GraphQL to a client at all:
it has no GraphQL schema, parser or executor, and V's standard library has none.
So it is built here, in this repo, and moved to its own package (`five07.graphql`)
later if that's needed (2026-10-12; revises Q9).

Decisions, from Q19–Q35 (2026-10-13):
- **GraphQL only.** Phase 4 builds on what vgraph does today. The Ent features vgraph
  lacks, the write API included, are Phase 6 (Q26).
- **`graphql/` module:** our own lexer, parser, validator and executor, never
  importing vgraph, so it can move to `five07.graphql` (Q20, Q24). The parser reads
  the whole spec: executable documents, and the type system (SDL), including
  `extend type`, since `vgraph gen` merges hand-written `.graphql` files (Q30, Q33).
- **Schemas follow the spec, as Apollo and graphql-js read and write them** (Q30). The
  generated SDL loads in graphql-js's `buildSchema`, and our parser reads SDL that
  graphql-js prints. Apollo's runtime extras (Sandbox page, error codes, persisted
  queries, Federation) are future state (§8).
- **Validation:** every rule in the spec, tested with cases ported from graphql-js,
  plus a maximum depth and number of selections (Q31).
- **Queries and mutations** (Q19, Q27). The executor runs both, mutations serially.
  Until Phase 6e generates them, the app declares mutations in `.graphql` files and
  writes their resolvers; `examples/service`'s call its stores.
- **Generated schema, entgql's conventions** (Q21, Q28): see "GraphQL naming" below.
- **Arguments:** list fields take `where`, `orderBy` and `limit` / `offset`, and each
  table gets a count. The generated V queries gain `count()` and `offset()`, the only
  additions to vgraph's query API in this phase. Relay connections are Phase 6e (Q22).
- **Hidden fields and tables:** `@[graphql: '-']` on a field or struct (Q29).
- **Batching:** level by level; resolvers receive every parent at once, and the
  generated ones run one load per edge per level. Nested `limit` / `offset` is cut
  per parent in V until 6e moves it into SQL (Q32).
- **Hand-written fields and operations** in `*.graphql` files, merged by `vgraph gen`,
  with resolver stubs in a file it never overwrites (Q33).
- **Transactions:** the HTTP handler takes an optional transaction wrapper; a
  request's mutations then share one transaction (Q34).
- **Introspection** (Q23), and an HTTP handler any framework can call, with
  `POST /graphql` in `examples/service` on veb. No subscriptions (Q24).
- **Cleanup:** delete `spike/` (Q25).

GraphQL naming, from entgql (Q28):
- types are named after the struct (`Article`); fields are the Go-style camelCase
  entgql produces from Ent's field names, so `created_at` is `createdAt` and
  `owner_id` is `ownerID`;
- ids are `ID!`. A foreign key column is a field (`ownerID: ID`), as entgql exposes
  a field that an edge is bound to, and in vgraph every edge column is one;
- edges are fields: unique edges (one_to_one, many_to_one) nullable, the others
  `[T!]!`; polymorphic edges stay separate fields;
- `time.Time` is the `Time` scalar;
- `where: ArticleWhereInput` uses entgql's names: `title`, `titleNEQ`, `titleIn`,
  `titleNotIn`, `titleGT` / `GTE` / `LT` / `LTE`, `titleContains`, `titleHasPrefix`,
  `titleHasSuffix`, `titleIsNil` / `titleNotNil`. Only the ones vgraph can run in
  Phase 4 are generated (`Contains` and the prefix/suffix forms are LIKE patterns);
  `and` / `or` / `not` and `has<Edge>` come with 6b and 6e;
- `orderBy: ArticleOrder` is `{ field: ArticleOrderField!, direction: OrderDirection }`,
  as entgql's; `limit` / `offset` are vgraph's own until connections (6e);
- root fields: one list per table, named as entgql's `QueryField` names it
  (`articles`). One row is read with `articles(where: {id: 3})`. `Node`, `node` and
  `nodes` wait for globally unique ids in 6d (Q42).

Exit (Q35): `examples/service` serves `POST /graphql` beside its REST routes, with a
query or mutation for every REST endpoint, asserting the same selects as REST;
`examples/relations` tests each relationship kind through GraphQL; the parser and
validator pass the graphql-js cases; the introspection result matches a checked-in
copy, and Apollo Sandbox and GraphiQL load the schema (by hand, once); SQLite and
PostgreSQL pass in CI, which also checks the generated schema and resolvers are up to
date.

*Result (2026-10-13, done):*
- **`graphql/`** (`five07.vgraph.graphql`; imports only V's standard library):
  - lexer, parser and printer for the whole language, executable and SDL;
  - schemas built from SDL with extensions, printed as graphql-js prints them, and
    checked with graphql-js's schema validation (`validate_schema`);
  - every validation rule of the spec, graphql-js's recommended
    `MaxIntrospectionDepthRule`, its two custom rules (`NoDeprecatedCustomRule`,
    `NoSchemaIntrospectionCustomRule`, as `no_introspection`), and vgraph's limits
    `max_depth` and `max_selections` (Q31);
  - variable and argument coercion with graphql-js's messages; the five scalars,
    custom scalars (`Scalar`), enums, `@oneOf`;
  - the executor: batched resolvers (`Resolver` gets every parent at a level),
    abstract types, `@skip` / `@include`, null propagation with error paths,
    serial mutations, an optional `Transaction` around a request's mutations;
    subscriptions are refused;
  - introspection, and `introspection_query`;
  - `Server.handle`, GraphQL over HTTP for any framework: POST JSON, GET for
    queries only (405 otherwise), `application/graphql-response+json` with 400 for
    request errors when the client accepts it, else `application/json` and 200.
- **Conformance with graphql-js** (`graphql/testdata/`): its own test suite was run
  with a recorder, and every recorded case matches exactly, messages and locations
  included: 166 lexer cases, 697 parse and print cases, 156 schemas built and
  printed, 439 validation cases and 102 SDL validation cases. The introspection of
  two schemas matches graphql-js's byte for byte. CI checks that graphql-js
  (npm, 16.11.0) builds, validates and prints the generated schemas unchanged.
- **Generator:** `vgraph gen` writes `graph/schema.graphql`, `graph/graphql.v`
  (`Graph.graphql(r Resolvers)`) and, once, `graph/resolvers.v`:
  - types per table with entgql's names; list edges are `[T!]`, as entgql writes
    them without connections, not `[T!]!`;
  - `WhereInput` with entgql's predicate names: `NEQ`, `In`, `NotIn`, `GT`/`GTE`/
    `LT`/`LTE`, `Contains`/`HasPrefix`/`HasSuffix` on strings, `IsNil`/`NotNil`;
  - `Order` / `OrderField` / `OrderDirection` as entgql's;
  - edge resolvers reuse `with_<edge>`; nested `limit` / `offset` cut per parent;
  - `.graphql` files anywhere in the project are merged; problems are reported at
    their file and line;
  - stubs for the fields they add to `Query`, `Mutation` or a generated type, as
    methods of `Resolvers` (gqlgen's pattern: the struct holds what they need);
    fields of the files' own object types use the default resolver.
- **Client and `load`:** `offset()`, `count()`, `not_in_*`, and a fix: a
  many_to_many load now keeps the order of the edge's query (it kept the join
  table's).
- **`examples/service`:** `POST /graphql` and `GET /graphql`; `api.graphql` has a
  mutation for each of the 14 REST endpoints that write, resolved through the same
  stores and comment service; mutations share a SQLite transaction. Tests: each of
  the 15 REST reads has a GraphQL query running the same selects; every mutation,
  with REST's messages; rollback; introspection over HTTP equals graphql-js's.
- **`examples/relations`:** `check_graphql` on SQLite and PostgreSQL.
- **Phase 3.2 and 4 together:** all 18 test files pass (20 with the 2 PostgreSQL
  ones, against PostgreSQL 18).
- **Compiler bugs found:** three more in `regressions/`: `smartcast_array_interpolation.vv`,
  `map_nested_field_name.vv`, `const_loop_var/` (a `for` variable clashing with a
  const of the main module).
- **Not done here:** opening Apollo Sandbox and GraphiQL by hand (Q35). Both read
  the schema through introspection, which matches graphql-js's.
- **Left for Phase 6:** `Contains` / `HasPrefix` / `HasSuffix` are LIKE patterns, so
  `%` and `_` in the value act as wildcards (the ORM has no `ESCAPE`); no
  `EqualFold` / `ContainsFold`, and no `In` on floats and times; `i64` columns are
  `Int`, as in entgql, so values past 32 bits fail.

**Phase 5: migration helpers** for `v.migrations` (Q10): from the declared edges,
produce the indexes, foreign keys and join tables as `migrations.Index` /
`ForeignKey` / `Table` values, for migrations written by hand. `examples/service` moves its
table setup to `v.migrations`. Questions: Q44–Q50, all answered with the defaults
(2026-10-13).

*Result (2026-10-13, done):*
- **`migrate.v`** (imports `v.migrations`): `Schema.migration_indexes()`,
  `foreign_keys()`, `join_table(table, edge)`, and `add_edge_indexes` /
  `remove_edge_indexes` for a migration's `up` and `down`, as Q44–Q46 describe.
  Index names are unchanged (`<table>_<columns>_idx`); foreign keys are
  `<table>_<column>_fkey`. `vgraph.Index`, `Index.sql()`, `Schema.indexes()` and
  `Client.ensure_indexes()` are gone (Q47).
- **Join tables:** each now gets a unique index on its two columns (sorted, so the
  two directions of an edge share it), beside the index on each column. The
  single-column index on the pair's first column is redundant with it; it is kept
  so edge indexes stay as before.
- **Schema:** `Column.sql_type` holds a field's `sql_type` attribute, so a join
  column for a `sql_type: 'uuid'` key is `uuid`.
- **Generator:** `graph.v` has `pub fn schema() !vgraph.Schema`, which
  `Graph.new` calls, so a migration gets the schema without a connection.
- **`examples/service`:** `migrations/` (module `migrations`, importing
  `v.migrations as vm`) has `1 initial`: `create_orm_table` for the four models,
  then `add_edge_indexes(graph.schema())`; `down` drops the tables. `new_app_on`
  migrates `db`, not the counting `conn`. The four `create_tables` are gone, and
  the store tests create their tables themselves. `test_startup_migrates`: two
  startups, `status()` is `1 initial applied`, the five indexes are those
  `ensure_indexes` made, rollback drops everything, and migrate restores it. The
  query-count tests are unchanged.
- **`examples/relations`:** `checks.v` has the same kind of migration, run by
  `migrate` on SQLite and on PostgreSQL (`pg.connect_direct`). The unique-index
  check now also rejects a duplicate join row.
- **Tests:** `vgraph_test.v` covers the indexes, foreign keys (none on polymorphic
  columns), join tables with int and UUID keys, and a migrate and rollback on
  SQLite, where the join table rejects a duplicate pair and an unknown key.
  `pg_test.v` runs the helpers through a migration on PostgreSQL, with
  `add_foreign_key`. All 18 test files pass, and both PostgreSQL tests pass
  against PostgreSQL 18. CI is unchanged and hasn't run (it runs on `main`).
- **Compiler bug found:** a seventh, `regressions/sql_transactional_connection.vv`:
  an `sql` block rejects a value typed `orm.TransactionalConnection`, though it
  embeds `orm.Connection`. `examples/relations` passes the database to `migrate` and
  `seed` separately.
- **Caveat, documented in the README:** a migration that calls `add_edge_indexes`
  with the current schema makes the indexes the edges need *now*. When a later
  migration adds edges, the first one has to list its own indexes instead.

**Phase 6: Ent parity** (Q19, Q26). Everything in Ent and entgql that vgraph doesn't
have yet. The sub-phases are a proposal, in dependency order:
- **6a, writes:** create, bulk create, update, delete, edge writes, transactions,
  field options and validators (Q38, Q39);
- **6b, queries:** the rest of Ent's query API (OR/NOT, edge predicates, query-level
  traversal, `select`, aggregates, locking);
- **6c, runtime:** hooks, interceptors, privacy, and passing a context (Q40, Q41);
- **6d, schema:** more field types, custom id types, globally unique ids (each table's
  ids in their own range, set by the migration helpers) and GraphQL's `Node` with
  them (Q42), edge schemas, mixins, declared indexes, views;
- **6e, entgql:** generated mutations, Relay connections, the full `WhereInput`,
  multi-field ordering and per-parent pagination;
- migration helpers (Phase 5) grow with each sub-phase's schema options (Q36).

Decisions (2026-10-13):
- **Order:** Phase 5 comes first and covers edges; each Phase 6 sub-phase extends the
  migration helpers for what it adds (Q36).
- **Writes** (Q38): generated builders per table, `create()`, `update_one()`,
  `update()`, `delete_one()`, `delete()`, with `set_` / `clear_` / `add_<edge>_ids` /
  `remove_<edge>_ids`. A create runs its insert, `last_id()` and edge writes in one
  transaction, and uses `RETURNING id` on PostgreSQL.
- **Field options** (Q39): an optional `fields()` method beside `edges()`, listing
  only the fields that need options; the rest are inferred. It absorbs
  `@[graphql: '-']` (Q29), which keeps working.
- **Hooks** (Q40): `fn (Article) hooks() []vgraph.Hook`, plus runtime hooks on the
  `Graph`. `examples/service` moves its store logic (validation, slugs, timestamps,
  soft delete) into hooks, and its hand-written GraphQL mutations become generated
  ones.
- **Context** (Q41): `g.with_ctx(ctx)` returns a `Graph` whose queries and writes
  pass `ctx`, a value the app defines (its user, request, and so on), to hooks,
  interceptors and privacy rules. The GraphQL handler sets it per request. Hooks
  depend on it, so 6c's design starts from it.

Decisions before 6a (Q51–Q60, 2026-10-13):
- **SQL layer** (Q51): vgraph writes its own parameterized SQL where `orm.Connection`
  can't, through a `vgraph.Driver` with adapters for SQLite and PostgreSQL only. A
  plain `orm.Connection` still works, with workarounds, or an error naming the
  adapter. An upstream `orm.RawConnection` is future state (`TODO.md`).
- **Order** (Q52): 6a → 6c → 6b → 6d → 6e. **Exit** (Q59): the default, per sub-phase.
- **Context** (Q53): `vgraph.Context`, an empty interface; `g.with_ctx(ctx)`.
- **Hooks** (Q54): untyped schema hooks in `hooks()` on the models, on
  `vgraph.Mutation`, and typed runtime hooks on the `Graph`.
- **Field options** (Q55), **write results** (Q56) and **upsert** (Q57): the defaults.
- **`examples/service`** (Q58): unchanged until Phase 6 is complete. Then its REST API
  is removed and it runs on vgraph alone: generated queries, writes, hooks and
  mutations. This replaces Q40's plan to move its stores into hooks along the way,
  and Q35's REST-to-GraphQL query-count comparison ends with it.
- **`TODO.md`** (Q60): held. Its items wait for a new plan after `v0.1.0`; Phase 6
  doesn't take them on.

Inventory (2026-10-13), checked against Ent's docs. "Extra" marks what vgraph has
that Ent doesn't.

| Area | Ent feature | vgraph today | Phase |
|---|---|---|---|
| **Fields** | types: ints of every size, floats, bool, string/text, time, bytes, JSON, enum, UUID, `Other` | all but bytes, which V's ORM can't store (`TODO.md`); JSON through `Field.json`; UUID as `string` | 6d (done) |
| | `Optional`, `Nillable` | `Field.optional`; option types are nullable; `set_nillable_<field>` | 6a (done) |
| | `Default`, `DefaultFunc`, `UpdateDefault` | `default`, `default_now`, `update_default`, `update_now` | 6a (done) |
| | `Immutable`, `Sensitive` | `immutable` (no update setter); `sensitive` leaves GraphQL only, as V's `str()` can't be changed | 6a (done) |
| | `Unique`, `StorageKey`, `SchemaType`, `Comment`, `Deprecated` | `@[unique]` / `Field.unique`, `@[sql: 'col']`, `sql_type`, `Field.comment` / `deprecated` (descriptions and `@deprecated` in GraphQL) | 6a, 6d, 6e (done) |
| | validators: `Validate`, `MinLen`, `MaxLen`, `NotEmpty`, `Match`, `Range`, `Positive` | `validate`, `min_len`, `max_len`, `not_empty`, `pattern`, `min` / `max`, `positive` | 6a (done) |
| | custom types: `GoType`, `ValueScanner` | type aliases; no `ValueScanner` (Q84) | 6d (done) |
| | id types: `i64`, string (UUID) | `int` only (Q6) | 3.2 (Q43) |
| | id types: custom (`GoType`, `ValueScanner`) | aliases of `int`, `i64`, `string` | 6d (done) |
| **Edges** | `To` / `From` with `Ref` (an edge and its inverse, checked together) | `Edge.ref`, checked by `validate`; `bidi` for bidirectional self edges | 6d (done) |
| | `Unique`, `Field` (the column holding the key) | the kind and `column` | done |
| | `Required`, `Immutable`, `StorageKey` | `required`, `immutable`; `column` / `through` | 6d (done) |
| | `Through`: edge schemas, join tables with fields of their own | a registered join struct | 6d (done) |
| | — | polymorphic edges, per-edge soft delete (extra) | done |
| **Schema** | declared indexes (fields, edges, unique, partial) | `indexes()`, unique and partial | 5, 6d (done) |
| | mixins (shared fields, edges, hooks) | embedded structs | 6d (done) |
| | annotations (`entsql`, `entgql`) | `@[table]`; `@[graphql: '-']`; `graphql()` options | 4, 6d, 6e (done) |
| | views, multiple database schemas | views (`@[vgraph: 'view']`); schemas §8 (Q91) | 6d (done) |
| **Queries** | predicates `EQ`, `NEQ`, `In`, `NotIn`, `GT`/`GTE`/`LT`/`LTE`, `IsNil`, `NotNil` | all, as methods and functions | 6b (done) |
| | `Contains`, `HasPrefix`, `HasSuffix`, `EqualFold`, `ContainsFold` | all, escaped; GraphQL's escaped too | 6b (done) |
| | `And`, `Or`, `Not` | `load.and`, `or`, `not` | 6b (done) |
| | `Has<Edge>`, `Has<Edge>With` | `has_<edge>`, `has_<edge>_with` | 6b (done) |
| | custom SQL predicates | `load.raw`, with parameters | 6b (done) |
| | order by several fields, by an edge's count or field, nulls first/last | `order_by_*` add columns; `order_by_<edge>_count`, `order_by_<edge>_<field>`; `nulls_first` / `nulls_last` | 6b (done) |
| | `Limit`, `Offset` | `limit` | `offset` in 4 |
| | `All`, `First`, `Only`, `IDs`, `FirstID`, `OnlyID`, `Count`, `Exist` | all | 4, 6b (done) |
| | `Select`, `Scan`, `Unique` | `select`, `scan[T]`, `unique` | 6b (done) |
| | `GroupBy`, `Aggregate` (count, sum, min, max, mean) | `sum_` / `min_` / `max_` / `mean_<field>`; `group_by(...).aggregate(...)` | 6b (done) |
| | `Modify`, raw SQL (`sql/modifier`, `sql/execquery`) | raw predicates; `Modify` left out (Q79) | 6b (done) |
| | `ForUpdate`, `ForShare` (`sql/lock`) | `for_update`, `for_share`, `no_wait`, `skip_locked`; PostgreSQL | 6b (done) |
| | traversal from a query (`users().where_…().query_pets()`) | `query_<edge>` on a query | 6b (done) |
| | traversal from a node | `query_<edge>` | done |
| | eager loading, nested and configured (`With<Edge>`) | `with_<edge>` | done |
| | named edges (`WithNamed<Edge>`) | `with_named_<edge>` | 6b (done) |
| | `Edges.<X>OrErr`: "not loaded" told apart from "empty" | `<edge>_or_err` | 6b (done) |
| | `entql`, generic filtering at runtime | the `load.Cond` tree, `prepare_query`, `select_keys_where` | 6b (done) |
| **Writes** | `Create`, `CreateBulk`, `MapCreateBulk` | `create`, `create_bulk`, `map_create_bulk` | 6a (done) |
| | upsert (`OnConflict`, `UpdateNewValues`, `Ignore`, `DoNothing`) | `on_conflict_columns`, `update_new_values`, `ignore`, `do_nothing`, with a driver | 6a (done) |
| | `Update`, `UpdateOne`, `UpdateOneID`: `Set`, `Add` (increment), `Clear`, `Append` | `update`, `update_one`, `update_one_id`; `set_`, `add_`, `clear_` | 6a (done); `Append` 6d, with JSON fields |
| | edge writes: `Add<Edge>IDs`, `Remove<Edge>`, `Clear<Edge>`, `Set<Edge>ID` | `add_` / `remove_<edge>_ids`, `add_` / `remove_<edge>`, `clear_<edge>`, `set_<edge>_id`, `set_<edge>` | 6a (done) |
| | `Delete`, `DeleteOne`, `DeleteOneID` | `delete`, `delete_one`, `delete_one_id` | 6a (done) |
| | the `Mutation` interface (changed fields, old values) | `vgraph.Mutation`, `MutationData`, a typed `<T>Mutation` per table; `old_field`, `old_<field>()` | 6a, 6c (done) |
| | transactions: `Tx`, `Commit`, `Rollback`, transaction hooks | `g.tx`, `Client.begin` / `commit` / `rollback`; `on_commit`, `on_rollback` | 6a, 6c (done) |
| **Runtime** | hooks: schema and runtime, `On` / `If` / `Unless` | `hooks()`, `g.use`, typed `g.<table>().use`; `on`, `only_if`, `unless` | 6c (done) |
| | interceptors: `Intercept`, `Traverse`, soft delete as an interceptor | `interceptors()`, `g.intercept`, typed `g.<table>().intercept` (before a query, as `Traverse`; no result rewriting); `soft_delete_query` / `soft_delete_hook`; per-edge `soft_del` | 6c (done) |
| | privacy: policies, rules, viewer context | `policy()`, `g.policy`, query and mutation rules, filter rules, `privileged()` | 6c (done) |
| | `context.Context` on every call | `g.with_ctx(ctx)`, passed on by the GraphQL server, to hooks, interceptors and rules | 6a, 6c (done) |
| | debug logging of queries | `vgraph.trace`, without values (Q67) | 6c (done) |
| **Codegen** | `entc` feature flags, external templates, extensions | `--no-graphql`; templates and extensions §8 (Q93) | 6d (done) |
| | `ent describe` | `vgraph describe` | 6d (done) |
| | schema visualization (entviz) | none | §8 |
| **Migrations** | automatic and versioned migrations, diffing through Atlas | versioned through `v.migrations`, written by hand, with vgraph's helpers (Q10) | 5 (done); no diffing |
| **entgql** | schema generation | `vgraph gen` | 4 (done) |
| | `Node` interface, global ids, `node` / `nodes` | `node: true` on tables with global ids | 6d, 6e (done) |
| | `CollectFields`: eager loads from the selection set | none | 4 (Q32) |
| | `WhereInput`: every predicate, `and`/`or`/`not`, `has<Edge>` | all, with `EqualFold` / `ContainsFold` and `In` on floats and times | 6e (done) |
| | `OrderBy` inputs, multi-field ordering | `orderBy: [TOrder!]`; edge counts; `order_field` | 4, 6e (done) |
| | Relay connections, cursors, `totalCount`, per-parent pagination | `relay: true`; keyset cursors; windows per parent | 6e (done) |
| | mutation inputs (`CreateXInput`, `UpdateXInput`, `SetInput`), generated mutations | `create<T>` / `update<T>` / `delete<T>`, inputs, `set_input` | 6e (done) |
| | annotations: `Skip`, `Type`, `QueryField`, `RelayConnection`, `Mutations`, `OrderField`, `Directives` | `GraphqlTable`, `graphql_skip_in`, `order_field`, `directives` | 4, 6e (done) |
| | `Transactioner` (a transaction per request) | `graphql.Transaction`; `vgraph.GraphqlTransaction` | 4, 6e (done) |
| **Other** | Gremlin driver; entproto, entoas/ogent | none | §8 (Q37) |

*Readiness review (2026-10-13), after Phase 5.* What Phase 6 builds on, and what
stands in its way. Questions: Q51–Q60.

What's there to build on:
- `load` reads through `orm.Connection.select` with `Cond` / `Query`; `count_where`
  uses the ORM's aggregate. Nothing in the package writes.
- `Schema.add[T]` reflects columns (type, nullability, `sql_type`, `graphql_skip`) and
  calls `edges()` through `$for method`; `fields()` and `hooks()` can be found the
  same way.
- `vgraph gen` gets the schema as JSON from a loader program. Closures (validators,
  default functions, hooks) can't go through JSON, so the generator only learns
  which options a field *has*; the generated code calls `fields()` and `hooks()` at
  runtime, through `schema()`.
- `graphql` already has `Context` (an empty interface passed to every resolver) and
  `Transaction` (begin, commit, rollback around a request's mutations).
- The ORM has `orm.TransactionalConnection`, `orm.Tx` with savepoints, `JoinConfig`
  (inner and left joins), `QueryData.parentheses` and `is_and` (so OR and grouping
  can be expressed), aggregates (`count`, `sum`, `avg`, `min`, `max`, one per
  select), `has_distinct`, and raw expressions in `select_exprs`.

What `orm.Connection` can't do (V master `53dd72c`), and which Ent features need it:

| Missing | Needed by |
|---|---|
| a row count from `update` / `delete` (both return `!`) | `update().exec()` / `delete().exec()` returning rows changed (Q38) |
| `RETURNING`; `last_id()` is an `int` (pg: `LASTVAL()`, stashed per thread on a pool) | `RETURNING id` on PostgreSQL (Q38), `i64` keys past 32 bits |
| parameters in raw SQL: `execute(query string)` takes none | anything vgraph writes as SQL itself |
| `NOT`, `NOT LIKE`, `ESCAPE` | `not`, `Contains` without wildcards, the `Fold` forms on SQLite |
| subqueries, `EXISTS` | `has<Edge>`, `has<Edge>With`, traversal from a query in one statement |
| `GROUP BY`, more than one `ORDER BY` column, `NULLS FIRST/LAST` | `GroupBy`, multi-field ordering, ordering by an edge's count |
| window functions | per-parent `limit` in SQL (Q32), connections' `first` per parent |
| `FOR UPDATE` / `FOR SHARE`, `ON CONFLICT` (upsert lives in the deprecated function API) | locking, upsert |

Every driver has a parameterized raw call, `exec_param_many(query, params)`
(`sqlite.DB`, `pg.DB` / `pg.Conn` / `pg.Tx`, `mysql.DB`), but it isn't on the interface,
and each returns its own `Row` type. Q51 decides how vgraph reaches it.

Other findings:
- **An import cycle shapes hooks.** The generated `graph` module imports the models;
  a model's `hooks()` can't import `graph`, so a schema hook can't see the generated
  `ArticleMutation`. Ent avoids this because `entc` generates the entity structs
  itself. Q54.
- **`Field` can't hold a typed validator per field.** `[]vgraph.Field` is one list,
  so `validate: fn (v string) !` (Q39's sketch) only fits string fields. Q55.
- **`examples/service` writes by slug and reads back by slug** (to avoid `last_id()`
  races, §5). Its store logic (normalize, validate, slug, timestamps, publish time,
  soft delete) maps onto field options and hooks; the `Owner` registry's `id_of`
  stays app code. *(Q58: it changes only once Phase 6 is complete.)*
- **Order.** Hooks (6c) need the `Mutation` that 6a defines, and Q41 puts the context
  first. Generated mutations (6e) replace `examples/service`'s hand-written ones only
  once hooks hold its logic (Q40), and `Node` (6e) needs globally unique ids (6d).
  So the order is 6a → 6c → 6b → 6d → 6e (Q52), not the letters' order.
- **Size.** 6a alone roughly doubles each generated table file (a create, update and
  delete builder, a mutation type, setters per field and edge). Generated code
  rather than generics keeps to what has compiled reliably (seven compiler bugs so
  far, all in generics or comptime).
- **`TODO.md` overlaps Phase 6:** pagination by config with a `pagination` example
  (6e), a hooks example with a JWT bearer token and access checks (6c privacy), OTel
  (6c, with `vgraph.trace`), polymorphic foreign keys (6d), and docs. Federation is
  already §8. *(Q60: held until after `v0.1.0`.)*

Work per sub-phase (Q51–Q60 answered):
- **6a, writes:** the SQL layer: `vgraph.Driver` and the SQLite and PostgreSQL
  adapters (Q51); `vgraph.Field` and `fields()` reflected by
  `Schema.add`, `@[graphql: '-']` folded in (Q39, Q55); `Context` and `g.with_ctx`
  (Q41, Q53); `g.tx(fn (tx Graph) !)` on `orm.TransactionalConnection`, with the
  GraphQL `Transaction` adapter built on it; the `Mutation` interface and a generated
  `<Table>Mutation` (op, set fields, cleared fields, edge ids added and removed, old
  values for update one) (Q54); generated `create` / `create_bulk` / `update_one` /
  `update` / `delete_one` / `delete` with `set_` / `add_` / `clear_` and edge setters,
  validators and defaults applied (Q38, Q56); upsert (Q57); migration helpers for
  field defaults and unique fields (Q36); tests on SQLite and PostgreSQL.
- **6c, runtime:** schema and runtime hooks with `on` / `if` / `unless` (Q40, Q54);
  interceptors on queries and traversals, with per-edge `soft_del` re-expressed as
  one; privacy policies (allow, deny, skip) on queries and mutations; `vgraph.trace`
  (Q16).
- **6b, queries:** `and` / `or` / `not`; `NEQ`, `NotIn`, escaped `Contains` /
  `HasPrefix` / `HasSuffix`, `EqualFold` / `ContainsFold`; `has_<edge>` /
  `has_<edge>_with`; traversal from a query; `only`, `ids`, `first_id`, `only_id`,
  `exist`; `select` / `scan`, `unique`; `group_by` / `aggregate`; several order
  fields and order by edge; `for_update` / `for_share`; named edges; "not loaded"
  told apart from "empty"; raw predicates and modifiers.
- **6d, schema:** more field types (sized ints, `u*`, `f32`, bytes, JSON, enums),
  custom key types, globally unique ids through the migration helpers, edge
  inverses (`ref`) checked together, `required` / `immutable` edges, edge schemas,
  mixins (embedded structs), declared indexes, views, `vgraph describe`, generator
  options.
- **6e, entgql:** `Node` / `node` / `nodes`; generated `create<T>` / `update<T>` /
  `delete<T>` mutations with `Create<T>Input` / `Update<T>Input`; Relay connections
  with cursors, `totalCount` and per-parent pagination in SQL; the full
  `WhereInput`; multi-field `orderBy`; the remaining annotations.
- **Also for 6e** (2026-10-13, asked in chat; questions when 6e starts): named
  operations (`query GetUser { … }`) in the project's `.graphql` files are silently
  dropped by `vgraph gen` today: `validate_sdl` accepts them and `build_ast_schema`
  ignores them.
  - (a) report them: `vgraph gen` fails on an operation in a schema file, with its
    file and line; a convention such as `operations/*.graphql` for operations;
  - (b) stored operations ("trusted documents"): the server loads named operations
    at startup, clients send `operationName` and variables only, and the server can
    refuse anything else; close to Q30's persisted queries, fixed at build time;
  - (c) a typed V client per operation, generated from those files (as gqlgen's and
    graphql-codegen's clients); likely §8.
- **After 6e** (Q58): `examples/service` drops its REST API and stores, and runs on
  vgraph alone.

Decisions before 6c (Q61–Q69, 2026-10-13): the defaults. Trace events carry no
values: no parameters, and no error messages (Q67).

Decisions before 6d (Q82–Q94, 2026-10-13): the defaults.

Decisions before 6b (Q70–Q81, 2026-10-13): the defaults; reads that need SQL the
ORM can't express run keys first (Q70 (a)).

Decisions before 6e (Q95–Q108, 2026-10-13): the defaults. `Node` is opt-in, with
`node: true` in a table's `graphql()` options (Q95). `examples/service`'s rewrite
is Phase 7 (Q107).

*6e result (2026-10-13, done):*
- **Schema** (`gen/graphql.v`, Q99–Q105): per table, from its `graphql()` options
  (`vgraph.GraphqlTable`, Q104): `node` adds `implements Node` and the root `node` /
  `nodes`; `relay` makes its root list and every list edge to it a connection
  (`<T>Connection`, `<T>Edge`, `PageInfo`, `Cursor`; no `<root>Count`); `mutations`
  (all three by default, none for views); `type_name`, `query_field` (`-` for
  none), `directives`. `WhereInput` gains `not` / `and` / `or`, `has<Edge>` /
  `has<Edge>With`, `EqualFold` / `ContainsFold` and `In` / `NotIn` on floats and
  times (an OR of equals). `orderBy` is `[<T>Order!]`, with `<EDGE>_COUNT` for list
  edges and `<EDGE>_<FIELD>` for an edge's `order_field`. `Field.comment` and
  `deprecated` become descriptions and `@deprecated` (not on a required input
  field, which graphql-js refuses). Clashing names (a table typed `Node`, two root
  fields) are an error naming the options that rename them; `examples/relations`
  renames `Node` to `ListNode`.
- **Field and edge options** (Q104): `Field.graphql_skip_in []GraphqlSkip` (`.object`,
  `.where`, `.order`, `.create_input`, `.update_input`) beside `graphql_skip`, which
  stays the bool for all; Q104's `.type` is `.object`, `type` being a V keyword.
  `Field.order_field` (`-` for none) and `directives`; `Edge.graphql_skip`,
  `order_field` (validated: a many_to_one or one_to_one edge, a target column) and
  `directives`. `sensitive` no longer sets `graphql_skip`: it leaves the field out of
  the type, filters and orders, and keeps it in the inputs (Q102).
- **Mutations** (Q101, Q102): `create<T>(input)`, `update<T>(id, input)` and
  `delete<T>(id): ID!`, resolved through the builders, so checks, defaults, hooks and
  privacy apply. Inputs as entgql's: create fields required when the create needs
  them, `<edge>IDs` (singular, as entgql's inflection), `<edge>ID`; update fields
  nullable, `clear<Field>` (`clear<Edge>` for a foreign key), `add` / `remove` /
  `clear` per list edge; immutable fields and edges left out. A polymorphic type
  column is checked against its edges' types. The client gains
  `Create<T>Input` / `Update<T>Input` and `set_input` on the create and update_one
  builders (clears, then values, then edges).
- **Transactions** (Q103): `graphql.Transaction` is `begin(ctx) !Context`,
  `commit(ctx)`, `rollback(ctx)`: commit and rollback get the context too, so a
  server shared by concurrent requests keeps no state. `vgraph.GraphqlTransaction`
  returns a `TxContext`; `Client.with_ctx` takes it apart into the transaction's
  connection and the request's own context. The generated server sets it when
  `can_begin()`. Tested on a PostgreSQL pool: a request whose last mutation is
  denied leaves nothing behind.
- **Connections** (Q97): keyset cursors, base64 of a JSON list of the order values,
  the key last; `after` / `before` are conditions (`load.keyset`), with nulls where
  each database orders them (largest on PostgreSQL, smallest on SQLite).
  `first` / `last` read one row more; `totalCount` counts only when selected
  (`FieldInfo.selected`, which now follows named fragments). The key breaks ties in
  the direction of the last order, as entgql's. Two order columns need a driver, so
  a connection ordered by anything but its key needs one (Q97 had said one column
  ran without; the key makes two). An order by an edge reads its cursor values in
  one more select (`load.expr_values`).
- **Per parent** (Q98, `load/each.v`): `select_each`, `link_each`, `count_each`,
  `count_through`. With a driver: `ROW_NUMBER() OVER (PARTITION BY …)` for the keys,
  then the rows by key; counts by `GROUP BY`. Without one: every row, cut in V. The
  client's `with_<edge>` limit and offset now apply per row (`load_<edge>`), and
  GraphQL's nested `limit` / `offset` and connections use them; `page()` is gone.
- **Node** (Q95): the server reads `vgraph_types` once at startup
  (`Client.global_types`), fails naming a `node` table without a range, and `nodes`
  reads each table's ids in one select, with an error at each unknown id.
- **Operations** (Q106): an operation or fragment in a schema file is an error at its
  file and line; files in `operations/` folders are validated against the schema
  and not served. Directives print as Apollo's subgraph schemas print them
  (`graphql.print_schema_with(applied_directives: true)`); graphql-js's
  `printSchema` drops them, so `check_schema.js` compares only schemas without
  custom directives, as both examples' are.
- **Fixed on the way** (6b): `not(has_<edge>())` on a many_to_one edge left out
  rows whose column is null (`NOT (NULL IN (…))`): the predicate is now
  `column IS NOT NULL AND column IN (…)`. Without a driver, a subquery's conditions
  now get the outer query's downgrade, so `has_pets_with(…has_prefix…)` runs.
- **`examples/service`** (Q107): its four models give `mutations: []`, since
  `api.graphql` declares its own; a clash is reported at the project file's line with
  that hint. Its `SqliteTransaction` follows the new interface. The introspection
  snapshot is regenerated: graphql-js 16.11.0 (npm) for the schema's types, with the
  16.x branch's introspection types taken from the old snapshot, a merge that
  reproduces the old snapshot exactly from the old schema. Its tests and query
  counts are otherwise unchanged.
- **Tests:** `examples/relations` (gadgets are `node` and `relay`): `check_relay`
  (node / nodes, paging both ways by key, level, a nullable rating with a second
  column, and likers' count; the selects; `totalCount`; argument errors),
  `check_nested_connections` (per-parent connections and lists, with the selects,
  with and without a driver, and `with_<edge>` limits), `check_where_input`,
  `check_mutations` (every edge kind, hooks, soft delete, privacy, a rolled-back
  request), on SQLite and PostgreSQL, plus `test_graphql_transaction_on_a_pool`. The
  generator test's project: a renamed type and root field, a field out of one input,
  directives, a description, a deprecation, create-only mutations, the polymorphic
  type check, `set_input`, and the `operations` checks. `load_test.v`: keysets,
  cursors, the no-driver per-parent paths. `execute_test.v`: connections, `selected`
  through fragments, printed directives, the transaction's context.
  `schema_test.v` / `write_test.v`: the new validation and `GraphqlTransaction`. All
  22 test files pass, both PostgreSQL tests against PostgreSQL 18, and graphql-js
  16.11.0 reads both generated schemas unchanged. CI's vet now includes `gql.v`.

*6d result (2026-10-13, done):*
- **Reflection** (`load/fields.v`, `schema.v`): every type of V's ORM but bytes, type
  aliases (through `unaliased_typ`), enums (their values listed with `$for v in
  field.typ.values`) and embedded structs (a nested `$for sub in field.typ.fields`:
  calling a generic function on `field.typ` still fails,
  `regressions/comptime_generic_call.vv`). The long type chains are generated text.
  `Column` gained `type_name`, `enum_values`, `embedded` and `json_type`; `Table`
  gained `indexes`, `view` and counts of hooks, interceptors and rules. `?i64`,
  `?f64`, `?bool` and the rest now read.
- **Bytes: left out** (Q82). V's ORM can bind `[]u8` but can't create the column on
  SQLite or read it back on either database (`TODO.md`).
- **`db.pg` decodes `u32` and `u64` wrongly** (0, or a wrong number): vgraph reads
  them as `i64` (`TODO.md`).
- **Mixins** (Q89): the ORM names an embedded struct's columns `<Struct>.<field>`
  (`Stamps.created_at`), so vgraph does too, and works with tables the ORM creates and
  the app's own `sql { }` blocks. `v.migrations` refuses such names, so
  `vgraph.create_table` writes the table's SQL itself.
- **JSON** (Q83): `Field.json`; `node.<field>_value()`, `set_<field>_value()`,
  `append_<field>()` (read, joined and written in the update's transaction, the row
  locked on PostgreSQL); a `JSON` scalar in GraphQL.
- **Edges** (Q86–Q88): `ref` checked against its inverse; `bidi` many_to_one keeps
  pairs consistent (whoever pointed at either side stops), `bidi` many_to_many writes
  and deletes both join rows; `required` on create, `immutable` refused on update and
  absent from the update builders. Edge schemas are recognized when `through` names a
  registered struct, rather than through a `through_struct` option (Q88): the join
  rows then go through that struct's create, with its defaults and hooks.
- **Indexes and views** (Q90, Q91): `indexes()`; `Schema.partial_indexes()`, created
  by `add_edge_indexes` with SQL; views have no write builders, no indexes and no
  foreign keys, and a write to one is refused.
- **Global ids** (Q85): `vgraph.create_table`, `vgraph.global_ids` and
  `Client.table_of`, with `Schema.migration_table`. Ranges count from index 1, not
  0, so a global id is always past 2^32. Without a driver, a new `i64` key can't be
  read back (`last_id()` is 32 bits on SQLite), and such a create is refused.
- **Unique many_to_one edges** (2026-10-13, after review): `examples/relations`
  declared `spouse` as a `bidi` many_to_one with nothing to make it one-to-one: only
  vgraph's own writes kept pairs, and any other write could give two users one
  spouse. `Edge.unique` now marks a many_to_one edge as the key side of a one-to-one
  relationship, as Ent's `Unique()`: its column gets a unique index
  (`users_spouse_id_idx`), a `bidi` many_to_one must be `unique`, and a `bidi` write
  clears the old partner before setting the new one, so the index holds throughout.
  `card` and `next` were one-to-one already, through their inverse one_to_one edges'
  indexes. Two checks also stopped relying on the unordered order of a many_to_many
  load, which PostgreSQL changed.
- **Generator:** predicates, setters, typed getters, orders and aggregates for the
  new types (aliases and enums typed); GraphQL `Int` / `Float` for the sized types,
  an enum type per enum field (`GadgetColor`); predicate functions that two tables
  would both produce (`pet_owner_id_eq` for `pets.owner_id` and `pet_owners.id`) are
  an error. `vgraph describe` (`gen/describe.v`) and `vgraph gen --no-graphql`.
- **Tests:** `schema_test.v` (types, mixins, the new validation, views, global ids
  across two migrations); `pg_test.v` (global ids on PostgreSQL);
  `examples/relations` `check_schema` on both databases (every new type, JSON and
  `append`, a mixin, the unique and partial indexes, required and immutable edges, an
  edge schema, global ids, a view in queries and GraphQL) and `bidi` / `ref` in its
  self edges, replacing the hand-written both-ways writes; `cmd/vgraph/gen_test.v`
  (`describe` on `examples/relations`, `--no-graphql`). All 22 test files pass, both
  PostgreSQL tests against PostgreSQL 18, and graphql-js 16.11.0 reads the generated
  schemas unchanged.

*6b result (2026-10-13, done):*
- **Conditions** (`load/cond.v`, Q71): `load.Cond` is a tree (`Junction`: leaf, and,
  or, not, true, false, sub, raw), with `and`, `or`, `not`, `contains`,
  `has_prefix`, `has_suffix`, `equal_fold`, `contains_fold`, `raw`, `in_sub`.
  `normalize` pushes NOT down to the operators (LIKE, folds, subqueries and raw SQL
  keep a NOT) and folds constants, so an empty `IN` inside an OR no longer empties
  the whole query, as 6a's flat list did. The ORM gets AND, OR and parentheses
  (`orm_where`); a driver gets SQL (`render`).
- **The plan** (`load/plan.v`, Q70 (a)): a query the ORM can run is one query, as
  before; otherwise, with a driver, the keys first (`SELECT "t0"."key" … ORDER BY …
  LIMIT … FOR UPDATE`), then the rows by key through the ORM, in the keys' order;
  without one, subqueries run first (`resolve`), an escape the value doesn't need
  is dropped, a fold becomes ILIKE on `db.pg` (found by type name, so not through
  `vgraph.trace`), and the rest is refused naming the drivers. `select_where`,
  `select_in` (edge loads), `count_where`, `aggregate_where`, `select_keys_where`,
  `select_into` (scan) and `group_where` all use it. `Query` gained `orders`,
  `lock`, `distinct` and `columns`; `load.Order` / `asc` / `desc` / `nulls_first` /
  `nulls_last`, `Lock`, `Aggregate` (`count`, `sum`, `mean`, `min_of`, `max_of`; in
  `vgraph` too), `Group`, `scan_groups`. Parameters stay text; on SQLite a number is
  written `CAST(? AS INTEGER)` (or `REAL`), as SQLite converts text to a number only
  next to a column of that type, which raw SQL broke.
- **Subqueries and privacy** (Q73): `prepare_query` prepares each subquery of a
  registered table as a query of it, so its privacy rules and interceptors apply,
  and a soft-deleted pet doesn't count for `has_pets`. Edge predicates are
  `column IN (SELECT …)` subqueries rather than `EXISTS`: the same rows, and the
  same SQL for the no-driver fallback; each adds `IS NOT NULL` so a `NOT IN` is
  right with nullable columns. Locks need a transaction (`prepare_query`) and
  PostgreSQL (Q78: refused on SQLite).
- **Generator** (`gen/query.v`): per field and operator a method and a function
  (`graph.user_name_eq`); `has_<edge>` and `has_<edge>_with` (a function taking
  conditions, as Ent's, and a method taking a configured query) on queries, updates
  and deletes; `query_<edge>` on queries; `only`, `ids`, `first_id`, `only_id`,
  `exist`, `select`, `unique`, `scan[T]`; `sum_` / `min_` / `max_` / `mean_<field>`;
  `<T>GroupBy` with `aggregate`, `all`, `scan[T]`; `order_by`,
  `order_by_<edge>_count[_desc]` on list edges, `order_by_<edge>_<field>[_desc]` on
  unique ones (but a many_to_one edge's key, which is its own column, and names a
  field order takes); `order_by_<field>` now adds a column (Q77); `for_update`,
  `for_share`, `no_wait`, `skip_locked`; `with_named_<edge>` and
  `node.named_<edge>` on list edges; `node.loaded` and `<edge>_or_err`. Edge loads
  are one private `load_<edge>` method each, which `with_` and named loads share.
  `graph.v` gained `NotSingularError`, `NotLoadedError` and `with_conds`.
- **GraphQL** (Q80): `Contains` / `HasPrefix` / `HasSuffix` are escaped.
- **Tests:** `load/cond_test.v` (negation, constants, the ORM's parentheses, SQL for
  each dialect, the no-driver fallback). `examples/relations` `check_queries`, on
  both its clients (without a driver, with the selects each runs, and with one) and
  both databases: `has_<edge>`, `has_<edge>_with` and traversal from a query for
  every relationship kind and UUID keys; or / not; every string predicate; the
  refusals without a driver; every result method; aggregates; `group_by` with
  `scan`; orders by several columns, by edge count and edge field, nulls last;
  locks (on PostgreSQL; refused on SQLite and outside a transaction); named edges
  and `<edge>_or_err`. All 21 test files pass, and both PostgreSQL tests against
  PostgreSQL 18; `examples/service`'s query counts are unchanged.
- **Found on the way:** inside module `load`, `or(...)` can't be called by name (it
  parses as the keyword); `load.or(...)` from other modules works. The test uses a
  local `either`.

*6c result (2026-10-13, done):*
- **Hooks** (`hooks.v`, Q61–Q63): `vgraph.Hook` (`name`, `on`, `cond`, `run`),
  `vgraph.on` / `only_if` / `unless`; `Client.use` / `use_on`, and a model's
  `hooks()`, reflected by `Schema.add`. A write now runs as: defaults, then the hooks
  outermost first (privacy, graph, table, model), then innermost the checks and the
  SQL, all in the write's transaction. `Mutation` gained `key`, `keys`, `old_field`,
  `add_ids`, `remove_ids`, `clear_edge`, `where`, `set_op`, `on_commit`, `on_rollback`.
  `old_field` returns `!orm.Primitive` (`orm.Null{}` for null): V has no `!?T`, so the
  typed `old_<field>()` exists for non-null fields only. A bulk create runs its hooks
  per row; with no hooks it keeps 6a's single statement on PostgreSQL. The required
  check moved after the hooks, so a hook can supply a required value. `MutationData.key`
  is now `row_key`: `key()` is the method.
- **Typed runtime hooks** (Q62): per table, `<T>Mutate`, `<T>Hook`, and on `<T>Query`
  `use` (typed), `use_hook` (a `vgraph.Hook`), `intercept` (typed: a `<T>Query` in,
  narrowed out) and `policy`. `<T>Mutation` wraps the `vgraph.Mutation` (`inner`),
  with typed getters, setters, `clear_<field>` and `old_<field>`. `Graph` gained
  `use`, `intercept`, `policy`, `skip`, `privileged`, `on_commit`, `on_rollback`. The
  registry is shared by every copy of a client.
- **Transaction hooks** (Q64): `TxState` on the client that owns a transaction;
  `commit` and `rollback` run the callbacks after the transaction ends. A write with no
  transaction available runs them when it succeeds or fails.
- **Interceptors** (Q65): `Interceptor{name, run}`, run by `Client.prepare_query`,
  which every generated select now goes through: `all`, `count`, edge loads,
  traversals, and so the GraphQL resolvers; `load_one` / `load_many` too.
  `soft_delete_query` and `soft_delete_hook` (named `soft_delete`); `skip(...)`. A
  write's read-back uses `bypass()`, so no rule or interceptor hides the row it wrote.
  `load.Query`'s fields are now `pub mut`, for interceptors.
- **Privacy** (Q66): `Policy{query, mutation}`, `Decision`, `always_allow` /
  `always_deny` (and the `_query` forms), `PrivacyError`, `policy()` on a model,
  `policy` / `policy_on` on the client, `privileged()`. Mutation rules run as the
  outermost hook; query rules before the interceptors.
- **Tracing** (`trace.v`, Q67): `vgraph.trace(conn, f)` returns a `Traced`,
  `TracedTx` or `TracedDriver`, so a driver and a transactional connection stay what
  they are. `TraceEvent{kind, table, statement, duration, failed}`: no parameters, no
  error text, and no SQL for raw `execute` calls, which may hold values.
- **GraphQL** (Q68): a denied query or a hook's error is an error at its field;
  tested through the generated server.
- **Tests:** `hooks_test.v` (order, `on` / `only_if` / `unless`, skipping, a hook's
  error rolling back, `keys`, `old_field`, hook edge changes and conditions,
  transaction hooks inside and outside `begin`, interceptors, soft delete with `skip`,
  every privacy decision, `privileged`, tracing without values) on SQLite with and
  without the driver. The generator test's project has a model hook and policy, typed
  hooks with `old_title()`, a typed interceptor on edge loads, and privacy through
  GraphQL. `examples/relations`: pets are soft-deleted (hidden in queries, edges,
  counts and GraphQL; `skip` purges), groups have a policy (only an `Admin` context
  deletes one), and its counting connection is now `vgraph.trace`, with the same
  query counts. All 20 test files pass, and both PostgreSQL tests against PostgreSQL
  18. `examples/service`'s code is unchanged (Q58).
- **Compiler bug, again:** the shadowing bug of 6a also hit a closure named `fail` in
  `field.v`, compiled as `app.fail` of `examples/service`, a module vgraph never
  imports; the regression's notes say so.

*6a result (2026-10-13, done):*
- **Drivers** (Q51): `vgraph.Driver` (`orm.Connection`, `dialect()`,
  `exec_params(query, params)`, `begin_tx()`) and `TxConnection`. Adapters:
  `five07.vgraph.sqlite` (`sqlite.new(db)`), and `five07.vgraph.pg` for a pool
  (`pg.pool(db)`: a transaction pins one connection through `pg.DB.begin`), a direct
  connection (`pg.direct(conn)`) and a transaction. Parameters go as text, stored as
  the ORM stores them (SQLite: booleans 0/1, times as Unix seconds); nulls are written
  into the SQL, since the drivers' raw calls take strings only. PostgreSQL
  transactions run at READ COMMITTED. `Client` finds the driver with `conn is Driver`.
- **Field options** (Q39, Q55): `vgraph.Field` and `fields()`, reflected by
  `Schema.add` and checked by `validate` (a missing field, an option the type can't
  have, an immutable field with an update default). `Column` gained `serial`,
  `optional`, `immutable`, `sensitive`, `unique`, `comment`, `deprecated`,
  `has_default`, `auto_update`. The closures stay out of `Table`, in `Schema.options`:
  `json2` can't encode a struct with function fields, even with `@[json: '-']`, and
  `vgraph gen` prints the tables as JSON. `sensitive` and `graphql_skip` hide a field
  from GraphQL, as `@[graphql: '-']` does.
- **Writes:** `MutationData` (values, increments, edge keys added, removed and
  cleared, conditions, upsert) implements `vgraph.Mutation`; `Client.create`,
  `create_bulk`, `update_one`, `update`, `delete_one`, `delete` run it. A create
  applies defaults, reports required columns, runs the checks, inserts, then writes
  edges; an update reads the matching keys, updates by key, then writes edges; a
  delete removes the rows' join-table rows first. All in one transaction where the
  connection has one. Counts come from the keys read in that transaction, which
  works with or without a driver (Q56 said `RETURNING`; the result is the same).
  Without a driver a new key comes from `last_id()`, and upserts are refused.
- **Bulk inserts:** one statement with `RETURNING` on PostgreSQL; one per row on
  SQLite, whose `RETURNING` doesn't promise the rows' order, and for `do_nothing`.
- **Generator:** `<table>_mutation.v` per table: `<T>Mutation` with typed getters;
  `<T>Create` / `<T>CreateBulk` (with `map_create_bulk[T]`), `<T>UpdateOne`,
  `<T>Update`, `<T>DeleteOne`, `<T>Delete`, as in README.md. Immutable fields have no
  update setter; foreign keys have no `add_`; a polymorphic `set_<edge>_id` sets the
  type column too; a one_to_one `set_<edge>_id` on an update first unlinks the row's
  current target, when the target's column is nullable; when it isn't, the unique
  index refuses a second target. Two setters of one name are an error.
  `graph.v` gained `with_ctx`, `ctx` and `tx`.
- **Context** (Q53): `with_ctx` takes a `graphql.Context`, not a `vgraph.Context`. V
  can't convert one interface to another, or smartcast through an interface alias,
  so vgraph and its GraphQL module share one type, and the generated resolvers pass
  the request's context to the queries they run.
- **Migration helpers** (Q36): a field with `unique` gets a unique index.
- **Tests:** `write_test.v`: every operation, check and default, edges of every
  kind, rollback of a failed edge write, transactions, bulk, upsert, on SQLite with and
  without the driver. `examples/relations` `check_writes`: each relationship kind
  written through the generated builders, UUID keys, an upsert on the key, bulk
  creates, updates and deletes of many rows, a rolled-back `g.tx`, on SQLite and
  PostgreSQL. `pg_test.v`: the pool driver, a multi-row insert's keys in order, and a
  transaction's writes unseen by the pool's other connections until it ends.
  `cmd/vgraph/gen_test.v`: polymorphic writes on a connection without a driver or
  transactions. All 19 test files pass, and both PostgreSQL tests against PostgreSQL
  18. `examples/service`'s code is unchanged (Q58); only its generated client is
  regenerated, and its tests and GraphQL schema are unchanged.
- **Compiler bug found:** an eighth, `regressions/fn_var_shadows_module_fn/`: a local
  variable holding a function, named like a function of an imported module
  (`validate`, which `graphql` declares), is called as that function, and the C
  doesn't compile.
- **Moved on:** old values in `Mutation` to 6c, with the hooks that read them; edge
  `required` / `immutable` to 6d; `Append` to 6d, with JSON fields; field `comment` and
  `deprecated` as GraphQL descriptions to 6e. A `graphql.Transaction` built on `g.tx`
  waits for 6e's generated mutations: the generated resolvers use the graph they were
  built with, so on a pool a request's transaction needs a per-request graph.

## 7. Questions

**Q1.** Repository and name: a GitHub repo `vgraph` under which account? The VPM name
becomes `<account>.vgraph`, and it can't be changed after submission.
> A: `five07` - this is the repo I will use.

**Q2.** V version: pin to 0.5.2 (stable to build against, but slower to get fixes),
or follow V master (fixes arrive sooner, along with API churn)? **Default:** pin, and
bump on purpose.
> A: yes, pin to 0.5.2 for now
>
> *Superseded by Q13: follow local master, and pin a `0.5.x` release before publishing.*

**Q3.** Databases: SQLite only for v1, or Postgres too (the `rest-api` stretch
goal)? **Default:** SQLite first, with Postgres in CI from Phase 2.
> A: SQLite first, with Postgres in CI from Phase 2.

**Q4.** How entities declare edges. **Default:** (a), plain and checkable.
- (a) a method, `fn (Article) edges() []vgraph.Edge`, like Ent's `Edges()`;
- (b) struct attributes, `@[edge: 'comments; to: Comment; fk: owner_id']`, which
  are compact but are stringly typed and only checked at runtime;
- (c) a separate schema file that `vgraph gen` reads.
> A: hmm, start with (a) and later let's test an example of (a) and (c) and then we'll decide. Works with Q5

**Q5.** Code generation in v1, or reflection-only loading first (Phases 0–2) with
the generator later? **Default:** reflection first; it shows sooner whether V's
generics hold up.
> A: default choice

**Q6.** Identifiers: assume an `int` primary key named `id` (Ent's default), with
slugs left to the app as in `rest-api`? **Default:** yes, with the key column
configurable per entity.
> A: default choice

**Q7.** Soft delete as a built-in edge option (`soft_del: 'deleted_at'`), since
`rest-api` filters it everywhere? **Default:** yes, opt-in per edge.
> A: default choice

**Q8.** Polymorphic edges in v1? They're the hardest kind and the one `rest-api`
needs most. **Default:** yes. Without them Phase 1 can't replace the `Owner` registry.
> A: default choice

**Q9.** GraphQL: build an executor in vgraph, adapt `luizfonseca.graphql` (parser
only, inactive for about 3 years), or keep GraphQL a separate project? **Default:**
separate; vgraph only provides the batching.
> A: default choice, we can pivot later if need be, but keeping this package lean is optimal. A separate five07.graphql package could be a good idea

**Q10.** Migrations (your Atlas TODO): inside vgraph, or a separate package (for
example `vmigrate`) that reads vgraph's schema? **Default:** separate.
> A: V ORM now has a migration tool and we should utilize it instead of an Atlas clone. (https://vlang.veery.blog/post/25/introducing-orm-migrations-in-v)

**Q11.** Upstream V bugs (`@[index]` on SQLite, `exec` swallowing errors, the
`update` name, `last_insert_rowid`): report or fix them in `vlang/v` as part of this
project, or only work around them? **Default:** report each one with the small
reproduction programs already written, and work around them in the meantime.
> A: like the changes I PR'd for veb/HMR, we'll potentially report issues with a PR ready.

**Q12.** License: MIT, matching `rest-api`? **Default:** MIT.
> A: MIT

### New questions from your answers

**Q13. Q2 and Q10 conflict.** `v.migrations` isn't in the `0.5.2` tag: it landed on
master on 2026-10-10. Your compiler, master `53dd72c`, has it and passes its tests, but
still reports `V 0.5.2`. **Default:** pin to master commit `53dd72c` instead of the tag.
Record it in the README and CI (`git checkout 53dd72c && make`), and bump it on purpose.
The other choice is to stay on the `0.5.2` tag and move Phase 5 until a release
includes `v.migrations`.
> A: let's use whatever master I have checked out for V. By the time we finish building, we will decide to pin on `0.5.X`

**Q14. Where `example/` lives, and what is copied.** **Default:** `vgraph/example/`, with
its own `v.mod` (`name: 'example'`), copied from `rest-api`'s last commit (`9d802d6`)
with `git archive`, which leaves out `.git`. That also leaves out `rest-api`'s
uncommitted `TODO.md` edit, its untracked `VGRAPH.md` (an older copy of this plan),
`PLAN.md` and any `.db` file. The name changes from `rest-api` to `example` in
`v.mod`, `.env.example` (`DB_PATH=example.db`) and the README.
> A: default choice

**Q15. How `example` imports vgraph during Phases 0–1.** A `v.mod` in `example/` makes
`example/` the import root, so it can't see `../load`. **Default:** keep the loader
inside `example/vgraph/load/` until Phase 2. Phase 2 then moves it to the package root
and symlinks `~/.vmodules/five07/vgraph` to this repo, so `example` already imports
`five07.vgraph` before anything is published. Or symlink from day one, which means
renaming nothing later but needs that symlink on every machine and in CI.
> A: default choice

**Q16. How queries are counted for the Phase 1 exit check.** `rest-api` has no SQL
tracing. **Default:** a small `CountingConnection` that wraps `orm.Connection` and
records each statement, used only in tests. Each endpoint test then asserts its query
count, so an N+1 regression fails the test instead of being caught by eye. It can later
become part of vgraph (`vgraph.trace`).
> A: sounds good

**Q17. Query layer: `orm.new_query`, or vgraph's own on `orm.Connection.select`?** Phase 0
found that the function API is deprecated. It leaves vlib after 2027-08-17 for a
separate repository that doesn't exist yet. **Default:** build on `Connection.select`.
vgraph already reflects over every field, the driver interface stays in vlib, and
Postgres/MySQL come with it. The cost is mapping each field type ourselves: options,
`time.Time`, enums, `sql_type` overrides. The spike maps int, i64, f64, bool and string
in about 60 lines (`spike/load/select.v`). The other choice is `new_query` for now,
switching when its new home is known.
> A: default choice

**Q18. Schema source for `vgraph gen`: (a) `edges()` methods or (c) `schema.toml`?** See
the comparison under Phase 3. **Recommendation:** (a). The generator needs the fields
either way, and (a) gets them from the real structs instead of a second copy.
> A: (a) `edges()` methods. *(`schema.toml` and its sync test were then removed.)*

### Phase 4 scope (GraphQL)

Background: vgraph's generated client already loads one query per edge per level,
which is how a GraphQL executor should resolve nested fields. What doesn't exist
yet: a GraphQL schema, a parser, an executor, and an HTTP endpoint.

**Q19. Operations: queries only, or mutations too?** vgraph only reads today.
Mutations need a write API first: create, update and delete, plus writing edges,
including both directions of a bidirectional edge. **Default:** queries only for
Phase 4, with the write API and mutations as a later phase.
> A: The goal of this project is 1:1 feature parity with Ent. mutations are part of that scope. we also need a GraphQL schema, a parser, an executor, and an HTTP endpoint

**Q20. Parser and executor: our own, or `luizfonseca.graphql`?** That package is a
parser only, unfinished, and untouched for about 3 years. **Default:** our own: a
lexer and parser for the executable subset of the spec (queries, fields, arguments,
aliases, variables, fragments and inline fragments, `@include` / `@skip`), and an
executor that resolves each level of a query with the generated `with_<edge>` loads.
> A: Build our own. it's a hard requirement. But build it into a way that we could extract it into a new package (`five07/graphql`).

**Q21. Schema: generated, or written by hand?** **Default:** generated by `vgraph gen`
(a flag such as `--graphql`, or always), like Ent's `entgql`. Each table becomes an
object type with its scalar fields and its edges as fields, plus root query fields
for each table. The output is both the SDL (`schema.graphql`) and the V resolvers.
Field names stay snake_case (`created_at`), or are converted to camelCase
(`createdAt`) as GraphQL tooling expects.
> A: (and snake_case or camelCase?) generated and camelCase field names

**Q22. Arguments, pagination and counts.** **Default:** list fields take `where`
(one input type per table, built from the same predicates as the generated
queries: `eq`, `lt`/`gt`, `in`, `like`, `is_null`), `order_by` and `limit` /
`offset`, and each table gets a `count`. Relay-style cursor connections
(`edges { node }`, `pageInfo`, as `entgql` does) come later, if needed. The
generated V queries gain `count()` and `offset()` for this.
> A:default choice

**Q23. Introspection.** Tools such as GraphiQL, Apollo and code generators need
`__schema` / `__type`. **Default:** yes: it's mostly static data generated with the
schema, and without it the endpoint is hard to use from standard tools.
> A: yes, and let's try to keep to the Apollo standard

**Q24. Transport and where it lives.** **Default:** a `graphql` module in this repo
(moved to `five07.graphql` later, if needed), with an HTTP handler that any web
framework can call (request body in, JSON out), and a `POST /graphql` route in
`examples/service` built on veb. No subscriptions.
> A: agreed on all points

**Q25. Delete `spike/`?** The `load/` module replaced it, and its tests still run in
every `v test .`. **Default:** delete it; git history keeps it.
> A: yes

### Phase 4: new questions from your answers (2026-10-13)

**Q26. What "1:1 parity with Ent" covers, and what lands in Phase 4.** Q19 made Ent
parity the goal, and vgraph has no write API. Should Phase 4 build the missing Ent
features too? *(The feature table that was here is now the Phase 6 inventory.)*
> A: i didn't mean to infer that the missing Ent functionality must be done in phase 4, in fact, that should be pushed to a new phase. This phase should simply focus on the GraphQL layer and its implementation. Plan for all Ent features AND create a new Phase to address the missing vgraph functionality.
>
> *Done: Phase 4 is GraphQL only, Phase 6 is Ent parity with the full inventory, and
> §3 and the layers table say so. Q27 onward were reframed around it; Q27–Q41 replace
> the earlier Q27–Q37, none of which had answers.*

#### Phase 4 (GraphQL)

**Q27. Mutations before the write API.** Q19 puts mutations in scope, but generating
them (`createArticle`, `updateArticle`) needs Phase 6's write API. **Default:** Phase 4
builds everything a mutation needs except the generated ones: the `Mutation` root type,
serial execution as the spec requires, input object types and variables, and a way for
the app to declare mutations and write their resolvers (Q33). `examples/service`
declares one mutation per REST write endpoint, with resolvers calling its existing
stores, so the validation, slugs and soft deletes it already has stay in one place.
Phase 6e then generates mutations for every table.
> A: agreed

**Q28. GraphQL types and names.** **Default:**
- type names come from the struct (`Article`); the root list field from the table
  (`articles`), plus a single-row field `article(id: ID!)`;
- primary keys are `ID!` (strings on the wire, as the spec and Relay expect);
- `time.Time` is a custom `Time` scalar (RFC 3339), as in entgql;
- every type implements `Node`, with root `node(id: ID!)` and `nodes(ids: [ID!]!)`.
  Ids are only unique per table, so a global id names its type;
- polymorphic edges stay separate fields (`Comment.article`, `Comment.post`). A union
  (`owner: Owner`, `union Owner = Article | Post`) can come in 6e;
- one_to_one and many_to_one edges are nullable object fields, the others `[T!]!`.

Two choices to confirm: are **global ids** base64-encoded, as Relay recommends
(`QXJ0aWNsZToz`), or plain (`Article:3`)? And are **foreign key columns** fields
(`Comment.userId`), or only their edges (`Comment.author`)? entgql leaves them out
unless the edge is bound to the field.
> A: stick with entql standard

**Q29. Hiding tables and fields from GraphQL.** Phase 6's field options include
`Sensitive` and entgql's `Skip`, but Phase 4 already needs a way to keep a field
(a password hash) or a whole table (a join table with a struct) out of the schema.
**Default:** a `@[graphql: '-']` attribute on a field or struct, like `@[json: '-']`.
Phase 6 folds it into the field options (Q39) and keeps the attribute working.
> A: Yes, that is a good annotation choice

**Q30. "The Apollo standard" (Q23).** Which of these did you mean? **Default:** (a) and
(b) in Phase 4, (c) and (d) in Phase 6e or later.
- (a) spec introspection that Apollo Sandbox, Apollo Client codegen and GraphiQL read,
  with descriptions (from the doc comments) and `@deprecated`, plus a `GET /graphql`
  page that opens Sandbox or GraphiQL;
- (b) [GraphQL over HTTP](https://graphql.github.io/graphql-over-http/) responses with
  Apollo Server's error codes in `extensions.code` (`GRAPHQL_PARSE_FAILED`,
  `GRAPHQL_VALIDATION_FAILED`, `BAD_USER_INPUT`, `INTERNAL_SERVER_ERROR`);
- (c) automatic persisted queries (APQ, `extensions.persistedQuery.sha256Hash`);
- (d) Apollo Federation v2 subgraph support (`_service { sdl }`, `_entities`, `@key`),
  so vgraph can sit behind an Apollo Router.
> A: sorry, all of that would be future state. I meant the Apollo standard for generating and parsing schemas.

**Q31. Validation and limits.** The spec has about 30 validation rules (unknown
fields, argument types, fragment cycles, variable usage, and so on). **Default:** all
of them, tested against cases ported from graphql-js's test suite, plus a configurable
maximum query depth and number of selections, since nested queries fan out.
> A: agreed

**Q32. How the executor batches.** entgql reads the whole selection set first
(`CollectFields`) and builds one Ent query with every nested `With<Edge>`. The other
route is level by level: the executor hands each field every parent at once, as a
dataloader does. **Default:** level by level. The `graphql` module's resolvers take a
list of parents, so any backend can batch, and the module never imports vgraph. The
generated resolvers run one `load_one` / `load_many` per edge per level, with that
field's `where` and `orderBy` applied, and aliases of the same edge with different
arguments load separately. `examples/service`'s query-count assertions then cover
GraphQL too. 

Nested `limit` / `offset` (`articles { comments(limit: 3) }`) is per parent, which one
`IN (…)` query can't do without window functions. **Default:** Phase 4 loads the
edge's rows in one query and cuts each parent's list in V: correct, batched, but it
reads every row of the edge. Phase 6e moves it into SQL
(`ROW_NUMBER() OVER (PARTITION BY …)`) where the database supports it.
> A: agree with default

**Q33. Hand-written fields and operations.** Apps need fields the schema doesn't
generate (`Article.url`, a root `me`) and, until 6e, all their mutations (Q27).
**Default:** `vgraph gen` also reads any `*.graphql` files in the project
(`extend type Article { url: String! }`, `extend type Mutation { … }`), merges them
into the schema, and writes resolver stubs for the app to fill in, in a file it never
overwrites, as gqlgen does.
> A: yes, agree

**Q34. Transactions for mutations.** The spec runs a request's mutation fields in
order. vgraph has no transactions until 6a, but `orm.TransactionalConnection` does
(SQLite and PostgreSQL implement it). **Default:** the HTTP handler takes an optional
transaction wrapper; when it's set, all of a request's mutation fields run in one
transaction and any error rolls the request back, as entgql's `Transactioner` does.
`examples/service` sets it. The other choice is one transaction per mutation field,
with partial success reported in `errors`.
> A: yes agree

**Q35. Exit criteria for Phase 4.** **Default:**
- `examples/service` serves `POST /graphql` (and `GET` for Sandbox) beside its REST
  routes, with a query or mutation for every REST endpoint, and its tests assert that
  each GraphQL query runs the same selects as the matching REST endpoint;
- `examples/relations` has a GraphQL test for each relationship kind;
- the parser and validator pass the cases ported from graphql-js;
- the standard introspection query's result matches a checked-in copy, and Apollo
  Sandbox and GraphiQL load the schema (checked by hand once);
- everything passes on SQLite and PostgreSQL in CI, and CI checks that the generated
  schema and resolvers are up to date.
> A: perfect

#### Phase order and scope

**Q36. Phase 5 before Phase 6?** Phase 5 (migration helpers from edges) is small and
doesn't depend on Phase 6. Phase 6 adds schema options (unique fields, defaults,
declared indexes, edge schemas) that migrations then need to cover. **Default:** keep
the order; Phase 5 covers edges, and each Phase 6 sub-phase extends the helpers for
what it adds. The other choice is Phase 6 first, so the migration helpers are written
once against the full schema.
> A: yes that is fine

**Q37. Ent features outside the core.** The inventory covers Ent and entgql. Ent also
has a Gremlin driver (graph databases) and extensions: entproto (protobuf / gRPC),
entoas and ogent (OpenAPI), entviz (schema diagrams). **Default:** out of scope for
v1, listed in §3 as non-goals; `vgraph describe` (a text dump of the schema, like
`ent describe`) is in 6d.
> A: out of scope, but add to a list for future state, especially entproto.

#### Phase 6 (Ent parity): answer before Phase 6 starts

**Q38. The write API's shape.** Generated per table, like Ent's builders:

```v ignore
art := g.articles().create()
	.set_title('V')
	.set_author_id(user.id)  // or .set_author(user_node)
	.add_tag_ids(1, 2)       // writes join rows
	.save()!                 // ArticleNode
g.articles().update_one(art).set_title('W').clear_published_at().remove_tag_ids(2).save()!
g.articles().update().where_user_id(3).set_summary('').exec()! // rows changed
g.articles().delete_one(art.article.id).exec()!
g.articles().delete().where_deleted_at_is_not_null().exec()!
```

Writes go through `orm.Connection.insert` / `update` / `delete`. Reading back a new id
is the risk from §5: `last_id()` races when threads share a connection. **Default:**
this shape; a create runs its insert, `last_id()` and edge writes in one transaction,
uses `RETURNING id` on PostgreSQL, and the docs say a connection isn't to be shared
across threads without a pool.
> A: agreed

**Q39. Field options.** Writes need to know which fields are required on create, have
defaults, can't change, or must stay hidden. Reflection gives only the type and
nullability. **Default:** an optional `fields()` method beside `edges()`, listing only
the fields that need options:

```v ignore
pub fn (a Article) fields() []vgraph.Field {
	return [
		vgraph.Field{name: 'slug', immutable: true},
		vgraph.Field{name: 'created_at', default_now: true, immutable: true},
		vgraph.Field{name: 'updated_at', default_now: true, update_now: true},
		vgraph.Field{name: 'body', validate: fn (v string) ! { ... }},
	]
}
```

Fields not listed are inferred: an option type is optional, `@[sql: serial]` is set by
the database, and every other field is required on create.
> A: sounds good

**Q40. Hooks, and where business logic lives.** `examples/service`'s stores validate,
make slugs, set timestamps and soft-delete. In Ent that logic lives in hooks, so every
write, generated GraphQL mutations included, runs it. **Default:** hooks declared like
edges, `fn (Article) hooks() []vgraph.Hook`, each a function that receives the mutation
and the next step, with `on` (create, update, delete) conditions; runtime hooks
registered on the `Graph`. `examples/service` moves its store logic into hooks and its
GraphQL mutations become generated ones.
> A: yes we want that as hooks

**Q41. Context, for privacy and hooks.** Ent passes a `context.Context` to every call,
which is how privacy rules see the viewer and hooks see the request. vgraph's API has
none. **Default:** `g.with_ctx(ctx)` returns a `Graph` whose queries and writes pass
`ctx` to hooks, interceptors and privacy rules, and the GraphQL handler sets it per
request. Leaving it out keeps the API as it is.
> A: yes, especially with hooks to logic, passing a user defined context is critical

#### Phase 4 follow-up (2026-10-13)

**Q42. `Node` and global ids, given entgql's convention (Q28).** entgql's `node(id: ID!)`
finds a row from its id alone. With integer ids that relies on Ent's globally unique
ids (`sql/globalid`): each table's ids start at its own multiple of 2^32, recorded in
an `ent_types` table, so an id says which table it belongs to. vgraph's tables each
count from 1, so `3` could be an article or a user. **Default:** (a).
- (a) Phase 4 leaves out `Node`, `node` and `nodes`. Clients read one row with
  `articles(where: {id: 3})`. Globally unique ids come in 6d, with the migration
  helpers setting each table's starting id, and `Node` with them.
- (b) Add globally unique ids in Phase 4. Only new tables can start at their range;
  `examples/service`'s existing rows keep their ids, so it needs a data migration.
- (c) `Node` now with type-prefixed ids (`Article:3`, or base64 as Relay suggests),
  which is the Relay convention but not entgql's for integer ids.
> A: my choice is (a)

**Q43. Ids other than `int`, such as UUID strings** (reopens Q6). `load`, `Client`,
`Schema.validate` and the generated client assume `int` keys (`map[int]`, `[]int`,
`int_column`). GraphQL's `ID` is a string on the wire, so the schema doesn't change,
but Phase 4's resolvers would be built on the `int` load API, and generalizing it in
6d would break `load`, the generated client and the resolvers at once.
**Default:** a Phase 3.2 before GraphQL: key by the key's string form inside `load`,
accept `int`, `i64` and `string` keys, check edge column types against target keys,
and keep the generated API typed. Test with a UUID-keyed table in `examples/relations`.
> A: default (2026-10-13)

### Phase 5 (migration helpers): answer before Phase 5 starts

What's there (checked 2026-10-13, V master `53dd72c`): `migrate.v` has `vgraph.Index`,
`Schema.indexes()` and `Client.ensure_indexes()`, used at startup by both examples.
`v.migrations` has `migrations.Index{table, columns, name, unique}`,
`ForeignKey{from_table, column, to_table, primary_key, name, on_delete, on_update}` and
`Table{name, columns, foreign_keys, id, id_name, if_not_exists}`, run through
`Context.add_index` / `add_foreign_key` / `create_table`. Its limits that shape Phase 5:
- `add_index` has no `IF NOT EXISTS`, and names indexes `index_<table>_on_<columns>`
  when no name is given; vgraph's are `<table>_<columns>_idx`;
- on SQLite, `add_foreign_key` returns an error: foreign keys go in `Table.foreign_keys`
  when the table is created, or come from the ORM's `@[references]`, as today;
- `Table` takes one primary key column, so a join table can't have a composite key;
- `migrations.new` needs an `orm.TransactionalConnection`. `sqlite.DB` is one, but
  `examples/service`'s `CountingConnection` isn't; on PostgreSQL it refuses the pool
  that `pg.connect` returns and needs `pg.connect_direct`'s `pg.Conn`.

**Q44. The helpers' API.** **Default:** in the `vgraph` module, from a `Schema`:
- `s.migration_indexes() []migrations.Index`: what `indexes()` returns today, with
  vgraph's names kept, so databases that ran `ensure_indexes` already have them;
- `s.foreign_keys() []migrations.ForeignKey`: one per many_to_one edge and per join
  column; none for polymorphic edges, which point at more than one table;
- `s.join_table(table, edge) !migrations.Table` (Q46);
- `vgraph.add_edge_indexes(mut ctx, s)!` and `remove_edge_indexes(mut ctx, s)!`, for a
  migration's `up` and `down`.

`vgraph.Index` and its `sql()` go, replaced by `migrations.Index`. `vgraph` then imports
`v.migrations`, which no V release has yet (Q13 already accepts that).
> A: accept default

**Q45. Foreign keys on SQLite.** SQLite can't add one to an existing table, and the
examples' tables are created by the ORM, whose `@[references]` already writes them.
**Default:** `foreign_keys()` is for tables created through `ctx.create_table` (put them
in `Table.foreign_keys`) and for `add_foreign_key` on PostgreSQL and MySQL. Models
created with `create_orm_table[T]` keep `@[references]`. `Schema.validate` doesn't
check that a foreign key exists.
> A: accept default

**Q46. Join tables.** vgraph's join tables are structs with their own `id` (`GroupUser`,
`ArticleTag`), and a `Table` can't have a composite key. **Default:** `join_table`
returns a `Table` with an `id`, the two join columns `NOT NULL`, typed from the keys
they hold (`integer`, `bigint`, `text`, or `uuid` on PostgreSQL), and a foreign key to
each side. The pair gets a unique index from `migration_indexes()`, so a pair can't be
stored twice (today nothing stops it). Apps that keep a struct for the join table can
use `create_orm_table[T]` instead and take only the indexes.
> A: accept default

**Q47. `ensure_indexes`.** **Default:** remove it and `vgraph.Index.sql()`: nothing is
published, and both examples move to migrations. Index names stay the same (Q44), so an
existing database only needs its baseline migration recorded, not rerun; the examples'
local `.db` files are simply deleted, as `examples/service`'s README already says to do
after a schema change.
> A: accept default

**Q48. `examples/service` and `examples/relations`.** **Default:**
- `examples/service` gets a `migrations/` module with one migration, `1 initial`:
  `create_orm_table[T]` for its four models in dependency order, then
  `add_edge_indexes`; `down` reverses it. The four `create_tables` functions go.
- `new_app_on` runs `migrate()` on `db` (not on `conn`), so the
  `CountingConnection` counts only what the app runs, and the query-count tests
  don't change.
- `examples/relations` does the same in `checks.v`, on SQLite and PostgreSQL
  (`pg.connect_direct` there).
- The stores' own tests keep their `sql db { create table }` fixtures.
> A: accept default

**Q49. Dialects.** **Default:** the helpers take the dialect from the migration's
`Context`. SQLite and PostgreSQL are tested; MySQL is left untested, as for the rest of
vgraph.
> A: accept default

**Q50. Exit criteria for Phase 5.** **Default:**
- `examples/service` starts from an empty database through `v.migrations` alone;
  `status()` shows `1 initial` applied, and `rollback` then `migrate` again works;
- the indexes it ends up with are the ones `ensure_indexes` made, plus Q46's unique
  pair indexes if that's chosen (compared through `sqlite_master`), and the
  query-count tests are unchanged;
- the helpers have tests for every edge kind, polymorphic and UUID keys included, on
  SQLite and PostgreSQL;
- `ensure_indexes` is gone from the package and both examples, and CI (`v vet`
  included) passes.

A command that writes a migration file (`vgraph migrate new`), or diffs the schema
against the database as Atlas does, stays out (Q10).
> A: accept default

### Phase 6 (Ent parity): answer before 6a starts

Background: the readiness review under Phase 6. Q51–Q57 shape 6a; Q58–Q60 cover the
rest. Each later sub-phase gets its own short round of questions before it starts,
as Phase 5 did.

**Q51. The SQL that `orm.Connection` can't run.** Row counts, `RETURNING`, `NOT`,
`ESCAPE`, subqueries, `GROUP BY`, window functions, locking and upsert all need SQL
the interface can't express, and `execute` takes no parameters. **Default:** (b).
- (a) Stay on `orm.Connection` only. Each gap gets a workaround (a count select
  before an update, two queries for `has<Edge>`, a select by a unique key after an
  insert) or is left out. No new dependencies, but parity stops short: no locking,
  upsert, `GROUP BY` or per-parent pagination in SQL.
- (b) vgraph builds its own parameterized SQL per dialect, and runs it through a
  `vgraph.Driver` interface: `orm.Connection` plus `exec(query, params) ![][]?string`
  and `dialect()`. Small adapters live in their own modules
  (`five07.vgraph.sqlite`, `.pg`, `.mysql`) so an app only links the driver it
  imports. `load` keeps `orm.Connection.select` for what it already does. A plain
  `orm.Connection` still works; the features that need a driver return an error
  naming the adapter to use.
- (c) Like (b), but everything, the existing loads included, moves to vgraph's SQL,
  and `orm.Connection` is only used for its connection.
>  A:  For now, create the workarounds for sqlite and postgres only (a)
>
> *Clarified in chat (2026-10-13): (b), with adapters for SQLite and PostgreSQL only.
> (d), the upstream `orm.RawConnection`, is future state, recorded in `TODO.md`.*

**Q52. Sub-phase order.** **Default:** 6a writes → 6c runtime → 6b queries → 6d
schema → 6e entgql, each with its own exit criteria and a result recorded here. 6a
includes the context (Q41) and transactions, since writes and hooks need both.
>  A: agreed

**Q53. The context's type.** **Default:** `vgraph.Context`, an empty interface like
`graphql.Context`; the app passes its own struct and smartcasts it in hooks and
rules. `g.with_ctx(ctx)` returns a copy of the `Graph`. The generated GraphQL server
passes its request context through, so one value reaches resolvers, hooks and
privacy rules. The other choice, a generic `Graph[C]`, types the context but puts a
type parameter on every generated query, which is where the compiler bugs have been.
>  A: agreed

**Q54. Typed and untyped hooks.** A model's `hooks()` can't import the generated
`graph` module (a cycle), so it can't take the typed `ArticleMutation`.
**Default:** both, as Ent has both:
- schema hooks in `fn (Article) hooks() []vgraph.Hook`, on the untyped
  `vgraph.Mutation` interface: `op()`, `table()`, `field(name) ?orm.Primitive`,
  `set_field(name, value) !`, `clear_field(name)`, `old_field(name) !?orm.Primitive`,
  `added_ids(edge)`, `removed_ids(edge)`;
- runtime hooks registered on the `Graph` in the app, typed:
  `g.articles().use(fn (next ArticleMutator) ArticleMutator { ... })`, where the
  generated `ArticleMutation` has `title() ?string`, `set_title(string)`, and so on.

The other choice moves the schema out of the model structs, as Ent does: `vgraph gen`
writes the row structs too, and schema hooks can be typed. That reverses Q18.
>  A: both, as Ent has both

**Q55. Field options' shape** (refines Q39). One `[]vgraph.Field` list can't hold a
`fn (string) !` for one field and a `fn (int) !` for another. **Default:**
```v ignore
vgraph.Field{
	name: 'title'
	// built-in checks, stored as data, also used for the GraphQL schema's docs
	not_empty: true
	max_len:   200
	// anything else; the value as the ORM sees it
	validate:  fn (v orm.Primitive) ! { ... }
}
vgraph.Field{name: 'slug', immutable: true, default: fn () orm.Primitive { return app.new_slug() }}
vgraph.Field{name: 'created_at', default_now: true, immutable: true}
vgraph.Field{name: 'updated_at', default_now: true, update_now: true}
vgraph.Field{name: 'password_hash', sensitive: true} // never printed or exposed
```
Built-ins: `not_empty`, `min_len`, `max_len`, `match` (a regex), `min`, `max`,
`positive`; flags: `optional`, `immutable`, `sensitive`, `unique`, `comment`,
`deprecated`. The generated setters stay typed; the checks run in `save()`, after
the hooks, as Ent runs them. Normalizing (trimming a title) is a hook's job.
>  A: use the default 

**Q56. What a write returns, and how ids come back.** **Default:**
- `save()` on a create or `update_one` returns the node, read back by its key in one
  select, so database defaults and hooks' changes show; `exec()` skips the read;
- `update().exec()` and `delete().exec()` return the rows changed, through
  `RETURNING` (SQLite 3.35+, PostgreSQL), or a count in the same transaction where the
  driver lacks it (MySQL, a plain `orm.Connection`);
- a new key comes from `RETURNING` with a driver, else `last_id()` inside the
  create's transaction (`int` keys only); a `string` key, such as a UUID, must be set
  or have a `default`;
- `create_bulk` is one multi-row insert with a driver, else one insert per row, in
  one transaction either way.
>  A: agreed

**Q57. Upsert, and what stays out of 6a.** **Default:** 6a has
`create().on_conflict_columns('slug').update_new_values()` / `.ignore()` /
`.do_nothing()` on SQLite and PostgreSQL through the driver (Q51). `Add` (increment),
`Append` and `MapCreateBulk` are in 6a too; transaction hooks are in 6c.
>  A: agreed

**Q58. `examples/service` through Phase 6.** **Default:** in 6a its stores' writes
become builder calls, still behind the same store methods and REST handlers, and it
keeps its slugs. The write endpoints' selects get new baselines, written down with
the reason; the read endpoints' must not change. In 6c the store logic moves into
field options and hooks (Q40), and the stores shrink to reads by slug. In 6e its
`api.graphql` mutations are replaced by generated ones, with REST's messages kept.
>  A: don't update service until all of Phase 6 is complete, then remove all REST functionality and implement only vgraph

**Q59. Exit criteria for each sub-phase.** **Default:** every inventory row for that
sub-phase is done, or moved on purpose with a reason; each feature has tests on
SQLite and PostgreSQL (MySQL untested, Q49); `examples/relations` exercises it per
relationship kind where that applies; generated code is checked in CI; the
graphql-js check still passes on the generated schemas; `v vet` and `v fmt -verify`
are clean.
>  A: agreed

**Q60. `TODO.md` items.** **Default:** fold them into Phase 6 and delete them from
`TODO.md`:
- pagination by config (offset or Relay connections, chosen per table or per field),
  and a `pagination` example showing both: 6e;
- a hooks example with a JWT bearer token and a hook or privacy rule that allows or
  denies access: 6c, using the context (Q53);
- OTel: 6c, on `vgraph.trace`, in its own module so the core needs no OTel dependency;
- polymorphic foreign keys on related tables: 6d. What did you mean: a check that a
  polymorphic edge's `owner_id` points at a row of the table its `owner_type` names
  (a trigger, or a check in a hook)?
- schema discovery and validation: what did you mean? `vgraph describe` (6d), or
  checking the database against the schema?
- docs section: after 6e, before `v0.1.0`;
- federation: already §8.
>  A: Hold on TODO. Once we complete v0.1.0, we will work on these in a new PLAN.md

### Phase 6c (runtime): answer before 6c starts

Background: 6a left a `Mutation` (`MutationData`, and a typed `<T>Mutation` per
table) that every write builds before it runs, and `g.with_ctx(ctx)`, whose `ctx` is
a `graphql.Context` (6a result). Every select the generated client runs starts
from a `<T>Query`: root lists, `count()`, edge loads (`with_<edge>`, which build a
query of the target) and traversals. So one point in the generated code can see
every query, and one point in `Client` every write. Two V constraints shape the
answers: a model's `hooks()` can't import the generated `graph` (Q54), and V has no
`any`, so nothing can rewrite a query's results generically.

**Q61. The shape of a hook.** **Default:**
```v ignore
// in vgraph
pub type Mutate = fn (ctx graphql.Context, mut m Mutation) !
pub struct Hook {
pub:
	name string                                   // for errors and skipping
	on   []Op                                     // empty: every operation
	cond ?fn (ctx graphql.Context, m Mutation) bool // `If`; `unless` negates it
	run  fn (next Mutate) Mutate                  @[required]
}
// on a model, untyped (Q54)
pub fn (a Article) hooks() []vgraph.Hook {
	return [vgraph.Hook{
		on:  [.create]
		run: fn (next vgraph.Mutate) vgraph.Mutate {
			return fn [next] (ctx graphql.Context, mut m vgraph.Mutation) ! {
				if m.field_value('slug') == none {
					m.set_field_value('slug', new_slug())
				}
				next(ctx, mut m)!
			}
		}
	}]
}
```
A hook changes the mutation before `next`, checks after it, or returns an error to
stop the write. `next` returns nothing: Ent's returns the new value, which V can't
type generically; a hook that needs the new row's key reads `m.key()` after `next`.
The order, outermost first: privacy (Q66), runtime hooks for every table, runtime
hooks for the table, the model's `hooks()` in order; then the checks (`fields()`)
and the SQL. Defaults are applied before the hooks run, as in Ent, so hooks see
them. Models import `five07.vgraph.graphql` for the context type.
>  A: looks good

**Q62. Typed runtime hooks.** Registered on the graph at startup:
`g.use(hooks ...vgraph.Hook)` for every table, and
`g.articles().use(fn (next graph.ArticleMutate) graph.ArticleMutate { ... })`, where
the hook gets the typed `ArticleMutation` (`m.title()`, `m.set_title('V')`).
**Default:** yes. The registry is shared by every copy of the `Graph` (`with_ctx`,
`tx`), and is set up before the graph serves requests: registering while requests run
is not safe across threads.
>  A: yes

**Q63. What a hook can see and change.** **Default:** besides 6a's methods,
`Mutation` gains:
- `key() string`: the row's key; on a create, set once `next` has run;
- `keys() ![]string`: the keys an `update` or `delete` of many rows reaches, read in
  the write's transaction;
- `old_field(column) !?orm.Primitive` on `update_one` and `delete_one`: the stored
  value, from one select of the row, cached; the typed mutation has
  `old_<field>()`;
- `add_ids(edge, ...)`, `remove_ids(edge, ...)`, `clear_edge(edge)`: hooks can change
  edges too;
- `set_op(.update)` on a delete, for soft deletes (Q65).

A bulk create runs the hooks once per row, as Ent's `CreateBulk` does.
>  A: these look good

**Q64. Transaction hooks** (moved from 6a). **Default:** inside `g.tx`, `tx.on_commit(fn ())`
and `tx.on_rollback(fn ())` run after the transaction ends, such as to send an email
only once its row is stored. A write outside `g.tx` that runs its own transaction
runs them too.
>  A: looks good

**Q65. Interceptors.** Ent's `Intercept` wraps a query and can change its result;
`Traverse` changes the query before it runs. vgraph can't type a result generically.
**Default:** traverse-style only:
```v ignore
pub type Intercept = fn (ctx graphql.Context, table string, mut q load.Query) !
```
registered like hooks (on a model as `interceptors()`, on the graph with
`g.intercept(...)` or `g.articles().intercept(...)`), and run on every select of the
table: root queries, counts, edge loads, traversals, and the GraphQL resolvers that
use them. One can add conditions (a tenant, soft delete) or return an error (deny).
Typed per-table interceptors get `ArticleQuery` and return it.

Soft delete, as Ent's pattern, built from both: `vgraph.soft_delete('deleted_at')`
returns an interceptor that adds `deleted_at IS NULL`, and a hook that turns a delete
into an update setting it to now. `g.skip('soft_delete')` returns a graph that skips
the interceptors and hooks of that name, to read or purge deleted rows. Per-edge
`soft_del` stays: it is about one edge (an old comment's deleted author still shows).
>  A: agreed

**Q66. Privacy.** **Default:** as Ent's, on top of hooks and interceptors:
```v ignore
pub fn (a Article) policy() vgraph.Policy {
	return vgraph.Policy{
		query:    [allow_if_admin, filter_own_tenant]  // fn (ctx, table, mut q load.Query) !Decision
		mutation: [deny_if_anonymous, allow_if_owner, vgraph.always_deny] // fn (ctx, m Mutation) !Decision
	}
}
```
- rules run in order; each returns `.allow`, `.deny` or `.skip`; the first `.allow` or
  `.deny` decides; when all skip, the operation is allowed, as in Ent, so a list
  should end with `always_deny` where that matters;
- a query rule can narrow the query instead of deciding (a filter rule), as Ent's
  `privacy.FilterFunc`;
- a deny is a `vgraph.PrivacyError`; in GraphQL it is an error at the field, and the
  rest of the response stands;
- runtime policies on the graph (`g.policy(...)`) as for hooks; `g.privileged()`
  returns a graph that skips privacy, for seeds, migrations and system jobs.
>  A: looks great

**Q67. Query tracing** (`vgraph.trace`, Q16). **Default:** `vgraph.trace(conn,
fn (e vgraph.TraceEvent))` wraps a connection, driver or not, and reports each
statement: its kind (select, insert, update, delete, raw), table, duration and
error, plus the SQL and parameters of the driver's own statements. The examples'
`Counting` connections are replaced by it in `examples/relations`
(`examples/service` waits, Q58). OpenTelemetry stays held with `TODO.md` (Q60).
>  A: good, so long as it does not expose values. we can discuss if you have other ideas
>
> *So an event has no parameters, and no error message either: a database's message
> can quote values (PostgreSQL's unique violation: `Key (name)=(red) already
> exists`). It says that the statement failed; the caller gets the error itself.*

**Q68. GraphQL.** **Default:** the generated server already passes each request's
context (6a). In 6c, a `PrivacyError` or a hook's error in a resolver is reported at
its field. The GraphQL transaction (moved from 6a to 6e) stays in 6e.
>  A: perfect

**Q69. Exit criteria for 6c.** **Default:** Q59's, and:
- `hooks_test.v` (or similar) covers each hook form, its order, `on` / `if` /
  `unless`, `old_field`, `keys`, edge changes, transaction hooks, interceptors,
  soft delete with `skip`, every privacy decision, and `privileged`, on SQLite with
  and without a driver;
- the generator test's project uses typed runtime hooks, a model hook, an
  interceptor and a policy through the generated client and its GraphQL server;
- `examples/relations` runs a soft-delete table and a policy on SQLite and
  PostgreSQL;
- no new example: the hooks/JWT example is held with `TODO.md` (Q60).
>  A: agreed

### Phase 6b (queries): answer before 6b starts

Background (checked 2026-10-13): every read runs through `orm.Connection.select`
(`load.select_where`, `select_in`, `count_where`), and every generated select goes
through `Client.prepare_query` (6c). `load.Cond` is a flat list joined with AND.
What the ORM's select can express without a driver: AND and OR with parentheses
(`QueryData.is_and`, `parentheses`), the comparison operators, `LIKE` / `ILIKE`, `IN`
/ `NOT IN`, `IS [NOT] NULL`, one `ORDER BY` column, `LIMIT` / `OFFSET`, `DISTINCT`, one
aggregate per select, inner and left joins. What it can't: `NOT` (other than by
negating each operator; there is no `NOT LIKE`), `ESCAPE`, subqueries and `EXISTS`,
`GROUP BY`, more than one order column, `NULLS FIRST/LAST`, `FOR UPDATE`. So most of
6b needs the drivers (Q51), and one fact shapes how: the SQLite driver's raw call
returns a null cell as `''`, so rows can't be read back reliably as text.

**Q70. How reads use the drivers.** **Default:** (a).
- (a) **Keys first.** A query that needs SQL the ORM can't express runs in two
  steps: the driver runs `SELECT key FROM … WHERE … ORDER BY … LIMIT …` with
  everything (OR, NOT, ESCAPE, EXISTS, several order columns, locks), then the ORM
  reads those rows by key, typed as today, and vgraph puts them back in the first
  query's order. Keys are never null, so the text result is safe. A query the ORM
  can express stays one query, so today's query counts don't change. Without a
  driver, such a query is refused, with an error naming the adapter, except where
  Q73 and Q74 give a fallback.
- (b) **One query, read as text.** The driver runs the whole select and vgraph parses
  each cell from text by field type and dialect. One query, but SQLite's `''` for
  null makes optional strings ambiguous, and time and bool parsing differ by dialect.
- (c) **Wait for the upstream `orm.RawConnection`** (`TODO.md`), which returns typed
  cells. Blocks 6b.
>  A: (a)

**Q71. Composing predicates: `and`, `or`, `not`.** `load.Cond` becomes a tree:
`load.and(...)`, `load.or(...)`, `load.not(...)`. **Default:**
- the generated client gains one typed function per field and operator, named after
  the struct, for use inside `or` / `not`:
  `g.articles().where(load.or(graph.article_title_contains('V'), graph.article_views_gt(10)))`;
  the chained `where_<field>…()` methods stay and are ANDed, as today;
- AND and OR run through the ORM, with no driver needed; `not` is rewritten by
  negating each operator (`=` to `<>`, `IN` to `NOT IN`, `<` to `>=`, AND to OR), and
  needs a driver only around `LIKE`;
- the generated client gains the missing `where_<field>_ne` and `where_<field>_not_in`.
>  A: perfect

**Q72. String predicates.** **Default:**
- `where_<field>_contains`, `_has_prefix`, `_has_suffix`: `LIKE` with `%` and `_`
  escaped (`ESCAPE '\'`) through a driver. Without one, a value holding `%` or `_` is
  refused, not used as a wildcard. `_like` stays, as the raw pattern;
- `_equal_fold` and `_contains_fold`: `LOWER(column) = LOWER(?)` and `LOWER(column)
  LIKE LOWER(?)` through a driver, the same on SQLite (ASCII case only) and
  PostgreSQL. Without a driver, `ILIKE` on PostgreSQL; refused on SQLite;
- GraphQL's `Contains` / `HasPrefix` / `HasSuffix` switch to the escaped forms here,
  which fixes the Phase 4 note; `EqualFold` / `ContainsFold` join the `WhereInput` in
  6e with the rest of it (Q80).
>  A: agreed

**Q73. Edge predicates.** `has_<edge>()` and `has_<edge>_with(fn (q PetQuery) PetQuery)`,
on every edge kind, polymorphic and through join tables. **Default:**
- with a driver: one `EXISTS (SELECT 1 FROM … WHERE …)` subquery;
- without one: two queries, the targets' keys first, then `IN`;
- the target's privacy rules and interceptors apply to the subquery, as to an edge
  load, so a soft-deleted pet doesn't count; Ent leaves them out, but here edge
  loads already apply them, and the two should agree.
>  A: looks good

**Q74. Traversal from a query.** `g.users().where_name('ada').query_pets()` returns a
`PetQuery` of the pets of every user that matches. **Default:** the `PetQuery` holds
the users query and resolves it when it runs: a subquery (`owner_id IN (SELECT id
FROM users WHERE …)`) with a driver, two queries without one. Every edge kind, as
`query_<edge>` on a node has today; a many_to_many edge reads its join table in the
same way.
>  A: perfect

**Q75. Results.** **Default:**
- `only()`: the one matching row, a `NotFoundError` for none, a `NotSingularError`
  for more than one (it reads two);
- `ids() ![]KeyT`, `first_id()`, `only_id()`, `exist() !bool`: keys only, with no edge
  loads;
- `select(...columns)`: the rows with only those columns read, the others left at
  their zero values, as Ent's `Select` fills only what it selects; `unique()` adds
  `DISTINCT`;
- `scan[T]() ![]T`: rows read into an app struct by column name, with
  `load.select_where[T]`'s mapping. It is the one generic method here, and gets a
  regression test of its own.
>  A: looks good

**Q76. Aggregates.** V has no `any`, so results are typed by what they are.
**Default:**
- without grouping, typed methods per numeric field: `sum_<field>() !f64`,
  `min_<field>()`, `max_<field>()`, `mean_<field>() !f64`, besides `count()`. One
  aggregate per query, as the ORM has, so no driver is needed;
- `group_by(...columns).aggregate(vgraph.count(), vgraph.sum('views'), ...)`,
  needing a driver, returns `[]vgraph.Group`: `key map[string]orm.Primitive` (the
  grouped columns) and `values map[string]f64` (`count`, `sum_views`, …), with
  `scan[T]()` to read groups into an app struct instead.
>  A: good

**Q77. Ordering.** **Default:**
- `order_by_<field>()` and `_desc()` add an order column instead of replacing the
  last one, as Ent's `Order` does; a second one needs a driver (Q70);
- `order_by(vgraph.asc('title').nulls_last(), vgraph.desc('id'))` for nulls
  first/last;
- by an edge: `order_by_<edge>_count()` on list edges, and
  `order_by_<edge>_<field>()` on unique ones (many_to_one, one_to_one), through a
  driver subquery;
- GraphQL's `orderBy` stays one field until 6e.
>  A: agreed

**Q78. Locking.** **Default:** `for_update()` and `for_share()`, with `no_wait()` and
`skip_locked()`, through a driver, inside a transaction only (an error outside one).
On PostgreSQL they lock the rows. SQLite has no row locks: there they are refused
with an error saying so, rather than accepted and ignored. The other choice is to
accept them as no-ops on SQLite, since its transactions already serialize writers.
>  A: default

**Q79. The rest of the query inventory.** **Default:**
- named edges: `with_named_<edge>(name, configure)` loads an edge more than once
  with different settings, into `node.named_<edge>[name]`;
- "not loaded" told apart from "empty": `<edge>_or_err() !…` on a node returns a
  `NotLoadedError` when its query didn't ask for the edge; the fields stay as they
  are;
- raw predicates: `load.raw('lower(title) = ?', 'v')`, with parameters only, never
  interpolated text, through a driver; Ent's `Modify` for selects is left out;
- `entql` (filtering at runtime, untyped): the `load.Cond` tree and
  `Client.prepare_query` already are that, and `Client.select_keys` is exposed for it.
>  A: good

**Q80. GraphQL in 6b.** **Default:** only the escaping fix (Q72). `and` / `or` / `not`,
`has<Edge>` / `has<Edge>With`, the `Fold` predicates, multi-field `orderBy` and
connections stay in 6e, which builds them on 6b.
>  A: yes

**Q81. Exit criteria for 6b.** **Default:** Q59's, and:
- every predicate, result method, aggregate, order and lock tested on SQLite and
  PostgreSQL, through the generated client, with and without a driver where both
  work, and each refusal tested where a driver is needed;
- `examples/relations` checks `has_<edge>`, `has_<edge>_with` and traversal from a
  query for each relationship kind, with the queries each runs;
- the existing query-count tests unchanged: what the ORM can run still runs in one
  query.
>  A: good

### Phase 6d (schema): answer before 6d starts

Background (checked 2026-10-13, V master `53dd72c`):
- **The ORM's types:** `i8`, `i16`, `int`, `i64`, `u8`–`u64`, `f32`, `f64`, `bool`,
  `string`, `time.Time`, enums (stored as integers), `[]u8` (BLOB / BYTEA), and
  embedded structs, whose fields become the table's columns. No JSON type: a field
  of a struct type is a relation to the ORM, not a column. vgraph reads only `int`,
  `i64`, `f64`, `bool`, `string` and `time.Time` (and their options, but `?i64`,
  `?f64` and `?bool` fail when a row is read), and skips every array field, `[]u8`
  included.
- **Serial keys:** the ORM creates a `@[sql: serial]` key as `SERIAL` on PostgreSQL,
  which is 32 bits, and as `INTEGER` on SQLite, without `AUTOINCREMENT`, so SQLite
  gives a new row the largest key plus one, and a table's first key can't be set
  ahead of time. V's `int` is 64 bits on this build.
- **`v.migrations`:** `Index{table, columns, name, unique}` has no `WHERE`, so a
  partial index needs `ctx.execute` with SQL.
- **Moved here from earlier sub-phases:** `Append` (with JSON fields), and edge
  `required` / `immutable`.

**Q82. More field types.** **Default:** vgraph reads, writes, checks and generates
for all of the ORM's types:
- `i8`, `i16`, `u8`, `u16`, `u32`, `u64` and `f32` as the ints and floats are today:
  the same predicates, orders and aggregates; in GraphQL `Int` or `Float`, with
  values past 32 bits failing, as for `i64` today;
- enums: stored as integers, as the ORM does; predicates `eq`, `ne`, `in`, `not_in`;
  setters take the enum; in GraphQL an enum type generated from the V enum's values;
- `[]u8`: a bytes column; predicates `eq`, `ne`, `is_null`; left out of GraphQL, as
  entgql leaves bytes out unless told otherwise;
- and the missing options: `?i64`, `?f64`, `?bool` and the rest read as they should.

Keys stay `int`, `i64` or `string`.
>  A: agreed

**Q83. JSON fields.** **Default:** a JSON field is a `string` column in the model
(`sql_type: 'jsonb'` on PostgreSQL, text on SQLite), with an option naming its V
type: `vgraph.Field{name: 'tags', json: '[]string'}`. The generator then writes
`node.tags_value() ![]string` (decoded with `json2`) and `set_tags_value(v []string)`
(encoded) beside the plain string setter; `append_tags(items ...string)` on
`update_one` reads, appends and writes in the update's transaction (locking the row
on PostgreSQL). Predicates: `is_null` and the raw-SQL predicate only. In GraphQL a
`JSON` scalar carrying the decoded value, as entgql's `Map` does for maps.
>  A: agreed

**Q84. Custom types** (Ent's `GoType`, `ValueScanner`). **Default:** a V type alias
of a supported type (`type Email = string`, `type UserID = i64`) works as its base
type, as a field and as a key, and the generated API takes the alias. Anything else
(a struct stored in one column, a custom encoding) needs a JSON field (Q83). There
is no `ValueScanner` hook: the ORM has none to call.
>  A: agreed

**Q85. Globally unique ids, for GraphQL's `Node`** (Q42). Each table's keys start at
its own multiple of 2^32, so a key names its table. **Default:**
- opt-in, per schema, for tables with `i64` serial keys; an `int` key table keeps
  its own sequence and is left out of `Node`;
- `vgraph.global_ids(mut ctx, schema)!` in a migration records each table's index in
  a `vgraph_types` table (appending new tables, so ranges never move), and sets each
  table's next key: on PostgreSQL by `ALTER SEQUENCE … RESTART`, with the key column
  `BIGSERIAL` (`sql_type`); on SQLite by creating the table with `AUTOINCREMENT` and
  setting `sqlite_sequence`, which the ORM's `create table` doesn't do, so these
  tables are created through `migrations.Table`, or a helper vgraph adds for it;
- `Client.table_of(key i64) !string` reads it back; `Node`, `node` and `nodes` in
  GraphQL come with 6e. 

The other choice is Relay's typed global ids (`Article:3`, base64): no ranges and no
migration, but not entgql's convention, which Q28 and Q42 chose.
>  A: go with the default

**Q86. Edge inverses and bidirectional edges.** **Default:**
- `Edge.ref`: the name of the inverse edge on the target, as Ent's `From(…).Ref(…)`.
  `validate` checks the pair: the inverse exists and points back, over the same
  column (one_to_many or one_to_one with many_to_one), or the same join table with
  its columns swapped (many_to_many), with the same polymorphic type. Optional; it
  changes no SQL;
- `Edge.bidi`: on a self edge (a spouse, friends), a write stores both directions,
  as Ent's bidirectional edges do: setting ada's spouse to bob sets bob's to ada,
  and adding a friend adds both join rows. `examples/relations` then stops doing it
  by hand.
>  A: agreed

**Q87. Edge options.** **Default:**
- `required: true` on a many_to_one edge: a create must set it, even when its column
  is nullable (Ent's `Required`);
- `immutable: true`: the update builders have no setter or clear for the edge, and
  the write engine refuses a change;
- Ent's `StorageKey` is already `column` / `through` / `through_to`: nothing to add.
>  A: agreed

**Q88. Edge schemas** (Ent's `Through`: a join table with fields of its own). Today
a join table holds only the two keys. **Default:** a many_to_many edge may name a
registered struct as its join table (`through_struct: 'likes'`): the struct has its
own fields and its two many_to_one edges, and gets its own client and builders.
`validate` checks that its columns are the edge's. `add_<edge>_ids` still writes
join rows when the struct's other fields are optional or have defaults, and is
refused otherwise (create the join rows through their builder). Edge loads can load
the join rows (`with_<join edge>`) as well as the targets. Join tables keep their own
`id`: vgraph keys are one column (Q46).
>  A: agreed

**Q89. Mixins.** **Default:** an embedded struct is a mixin, as V and its ORM already
treat it as part of the table: its fields are the table's columns, and its own
`fields()`, `edges()`, `hooks()`, `interceptors()` and `policy()`, if it has them, are
merged before the table's own. For example a `Timestamps` struct with `created_at` /
`updated_at` and their `default_now` / `update_now`, embedded in every model.
>  A: agreed

**Q90. Declared indexes.** **Default:** `fn (Article) indexes() []vgraph.Index`, beside
`edges()`: `vgraph.Index{columns: ['user_id', 'slug'], unique: true, where:
'deleted_at IS NULL'}`. `migration_indexes()` and `add_edge_indexes` include them;
a partial one (`where`) is created with `ctx.execute`, on SQLite and PostgreSQL
alike; `validate` checks that the columns exist.
>  A: agreed

**Q91. Views and database schemas.** **Default:**
- views: a struct marked `@[vgraph: 'view']` reads from a view: queries, edges and
  GraphQL work; the generator writes no write builders for it, and the migration
  helpers leave it to the app's own `CREATE VIEW`;
- several database schemas (PostgreSQL's `billing.invoices`): out, to §8. The ORM
  quotes a table name as one identifier, so `schema.table` would need changes there.
>  A: agreed

**Q92. `vgraph describe`.** **Default:** `vgraph describe [folder]` prints each table:
its columns (type, null, key, options), edges (kind, target, column or join table,
inverse), indexes, and how many hooks, interceptors and policy rules its model
declares, as `ent describe` does. Text only.
>  A: agreed

**Q93. Generator options** (entc's feature flags, external templates, extensions).
**Default:** every feature stays on (vgraph has nothing like Ent's opt-in flags to
keep small); `vgraph gen` gains `--no-graphql`, for apps without GraphQL. External
templates and extensions: out, to §8. The generator writes V code, not templates,
and a project's own `.graphql` files and `resolvers.v` already cover the common
case. 
>  A: agreed

**Q94. Exit criteria for 6d.** **Default:** Q59's, and:
- `examples/relations` gains a table with every new field type, a JSON field, an enum,
  a mixin, a declared and a partial index, an edge schema, and `ref` / `bidi` on its
  self edges (replacing the hand-written both-ways writes); tested on SQLite and
  PostgreSQL;
- globally unique ids tested on both databases: ranges set, kept when a table is
  added in a later migration, and `table_of` correct;
- a view tested through queries and GraphQL;
- `vgraph describe` tested on `examples/relations`.
>  A: agreed

### Phase 6e (entgql): answer before 6e starts

Background (checked 2026-10-13):
- **What the generator writes today** (`gen/graphql.v`): per table an object type, a
  root list `articles(where, orderBy, limit, offset): [Article!]!` and
  `articlesCount(where)`, list edges `[T!]` with the same arguments, unique edges
  nullable; `ArticleWhereInput` with the Phase 4 predicates, ANDed;
  `ArticleOrder { direction, field }` with one field; enums, `Time` and `JSON`
  scalars. Nested `limit` / `offset` is cut per parent in V (`page`). Mutations exist
  only as the project's own `.graphql` fields, resolved by `Resolvers` methods.
- **What 6a–6d left for it:** the write builders and `<T>Mutation` (6a), hooks and
  privacy, which a generated mutation then runs (6c), `load.and` / `or` / `not`,
  `has_<edge>_with`, the `Fold` predicates, several order columns and order by edge
  (6b), `global_ids` and `Client.table_of` (6d), and `Field.comment` / `deprecated`
  (6a), not yet in the schema.
- **Window functions:** nothing in `load` writes `ROW_NUMBER() OVER (PARTITION BY …)`
  yet; 6b's keys-first plan (Q70 (a)) is where it fits, through a driver.
- **The GraphQL transaction** (moved from 6a): `graphql.Server.transaction` is a
  `Transaction` with `begin` / `commit` / `rollback` and no way to hand the
  resolvers a different graph. The generated resolvers capture the `Graph` they were
  built with (`fn [g] (ctx, …)`), so on a pool a request's mutations would run on
  other connections than its transaction. `examples/service` works today only
  because its `SqliteTransaction` runs `BEGIN` on the single connection the stores
  share.
- **Selections are visible to resolvers:** `FieldInfo.nodes` holds the field's
  merged selections, so a connection can count `totalCount` only when it's asked for.
- **entgql's own split:** entgql generates `CreateTodoInput` / `UpdateTodoInput` and a
  Go `SetInput` on the builders, but the app writes the `createTodo` field and its
  resolver in gqlgen. Q29 / Q27 already chose to generate the mutation fields too.

**Q95. `Node`, `node` and `nodes`** (Q42, Q85). **Default** (revised in chat,
2026-10-13: opt-in rather than inferred from the key):
- a table implements `Node` only when it asks to, with `node: true` in Q104's table
  options (`fn (Article) graphql() vgraph.GraphqlTable`). `validate` refuses it on a
  table without an `i64` serial key, the only kind `global_ids` gives a range to;
  when no table asks, there is no `Node` interface, `node` or `nodes` at all;
- `Graph.graphql()` checks once, at startup, that each `Node` table has a row in
  `vgraph_types`, and fails naming the table if not, so a missing `global_ids`
  migration is an error at boot rather than a `node` that answers wrongly;
- `node(id: ID!): Node` and `nodes(ids: [ID!]!): [Node]!` as entgql's; each id goes
  through `Client.table_of`, and `nodes` reads each table's ids in one query, keeping
  the order asked for, with `null` and an error at its index for an unknown id;
- the table's privacy rules and interceptors apply, as to every other read.

Inferring `Node` from the key was the other choice. A request would cost the same
either way (one `table_of` lookup, then one query per table), but inference can't
tell whether `global_ids` ever ran. A table whose ids start at 1 would then get a
`node` that finds the wrong table, or nothing.
> A: opt-in, as a table option

**Q96. Relay connections: when.** entgql adds a connection only where the
`RelayConnection` annotation asks for one; the rest stay lists. `TODO.md` asked for
"offset or Relay, by config" (held, Q60). **Default:** per table, opt-in (Q104):
- a table with connections gets `articles(after: Cursor, first: Int, before: Cursor,
  last: Int, orderBy, where): ArticleConnection!` as its root field, and every list
  edge pointing at it becomes a connection too, as entgql does;
- a table without stays as it is: lists with `limit` / `offset`, and `<root>Count`;
- the `<root>Count` field goes for a table with connections, since `totalCount`
  replaces it.

The other choices: connections for every table (one style everywhere, but
`examples/service`'s and the tests' lists all change), or both side by side
(`articles` a list, `articlesConnection` a connection), which entgql doesn't do.
> A: agree

**Q97. Relay connections: shape and cursors.** **Default:** entgql's names and types:
`ArticleConnection { edges: [ArticleEdge], pageInfo: PageInfo!, totalCount: Int! }`,
`ArticleEdge { node: Article, cursor: Cursor! }`, `PageInfo { hasNextPage,
hasPreviousPage, startCursor, endCursor }`, and a `Cursor` scalar.
- A cursor is opaque: base64 of JSON holding the row's key and the values of the
  order columns (entgql uses msgpack; the bytes differ, the contract doesn't).
- Paging is keyset, not offset: `after` turns into `(order columns, key) > (values)`,
  written as ORs of ANDs so the ORM can run a single order column without a driver;
  several order columns, or a mix of directions, need a driver (6b).
- `last` / `before` reverse the order, read, and reverse the page back;
  `first` and `last` together are refused, as entgql refuses them.
- `totalCount` runs a count only when it's selected (`FieldInfo.nodes`).
- `hasNextPage` / `hasPreviousPage` read one row past the page, as entgql does.
- No upper limit on `first` / `last` by default; `Server`'s `max_depth` and
  `max_selections` stay the only limits. A `max_page` on the generated server is an
  option to add here if you want one.
> A: agree

**Q98. Per-parent pagination in SQL** (Q32). Nested `limit` / `offset`, and nested
connections' `first` / `after`, are per parent. **Default:**
- with a driver: the keys-first plan (Q70 (a)) gains a window:
  `SELECT key, parent FROM (SELECT …, ROW_NUMBER() OVER (PARTITION BY parent ORDER BY
  …) AS n FROM … WHERE …) WHERE n BETWEEN …`, then the rows by key, as 6b does; through
  a join table for many_to_many, partitioned by the join column. SQLite (3.25+) and
  PostgreSQL both have it;
- without a driver: the Phase 4 way, every row of the edge and the cut in V;
- a nested `totalCount`: one `GROUP BY parent` count for every parent at once (a
  driver), or counted in V without one;
- this lives in `load` (a `Query.per_parent` window), so the generated client gains
  it too: `with_<edge>(fn (q) { return q.limit(3) })` then limits per parent, as
  Ent's `WithComments(func(q) { q.Limit(3) })` does not (Ent limits the whole load).
  So the client's `limit` inside `with_<edge>` changes meaning; the other choice keeps
  it as is and gives the per-parent form its own name (`limit_each(3)`).
> A: agree

**Q99. The full `WhereInput`.** **Default:** entgql's, on 6b:
- `not: ArticleWhereInput`, `and: [ArticleWhereInput!]`, `or: [ArticleWhereInput!]`;
- per edge `hasTags: Boolean` and `hasTagsWith: [TagWhereInput!]` (ANDed, as
  entgql's), polymorphic edges and join tables included; the target's privacy and
  interceptors apply in the subquery (Q73);
- strings gain `EqualFold` and `ContainsFold`; `In` / `NotIn` on floats and times
  (the Phase 4 gaps); `ID` keys gain `In` / `NotIn` on foreign keys already, and keep
  `GT`… on keys only;
- a predicate a plain `orm.Connection` can't run (a `Fold` on SQLite, an escaped
  `Contains` with `%`) is an error at the field, with 6b's message.
> A: agree

**Q100. Ordering in GraphQL.** **Default:**
- `orderBy: [ArticleOrder!]`: a list. GraphQL coerces a single value to a list of one,
  so today's queries keep working; entgql makes it a list only with `MultiOrder`,
  but here it costs nothing;
- the order fields stay every scalar field but JSON, as today; list edges add
  `<EDGE>_COUNT` (`TAGS_COUNT`) and unique edges add nothing unless Q104's field
  option names an edge field to order by (`OWNER_NAME`), as entgql's `OrderField` on
  an edge does;
- a connection's cursor holds every order column (Q97).
> A: agree

**Q101. Generated mutations: which fields.** entgql leaves the fields to the app
(see the background); Q27 / Q38 / Q40 asked for them generated. **Default:** per table,
unless Q104 turns some off:
- `createArticle(input: CreateArticleInput!): Article!`;
- `updateArticle(id: ID!, input: UpdateArticleInput!): Article!`;
- `deleteArticle(id: ID!): ID!`, which returns the id deleted;
- none for views (no write builders), for tables hidden with `@[graphql: '-']`, and
  for edge-schema join structs unless they're visible;
- no bulk (`createArticles`), update-many or delete-many fields; entgql has none.
  The app adds them in its `.graphql` files, resolved with the builders, as today.

Each runs the builder, so `fields()` checks, defaults, hooks and privacy all apply,
and a check's or hook's error is an error at the field (Q68). The request's
transaction (Q103) holds the writes.
> A: agree

**Q102. Mutation inputs.** **Default:** entgql's `Mutations()` inputs:
- `CreateArticleInput`: each writable field, non-null when it's required on create,
  nullable when it's optional or has a default (`default`, `default_now`); the serial
  key and fields with only an `update_default` left out. Edges: `ownerID: ID` for a
  many_to_one (non-null when `required`), `tagIDs: [ID!]` for list edges;
- `UpdateArticleInput`: every mutable field nullable (immutable fields and edges left
  out), `clearSummary: Boolean` for each optional field, `ownerID` / `clearOwner`,
  `addTagIDs` / `removeTagIDs` / `clearTags`;
- JSON fields take the `JSON` scalar; enums their GraphQL enum; a polymorphic edge's
  id needs its type too, so it gets `ownerID` and `ownerType`, checked against the
  edge's tables;
- `sensitive` fields stay in both inputs (a password is written, never read), as Ent
  keeps them; only `@[graphql: '-']` / `graphql_skip` removes a field from inputs too.
  Q104 can drop a field from one input only, as entgql's `Skip` modes do;
- the generated client gains `set_input(CreateArticleInput)` and the update's, as
  entgql's `SetInput`, so the app's own resolvers can reuse them.
> A: agree

**Q103. A request's transaction on `g.tx`** (moved from 6a). The resolvers need the
transaction's graph, not the one they were built with. **Default:**
- `graphql.Transaction.begin` becomes `begin(ctx Context) !Context`: it returns the
  context the request's mutations run with. The `graphql` module still knows nothing
  of vgraph;
- the generated server sets its own `Transaction` when the client can begin one: it
  wraps the request's context in a `vgraph.TxContext` holding the transaction's
  client, and every generated resolver starts from `g.with_ctx(ctx)`, which switches
  to that client when it finds one. `ctx()` unwraps it, so hooks and privacy rules
  still see the app's own context;
- the app's `Resolvers` reach it the same way (`r.graph.with_ctx(ctx)`); the
  generated `resolvers.v` stub's comment says so;
- an app can still set `server.transaction` itself, or turn it off.
> A: agree

**Q104. Annotations.** entgql's: `Skip` (with modes), `Type`, `QueryField`,
`RelayConnection`, `Mutations`, `OrderField`, `MultiOrder`, `Directives`.
**Default:** data, in the places vgraph already has:
- per table, an optional `fn (Article) graphql() vgraph.GraphqlTable` beside
  `fields()` / `edges()`: `type_name` (entgql's `Type`), `query_field` (the root
  field's name, or `'-'` for none), `node` (Q95), `relay` (Q96), `mutations` (`[.create, .update,
  .delete]` by default; `[]` for none), `directives` (SDL strings, such as
  `'@key(fields: "id")'`, printed on the type as written);
- per field, in `vgraph.Field`: `graphql_skip` gains modes (`.all`, `.type`,
  `.where`, `.order`, `.create_input`, `.update_input`), `order_field` (a name, or
  `'-'` to leave it out), `directives`;
- per edge, in `vgraph.Edge`: `graphql_skip`, `order_field` for a unique edge's
  field (Q100), `directives`;
- `@[graphql: '-']` keeps working, as `.all`;
- `comment` and `deprecated` become descriptions and `@deprecated(reason:)` on the
  field and its inputs (moved here from 6a), and a model's doc comment isn't read:
  V's comptime can't see it.

The other choice, struct attributes (`@[graphql: 'relay']`), can't hold lists or
names cleanly, and `fields()` already took the field options off attributes.
> A: agree

**Q105. Polymorphic edges as unions** (Q28: "can come in 6e"). entgql has no
polymorphic edges, so there is no convention to follow. **Default:** leave them as
separate fields (`Comment.article`, `Comment.post`), as Phase 4 has them, and put a
union (`owner: CommentOwner`) in §8. The other choice adds the union field beside
the separate ones, when every target table is visible.
> A: agreed

**Q106. Named operations in the project's `.graphql` files** (the "Also for 6e"
note). **Default:**
- (a) in 6e: `vgraph gen` fails on an operation or fragment in a schema file, at its
  file and line; files under an `operations/` folder (anywhere in the project) hold
  operations only, are validated against the generated schema on every `vgraph gen`,
  and are not served. CI then catches a query that a schema change broke;
- (b) stored operations ("trusted documents") and (c) a typed V client per operation:
  §8.
> A: agree

**Q107. `examples/service` after 6e** (Q58). Q58 says that once Phase 6 is complete
its REST API goes and it runs on vgraph alone. **Default:** that is its own phase,
**Phase 7**, with its own questions (slugs, which hooks, which mutations stay
hand-written, the end of the REST-to-GraphQL query-count comparison), so 6e's exit
doesn't depend on it. In 6e `examples/service` is only regenerated, and that
collides: its `api.graphql` already declares `createUser`, `updateUser`,
`deleteUser`, `createArticle`, `updateArticle`, `deleteArticle` and the post ones,
keyed by slug and returning `Boolean!` on delete, which the generated fields of
Q101 would duplicate. So its tables set Q104's `mutations: []` until Phase 7, and
`vgraph gen` reports such a clash at the `.graphql` file's line rather than
merging it.
> A: agree

**Q108. Exit criteria for 6e.** **Default:** Q59's, and:
- `examples/relations`: `node` / `nodes` over the global-id table and an error for a
  non-global id; a table with connections, root and nested, paged forward and back
  with a multi-column order, `totalCount` only when selected, with the selects each
  runs; nested `limit` and `first` in one query per edge with a driver, and the V cut
  without; the full `WhereInput` per relationship kind; every generated mutation per
  relationship kind, including a rollback of a request whose second mutation fails,
  on a PostgreSQL pool;
- the generator test's project: annotations (a renamed type and root field, a field
  left out of one input, mutations turned off, directives), descriptions and
  `@deprecated`, and an operation in `operations/` that fails when it no longer
  validates;
- graphql-js 16.11.0 builds and prints every generated schema unchanged, and the
  introspection checks are regenerated;
- the inventory's entgql rows are all done or moved with a reason.
> A: agree
