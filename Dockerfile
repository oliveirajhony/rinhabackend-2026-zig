# syntax=docker/dockerfile:1
# 3-stage build:
#   1. zig: download Zig 0.16 toolchain (heavy, cacheable)
#   2. build: compile preprocess + api + lb (musl static, single-host)
#   3. preprocess-data: download references.json.gz, run preprocess → dataset.bin
#   4. final (scratch): api + lb + dataset.bin. Entrypoint set per-service via compose.

FROM debian:bookworm-slim AS zig
ARG ZIG_VERSION=0.16.0
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz \
    && ln -s /opt/zig/zig /usr/local/bin/zig

FROM zig AS build
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN zig build -Drelease=true --summary all

FROM debian:bookworm-slim AS preprocess-data
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
ADD https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/resources/references.json.gz \
    /data/references.json.gz
COPY --from=build /src/zig-out/bin/preprocess /usr/local/bin/preprocess
RUN mkdir -p /index && /usr/local/bin/preprocess /data/references.json.gz /index/dataset.bin

FROM scratch AS final
COPY --from=build /src/zig-out/bin/api /api
COPY --from=build /src/zig-out/bin/lb /lb
COPY --from=preprocess-data /index/dataset.bin /dataset.bin
# Default entrypoint is api; override in docker-compose for the LB service.
ENTRYPOINT ["/api"]
