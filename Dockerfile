ARG BASE=silex/emacs:29.4
FROM --platform=${BUILDPLATFORM:-linux/arm64} ${BASE}

RUN apt-get update && \
    apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*
