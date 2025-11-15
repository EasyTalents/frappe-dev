FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# 1) Deps système + Python + MariaDB + Redis + cron
RUN apt-get update && apt-get install -y \
    sudo \
    curl \
    git \
    build-essential \
    python3 \
    python3-dev \
    python3-venv \
    python3-pip \
    libffi-dev \
    libssl-dev \
    mariadb-server \
    mariadb-client \
    redis-server \
    cron \
    xvfb \
    libfontconfig \
 && rm -rf /var/lib/apt/lists/*

# 2) Node.js 20 (LTS) + Yarn
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get update && apt-get install -y nodejs && \
    npm install -g yarn && \
    rm -rf /var/lib/apt/lists/*

# 3) User "coder" compatible Coder
RUN useradd -m coder && echo "coder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER coder

# 4) Répertoire de travail par défaut
WORKDIR /workspaces

# 5) PATH pour uv / bench
ENV PATH="/home/coder/.local/bin:${PATH}"
