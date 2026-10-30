# Migration from the bundled simplefin bridge

A previous version of freentonic shipped the SimpleFIN emulator as a
bolt-on subsystem (`lib/freentonic/simplefin/*`). Starting with
freentonic `vX.Y.Z` it's been extracted to this repo. The on-disk
state layout is **identical**, so migration is just a rewiring.

## What moves

| Old location | New location |
| ------------ | ------------ |
| `~/freentonic/simplefin/profiles/*.json` | `~/simplefreen-data/profiles/*.json` (no format change) |
| `~/freentonic/simplefin/state/*.json` | `~/simplefreen-data/state/*.json` |
| `~/freentonic/simplefin/cache/*/latest.json` | `~/simplefreen-data/cache/*/latest.json` |
| `~/freentonic/simplefin/claims/*.json` | `~/simplefreen-data/claims/*.json` |
| `~/freentonic/simplefin/runs/*/*.json` | `~/simplefreen-data/runs/*/*.json` |

Or — if you don't feel like moving files — keep the same directory
and point simplefreen's bind-mount at it:

```yaml
simplefreen:
  volumes:
    - ${HOME}/freentonic/simplefin:/data
```

## Environment variable renames

| Old | New |
| --- | --- |
| `FREENTONIC_SIMPLEFIN_ENABLED` | *(removed — the emulator is always "enabled"; whether you run it is a deployment choice)* |
| `FREENTONIC_SECRETS_KEY` | `SIMPLEFREEN_SECRETS_KEY` |
| `FREENTONIC_ADMIN_PASSWORD` | `SIMPLEFREEN_ADMIN_PASSWORD` |
| `FREENTONIC_PUBLIC_URL` | `SIMPLEFREEN_PUBLIC_URL` |
| `FREENTONIC_SIMPLEFIN_ROOT` | `SIMPLEFREEN_ROOT` |
| `FREENTONIC_CORS_ALLOWED_ORIGINS` | `SIMPLEFREEN_CORS_ALLOWED_ORIGINS` |

And two new ones required to tell simplefreen where freentonic lives:

- `FREENTONIC_URL` — where simplefreen calls `/invoke` (e.g.
  `http://freentonic:7878` on a shared Docker network).
- `FREENTONIC_INVOKE_TOKEN` — same value the old freentonic container
  used. Unchanged.

## Step-by-step

1. **Stop the old combined container.**
   ```sh
   docker stop freentonic-server && docker rm freentonic-server
   ```
   The bind-mounted state dir survives.

2. **Rebuild freentonic from the post-cleanup tree.** The new image has
   no SimpleFIN code — it's just the pure scraper.
   ```sh
   cd ~/code/freentonic
   git pull
   docker build -t freentonic:latest .
   ```

3. **Build simplefreen.**
   ```sh
   cd ~/code/simplefreen
   docker build -f docker/Dockerfile -t simplefreen:latest .
   ```

4. **Bring up both with compose.** Copy the example compose file,
   populate `.env`, `docker compose up -d`.

5. **Re-link in Actual?** Probably not. The access URL Actual stored
   points at the hostname you configured in `FREENTONIC_PUBLIC_URL`. If
   that hostname/port now routes to simplefreen instead of the old
   combined container, Actual's next `Sync` keeps working. If the
   hostname changed, click **Reset SimpleFIN credentials** in Actual
   and paste a fresh setup token.

6. **Verify.** In the admin UI:
   - Every profile you had should be listed.
   - Credentials pills ("N secrets") should still show — they're on
     disk, just reused by the new binary.
   - Trigger a **Sync now**. State should go `idle → queued → running
     → ready` as the scheduler calls freentonic and the push receiver
     writes the cache.
