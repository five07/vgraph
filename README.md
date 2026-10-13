# vgraph

An [Ent](https://entgo.io)-style graph layer for [V](https://vlang.io): declare the edges
between your entities once, load them in batches (one query per edge, not one per row),
and traverse them through a typed API. It runs on V's `orm.Connection`, so it works with
the SQLite, PostgreSQL and MySQL adapters.

**Status:** early design. Nothing is published yet. See [PLAN.md](PLAN.md) in the develop branch for the plan.

## Layout

- `spike/`: Phase 0, which checks that V's compile-time reflection and ORM can support
  batched edge loading. Run it with `v test spike/`.

## Requirements

V master (built against `53dd72c`, 2026-10-12). It will pin to a `0.5.x` release
before `v0.1.0`.

## License

MIT
