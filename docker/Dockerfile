# Simplefreen — SimpleFIN bridge that drives freentonic over HTTP.
# Slim Ruby base. No Chrome / Xvfb / VNC / browser tooling — all of
# that lives in the freentonic image.
#
# Pinned to an exact patch so a stale cached base can't slip into a
# build and upgrades show up as a diff. Bump for Ruby/Debian security
# releases.
FROM ruby:3.4.12-slim-trixie

# tini as pid 1 for clean signal forwarding.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Non-root user with a stable uid so bind-mounted /data files are owned
# predictably on the host (matches freentonic's convention).
ARG SIMPLEFREEN_UID=10001
RUN groupadd -g ${SIMPLEFREEN_UID} simplefreen \
 && useradd  -u ${SIMPLEFREEN_UID} -g ${SIMPLEFREEN_UID} -m -s /usr/sbin/nologin simplefreen

WORKDIR /opt/simplefreen

# App code. Copy with lean globbing so a dev-mode bind-mount over this
# path (via docker-compose) overlays the same file tree.
COPY bin         ./bin
COPY lib         ./lib
COPY simplefreen.gemspec Gemfile Rakefile README.md AGENTS.md LICENSE SECURITY.md ./
COPY docs        ./docs

# No runtime gems to install — zero-runtime-deps invariant mirrors
# freentonic. Just make sure the binary is on PATH.
RUN chmod +x /opt/simplefreen/bin/simplefreen \
 && ln -s /opt/simplefreen/bin/simplefreen /usr/local/bin/simplefreen

COPY docker/entrypoint.sh /opt/simplefreen/entrypoint.sh
RUN chmod +x /opt/simplefreen/entrypoint.sh

# Pre-create every mount point with the right ownership so that a
# fresh named Docker volume (created root-owned by default) inherits
# uid 10001 perms on first attach. Without this the entrypoint can't
# write into /data when running as USER simplefreen.
RUN mkdir -p /data /workflows /workspace/runs \
 && chown -R simplefreen:simplefreen /data /workflows /workspace

USER simplefreen

# State dir (bind-mount or named volume).
VOLUME ["/data"]

EXPOSE 7878

ENTRYPOINT ["tini", "--", "/opt/simplefreen/entrypoint.sh"]
CMD ["simplefreen"]
