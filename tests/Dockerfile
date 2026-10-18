FROM debian:stable
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        nginx jq openssl curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
