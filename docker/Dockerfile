# Dockerfile.tmux-build — minimal Ubuntu 22.04 base for building tmux from
# source with jemalloc support, isolated from the host per §12.9 architecture.
#
# Usage: invoked by scripts/build_containerized.sh — do NOT run
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
#
# `-o` (allow non-unique) on both groupadd and useradd: on macOS hosts the
# operator's primary GID is 20 (staff) — which collides with Ubuntu's
# dialout group at the same GID. Without `-o`, groupadd fails and the build
# aborts. The duplicate-GID is harmless for our volume-mount permission
# matching purpose. Same logic for UID (macOS users often start at 501,
# which may or may not collide depending on the base image).
RUN groupadd -g $BUILD_GID -o builder \
    && useradd -m -u $BUILD_UID -o -g builder -s /bin/bash builder

USER builder
WORKDIR /tmux-src

# Default command (overridden by the orchestrator)
CMD ["bash", "-c", "echo 'tmux build container ready'"]
