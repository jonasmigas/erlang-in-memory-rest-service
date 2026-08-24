# ---------------------------------------------------------------------------
# base: dependencies and the compiled application, shared by dev and builder
# ---------------------------------------------------------------------------
FROM erlang:26-alpine AS base

# The port the application binds inside the container. EXPOSE, the health
# probe and the release CMD all read it, so there is one value to change.
ENV APP_PORT=8080

WORKDIR /app

# rebar3 comes from the base image, which builds it from source, verifies it
# and pins the version by tag. Downloading a second copy here would add a pin
# that drifts from the erlang: tag -- and the base image also sets
# REBAR3_VERSION, which shadows a same-named ARG on the classic builder, so
# the URL and the checksum disagree and the build dies.
#
# No apk packages are needed either: every entry in rebar.lock is a pure
# Erlang hex package, so nothing invokes a C compiler or a git client.

# rebar.lock pins the transitive deps (cowlib, ranch); rebar.config alone pins
# only cowboy and jsx. Both land before the sources so editing src/ does not
# re-fetch.
COPY rebar.config rebar.lock ./
RUN rebar3 compile

COPY config ./config
COPY src ./src

# Compile the application, not just its dependencies. Without this the image
# builds green over source that does not compile, and warnings_as_errors does
# not fire until the first eunit or release run.
RUN rebar3 compile

EXPOSE ${APP_PORT}

# 127.0.0.1, not localhost: /etc/hosts maps localhost to both 127.0.0.1
# and ::1, the listener binds IPv4 only, and which of the two a resolver
# hands back first is not ours to decide. Where it answers ::1 the probe
# gets "Address not available" and reports a healthy service as down.
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
    CMD wget -qO- "http://127.0.0.1:${APP_PORT}/health" || exit 1

# ---------------------------------------------------------------------------
# dev: what docker-compose runs -- rebar3 on hand for eunit and the shell
# ---------------------------------------------------------------------------
FROM base AS dev

# Only the dev stage needs these. Keeping them out of base means editing a
# test or the benchmark does not invalidate the release build below.
COPY test ./test
COPY bench ./bench

CMD ["rebar3", "shell"]

# ---------------------------------------------------------------------------
# builder: assembles the self-contained OTP release
# ---------------------------------------------------------------------------
FROM base AS builder

# `release`, not `tar`: a tarball would only be unpacked again in the next
# stage, paying a gzip round trip and holding both copies in one layer.
RUN rebar3 as prod release

# ---------------------------------------------------------------------------
# runtime: the release and nothing else -- no rebar3, no compiler, no sources
# ---------------------------------------------------------------------------
FROM alpine:3.24 AS runtime

RUN apk add --no-cache libstdc++ ncurses-libs openssl \
    && adduser -D -h /app kv

ENV APP_PORT=8080

# config/vm.args confines the distribution listener to loopback; epmd needs
# telling separately, since it binds every interface by default.
ENV ERL_EPMD_ADDRESS=127.0.0.1

WORKDIR /app
COPY --from=builder --chown=kv:kv /app/_build/prod/rel/kv_store ./
USER kv

EXPOSE ${APP_PORT}

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
    CMD wget -qO- "http://127.0.0.1:${APP_PORT}/health" || exit 1

# -kv_store port overrides the sys.config value, so APP_PORT drives the bind,
# the probe and EXPOSE together rather than each carrying its own literal.
CMD ["sh", "-c", "exec bin/kv_store foreground -kv_store port $APP_PORT"]
