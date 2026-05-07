# Dockerfile.tmux-build — minimal Ubuntu 22.04 base for building tmux from
# source with jemalloc support, isolated from the host per §12.9 architecture.
#
# Usage: invoked by scripts/tmux/build_tmux_containerized.sh — do NOT run
# `docker build` directly; the orchestrator handles UID/GID matching and
# volume mounts.

FROM ubuntu:22.04

ARG BUILD_UID=1000
ARG BUILD_GID=1000

# Avoid interactive prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install build deps in one layer for image size hygiene
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        autoconf \
        automake \
        libtool \
        pkg-config \
        bison \
        libevent-dev \
        libncurses-dev \
        libjemalloc-dev \
        ca-certificates \
        git \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root builder user matching the host UID/GID (so output files
# are owned by the host operator, not root). Mirrors §12.9 Dockerfile pattern.
RUN groupadd -g $BUILD_GID builder \
    && useradd -m -u $BUILD_UID -g builder -s /bin/bash builder

USER builder
WORKDIR /tmux-src

# Default command (overridden by the orchestrator)
CMD ["bash", "-c", "echo 'tmux build container ready'"]
