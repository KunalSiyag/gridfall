# GridFall development container: Godot (headless use) per .godot-version, the tools venv, git, gh.
# Built from the repo root (devcontainer.json sets the context) so it can read the pinned files.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip zip git gh python3 python3-venv python3-pip \
        util-linux fontconfig libfontconfig1 libglib2.0-0 sudo \
    && rm -rf /var/lib/apt/lists/* \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu

COPY .godot-version /tmp/gridfall/.godot-version
RUN set -eu; \
    ver="$(tr -d '[:space:]' < /tmp/gridfall/.godot-version)"; \
    dl="${ver%.stable}-stable"; \
    curl -fsSL --retry 3 -o /tmp/godot.zip \
      "https://github.com/godotengine/godot/releases/download/${dl}/Godot_v${dl}_linux.x86_64.zip"; \
    unzip -q /tmp/godot.zip -d /opt/godot; \
    mv "/opt/godot/Godot_v${dl}_linux.x86_64" /opt/godot/godot; \
    chmod +x /opt/godot/godot; \
    ln -s /opt/godot/godot /usr/local/bin/godot; \
    rm /tmp/godot.zip; \
    godot --headless --version

USER ubuntu
COPY --chown=ubuntu:ubuntu tools/requirements-dev.txt /tmp/gridfall/requirements-dev.txt
RUN python3 -m venv /home/ubuntu/.venvs/gridfall-tools \
    && /home/ubuntu/.venvs/gridfall-tools/bin/pip install --no-cache-dir -r /tmp/gridfall/requirements-dev.txt
ENV PATH="/home/ubuntu/.venvs/gridfall-tools/bin:${PATH}"
