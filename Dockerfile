ARG ALPINE_RUNNER_VERSION=3.24

# Elixir 1.20.4 / OTP 29.1.2, matching CI. Pin the multi-platform image.
ARG BUILDER_IMAGE="elixir:1.20.4-otp-29-alpine@sha256:f95251968625b0b61716355b372b58b1916bb618b949de3d2e62fb803ad68784"
ARG RUNNER_IMAGE="alpine:${ALPINE_RUNNER_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apk add --no-cache build-base ca-certificates git npm openssl && \
    update-ca-certificates

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY config/runtime.exs config/

COPY assets assets
COPY lib lib
COPY priv priv
COPY rel rel

# Compile the release
RUN mix compile
RUN mix assets.deploy

RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN apk add --no-cache libstdc++ ncurses-libs openssl tzdata && \
    addgroup -S nonroot && \
    adduser -S nonroot -G nonroot

WORKDIR "/app"

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nonroot:nonroot /app/_build/${MIX_ENV}/rel/xeba ./

USER nonroot

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD wget -q -T 3 -O /dev/null "http://127.0.0.1:${PORT:-4000}/health/ready" || exit 1

CMD ["/app/bin/xeba", "start"]
