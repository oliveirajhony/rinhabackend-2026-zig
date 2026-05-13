# syntax=docker/dockerfile:1
# Base image with Zig 0.16 pinned; used by api/lb/preprocess Dockerfiles.
FROM debian:bookworm-slim AS zig
ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=skip
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && zig version

FROM zig AS build
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN zig build -Drelease=true --summary all
