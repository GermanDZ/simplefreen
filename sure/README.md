# sure-finances deployment

A self-contained Kamal project that deploys [sure-finances][src] (a
self-hosted Rails 7.2 fork of Maybe Finance) onto the same host as
simplefreen (`$KAMAL_HOST`), behind the same off-host edge proxy that
fronts simplefreen.

The sure-finances source lives in a sibling clone (`../../sure-finances`)
and is kept pristine for upstream contribution. This directory owns
all the deployment surface (`config/deploy.yml`, secrets,
hostname/TLS routing).

[src]: https://github.com/we-promise/sure

## Topology

```
LAN/VPN clients (HTTPS :443)
  └─▶ edge proxy (<edge-ip>, off-host; terminates TLS,
        │           not part of this repo)
        └─▶ kamal-proxy (host-wide singleton, vhost-routes by Host header)
              ├─▶ Host: $SIMPLEFREEN_HOST → simplefreen-web:7878
              └─▶ Host: $SURE_HOST        → sure-web:3000
                                          │
                       sure-worker (Sidekiq) ┘
                       sure-postgres  (accessory, Postgres 16, volume sure_postgres_data)
                       sure-redis     (accessory, Redis 7,    volume sure_redis_data)
                       sure_storage   (volume, ActiveStorage local disk)
```

## First-time setup

From this directory (`simplefreen/sure/`):

1. **Pin a sure-finances ref** in the sibling clone — that's what gets built:
   ```sh
   (cd ../../sure-finances && git checkout <tag-or-sha>)
   ```
2. **Environment**: export `KAMAL_HOST` (deploy target) and `SURE_HOST`
   (public hostname, e.g. `sure.example.com`), e.g. from a gitignored
   `.envrc`. `config/deploy.yml` reads both via ERB.
3. **DNS + edge**: `$SURE_HOST` resolves to the edge proxy, and the edge
   has a vhost for it forwarding to `<KAMAL_HOST>:80` (same shape as
   simplefreen's, minus the noVNC route — see `../docs/operator-guide.md`
   § "Edge proxy").
4. **Secrets**:
   ```sh
   cp .kamal/secrets.example .kamal/secrets
   # fill in GHCR_TOKEN, SECRET_KEY_BASE, POSTGRES_PASSWORD
   ```
5. **Deploy**:
   ```sh
   kamal setup
   ```

## Backups

```sh
bin/backup-db                  # backups/sure-<utc-stamp>.dump
bin/backup-db before-upgrade   # backups/sure-<utc-stamp>-before-upgrade.dump
bin/restore-db backups/sure.latest.dump
```

Run `bin/backup-db before-<label>` immediately before any `kamal deploy`
that may run migrations. Dumps are pg_dump custom-format (`-Fc`) so they
restore cleanly with `--clean --if-exists`. `backups/sure.latest.dump`
is a symlink to the most recent dump, for convenience.

`bin/restore-db` is destructive — drops and recreates every object in
prod `sure_production`. Stop the app first:

```sh
kamal app stop
bin/restore-db backups/sure.latest.dump
kamal app boot
```

## Day-to-day

```sh
cd simplefreen/sure
kamal app logs -f               # tail web
kamal app logs -r worker -f     # tail Sidekiq
kamal app exec --interactive bash
kamal accessory logs postgres   # or `redis`
kamal app boot                  # recreate containers from current image
kamal app stop && kamal app boot   # clean replacement
```

## Upgrading the deployed version

`kamal deploy` is **not** the upgrade path here. Its remote buildx
driver runs buildkit in its own container, which can't reach the
LXC's host-local registry at `127.0.0.1:5000`. We build via
`bin/rebuild` instead, which SSHes to the LXC and runs plain
`docker build` against the LXC's daemon — same pattern as
[`../bin/build-freentonic-image`](../bin/build-freentonic-image).

```sh
(cd ../../sure-finances && git fetch && git checkout <ref>)  # pin
bin/backup-db before-upgrade                                 # safety net
bin/rebuild                                                  # build + push to 127.0.0.1:5000
kamal app boot                                               # roll containers
```

`bin/rebuild` auto-detects the sibling clone at `../../sure-finances`.
Override with `SURE_SRC=/path/to/checkout bin/rebuild`, or omit any
local source and it'll `git clone we-promise/sure` on the LXC
(`SURE_REPO` / `SURE_REF` to point at a fork/branch).

Day-to-day development at `HEAD` in the clone is unaffected — only
the checkout state at the moment `bin/rebuild` runs is what ships.

## Why this layout

- **sure-finances clone stays pristine** so upstream contributions
  aren't polluted with deployment files.
- **Kamal project is self-contained in `sure/`** — running `kamal`
  from here means it uses this `.kamal/secrets` and this (empty)
  `.kamal/hooks/`, not simplefreen's. No accidental cross-contamination
  with simplefreen's freentonic build hook.
- **One Kamal project per app** — simplefreen and sure deploy
  independently. The shared infrastructure (the off-host edge Caddy +
  the host-singleton `kamal-proxy`) sits in front of both and is
  naturally multi-tenant.
