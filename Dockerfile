# ---------------------------------------------------------------------------
# base: toolchain plus fetched dependencies, shared by dev and builder
# ---------------------------------------------------------------------------
FROM erlang:26-alpine AS base

# Pinned rather than pulled from s3.amazonaws.com/rebar3/rebar3, which always
# serves the newest build: with that URL the image contents depend on the day
# it was built. The checksum makes the download tamper-evident.
ARG REBAR3_VERSION=3.24.0
ARG REBAR3_SHA256=d2d31cfb98904b8e4917300a75f870de12cb5167cd6214d1043e973a56668a54

RUN apk add --no-cache git build-base \
    && wget -O /usr/local/bin/rebar3 \
        "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
    && echo "${REBAR3_SHA256}  /usr/local/bin/rebar3" | sha256sum -c - \
    && chmod +x /usr/local/bin/rebar3 \
    && rebar3 --version

WORKDIR /app

# rebar.lock pins the transitive deps (cowlib, ranch); rebar.config alone pins
# only cowboy and jsx, so copying just the config lets the rest re-resolve at
# build time. Both land before the sources so editing src/ does not re-fetch.
COPY rebar.config rebar.lock ./
RUN rebar3 compile

COPY config ./config
COPY src ./src
COPY test ./test

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
