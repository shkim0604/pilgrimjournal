# syntax=docker/dockerfile:1
#
# Group server image: `serve` (API) and `worker` run from the same image (docker-compose.yml).
# Build context is server/, so the PilgrimAPI contract package (server/PilgrimAPI) is inside it.
# Multi-arch: the official swift and ubuntu images are published for arm64 (Mac mini) and amd64.

# ---- build ---------------------------------------------------------------------------------
FROM swift:6.2-noble AS build

RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q install -y libjemalloc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Resolve dependencies first so source edits do not refetch them.
COPY PilgrimAPI/Package.swift PilgrimAPI/Package.swift
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY . .

RUN swift build -c release \
        --product PilgrimServer \
        --static-swift-stdlib \
        -Xlinker -ljemalloc

WORKDIR /staging
RUN cp "$(swift build --package-path /build -c release --show-bin-path)/PilgrimServer" ./ \
    && cp /usr/libexec/swift/linux/swift-backtrace-static ./ \
    && find -L "$(swift build --package-path /build -c release --show-bin-path)/" \
        -regex '.*\.resources$' -exec cp -Ra {} ./ \;

# ---- run -----------------------------------------------------------------------------------
FROM ubuntu:noble

# tzdata: users' IANA time zones (expiry, Daily Report). ca-certificates: Apple, APNs.
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q install -y libjemalloc2 ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app pilgrim \
    && mkdir -p /data/media \
    && chown pilgrim:pilgrim /data/media

WORKDIR /app
COPY --from=build --chown=pilgrim:pilgrim /staging /app

ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static
ENV APP_ENV=production \
    HTTP_HOST=0.0.0.0 \
    PORT=3100 \
    MEDIA_ROOT=/data/media

USER pilgrim:pilgrim
VOLUME ["/data/media"]
EXPOSE 3100

ENTRYPOINT ["./PilgrimServer"]
CMD ["serve"]
