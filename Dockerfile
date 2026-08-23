# ---------------------------------------------------------------------------
# base: toolchain plus fetched dependencies, shared by dev and builder
# ---------------------------------------------------------------------------
FROM erlang:26-alpine AS base

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
COPY test ./test

# Compile the application, not just its dependencies. Without this the image
# builds green over source that does not compile, and warnings_as_errors does
# not fire until the first eunit or release run.
RUN rebar3 compile

# ---------------------------------------------------------------------------
# dev: what docker-compose runs -- rebar3 on hand for eunit and the shell
# ---------------------------------------------------------------------------
FROM base AS dev

EXPOSE 8080
CMD ["rebar3", "shell"]

# ---------------------------------------------------------------------------
# builder: assembles the self-contained OTP release
# ---------------------------------------------------------------------------
FROM base AS builder

RUN rebar3 as prod tar \
    && mkdir -p /release \
    && tar -xzf _build/prod/rel/kv_store/kv_store-*.tar.gz -C /release

# ---------------------------------------------------------------------------
# runtime: the release and nothing else -- no rebar3, no compiler, no sources
# ---------------------------------------------------------------------------
FROM alpine:3.24 AS runtime

RUN apk add --no-cache libstdc++ ncurses-libs openssl \
    && adduser -D -h /app kv

WORKDIR /app
COPY --from=builder --chown=kv:kv /release ./
USER kv

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["bin/kv_store", "foreground"]
