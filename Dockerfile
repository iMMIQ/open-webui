# syntax=docker/dockerfile:1
# Initialize device type args
# use build args in the docker build command with --build-arg="BUILDARG=true"
ARG USE_CUDA=false
ARG USE_OLLAMA=false
ARG USE_SLIM=false
ARG USE_PERMISSION_HARDENING=false
# Tested with cu117 for CUDA 11 and cu121 for CUDA 12 (default)
ARG USE_CUDA_VER=cu128
# any sentence transformer model; models to use can be found at https://huggingface.co/models?library=sentence-transformers
# Leaderboard: https://huggingface.co/spaces/mteb/leaderboard 
# for better performance and multilangauge support use "intfloat/multilingual-e5-large" (~2.5GB) or "intfloat/multilingual-e5-base" (~1.5GB)
# IMPORTANT: If you change the embedding model (sentence-transformers/all-MiniLM-L6-v2) and vice versa, you aren't able to use RAG Chat with your previous documents loaded in the WebUI! You need to re-embed them.
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""
ARG USE_AUXILIARY_EMBEDDING_MODEL=TaylorAI/bge-micro-v2

# Tiktoken encoding name; models to use can be found at https://huggingface.co/models?library=tiktoken
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"

ARG BUILD_HASH=dev-build
# Override at your own risk - non-root configurations are untested
ARG UID=0
ARG GID=0

######## WebUI frontend ########
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build

# Set Node.js options (heap limit Allocation failed - JavaScript heap out of memory)
# ENV NODE_OPTIONS="--max-old-space-size=4096"

WORKDIR /app

COPY package.json package-lock.json ./
# onnxruntime-node otherwise assumes CUDA 12 on Linux x64 and downloads GPU
# binaries that are neither needed to build the frontend nor copied to runtime.
RUN --mount=type=cache,target=/root/.npm \
    ONNXRUNTIME_NODE_INSTALL_CUDA=skip npm ci --force

# Backend and Python metadata change independently from the frontend bundle.
COPY --exclude=backend --exclude=backend/** \
    --exclude=pyproject.toml --exclude=uv.lock . .
ARG BUILD_HASH
ARG BUILD_SOURCEMAPS=false
ENV APP_BUILD_HASH=${BUILD_HASH}
ENV BUILD_SOURCEMAPS=${BUILD_SOURCEMAPS}
# Reuse downloaded Pyodide assets across frontend source changes.
RUN --mount=type=cache,target=/root/.cache/pyodide,sharing=locked \
    mkdir -p static/pyodide && \
    cp -a /root/.cache/pyodide/. static/pyodide/ && \
    npm run build && \
    find /root/.cache/pyodide -mindepth 1 -delete && \
    cp -a static/pyodide/. /root/.cache/pyodide/

COPY ./backend /app/backend

# The backend rewrites its bundled static assets (favicons, splash, manifest,
# loader.js, ...) under open_webui/static at startup. Make that directory
# writable by an arbitrary UID -- which under OpenShift's restricted SCC is
# always a member of GID 0 -- so those writes don't fail with EACCES and crash
# the boot log with "[Errno 13] Permission denied". `chmod -R g=u` mirrors the
# owner bits onto the group (the Red Hat arbitrary-UID idiom). Do this in a
# build stage so the permission change does not duplicate the static assets in
# the final image.
ARG UID
ARG GID
RUN chown -R $UID:$GID /app/backend && \
    chgrp -R 0 /app/backend/open_webui/static && \
    chmod -R g=u /app/backend/open_webui/static

######## WebUI backend ########
FROM python:3.11-slim-bookworm AS base

# Use args
ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_CUDA_VER
ARG USE_SLIM
ARG USE_PERMISSION_HARDENING
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG USE_AUXILIARY_EMBEDDING_MODEL
ARG UID
ARG GID
ARG TARGETARCH

# Python settings
ENV PYTHONUNBUFFERED=1

## Basis ##
ENV ENV=prod \
    PORT=8080 \
    # pass build args to the build
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=${USE_CUDA} \
    USE_SLIM_DOCKER=${USE_SLIM} \
    USE_CUDA_DOCKER_VER=${USE_CUDA_VER} \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL} \
    USE_AUXILIARY_EMBEDDING_MODEL_DOCKER=${USE_AUXILIARY_EMBEDDING_MODEL}

## Basis URL Config ##
ENV OLLAMA_BASE_URL="/ollama" \
    OPENAI_API_BASE_URL=""

## API Key and Security Config ##
ENV OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false

#### Other models #########################################################
## whisper TTS model settings ##
ENV WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models"

## RAG Embedding model settings ##
ENV RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    AUXILIARY_EMBEDDING_MODEL="$USE_AUXILIARY_EMBEDDING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models"

## Tiktoken model settings ##
ENV TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken"

## Hugging Face download cache ##
ENV HF_HOME="/app/backend/data/cache/embedding/models"

## Torch Extensions ##
# ENV TORCH_EXTENSIONS_DIR="/.cache/torch_extensions"

#### Other models ##########################################################

WORKDIR /app/backend

ENV HOME=/root
# Prevent 0-byte file corruption in QEMU arm64 cross-builds.
ENV UV_LINK_MODE=copy

######## Python dependency builder ########
FROM base AS python-deps

# Isolate dependency compilation from runtime package installation.
RUN --mount=type=cache,id=apt-cache-$TARGETARCH,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential libmariadb-dev python3-dev

COPY ./backend/requirements.txt ./requirements.txt

RUN --mount=type=cache,target=/root/.cache/pip \
    --mount=type=cache,target=/root/.cache/uv \
    set -e; \
    pip3 install uv; \
    if [ "$USE_CUDA" = "true" ]; then \
    # If you use CUDA the whisper and embedding model will be downloaded on first use
    # Pin matching packages: torch 2.10.0 causes SIGILL on ARM devices, and
    # independently resolved companion packages can be ABI-incompatible. #21349
    pip3 install torch==2.9.1 torchvision==0.24.1 torchaudio==2.9.1 --index-url https://download.pytorch.org/whl/$USE_CUDA_DOCKER_VER; \
    else \
    pip3 install torch==2.9.1 torchvision==0.24.1 torchaudio==2.9.1 --index-url https://download.pytorch.org/whl/cpu; \
    fi; \
    uv pip install --system -r requirements.txt; \
    pip3 uninstall --yes uv

# Download model assets after dependency installation so later runtime changes
# do not invalidate the downloads.
RUN set -e; \
    mkdir -p /app/backend/data /root/nltk_data; \
    if [ "$USE_CUDA" = "true" ] || [ "$USE_SLIM" != "true" ]; then \
    python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')"; \
    python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ.get('AUXILIARY_EMBEDDING_MODEL', 'TaylorAI/bge-micro-v2'), device='cpu')"; \
    python -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])"; \
    python -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])"; \
    python -c "import nltk; nltk.download('punkt_tab', download_dir='/root/nltk_data')"; \
    fi; \
    chown -R $UID:$GID /app/backend/data

######## Runtime image ########
FROM base AS runtime

ARG USE_RUNTIME_BUILD_DEPS=true

# Create user and group if not root
RUN if [ $UID -ne 0 ]; then \
    if [ $GID -ne 0 ]; then \
    addgroup --gid $GID app; \
    fi; \
    adduser --uid $UID --gid $GID --home $HOME --disabled-password --no-create-home app; \
    fi

RUN mkdir -p $HOME/.cache/chroma && \
    echo -n 00000000-0000-0000-0000-000000000000 > $HOME/.cache/chroma/telemetry_user_id && \
    chown -R $UID:$GID /app $HOME

# Open WebUI installs tool dependencies at runtime, so keep the compiler and
# Python headers by default. Fixed deployments can opt out for a smaller image.
RUN --mount=type=cache,id=apt-cache-$TARGETARCH,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lists-$TARGETARCH,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    git pandoc netcat-openbsd curl jq ca-certificates \
    ffmpeg libsm6 libxext6 zstd \
    && if [ "$USE_RUNTIME_BUILD_DEPS" = "true" ]; then \
    apt-get install -y --no-install-recommends \
    build-essential libmariadb-dev python3-dev; \
    fi

# Preserve the Python installation prefix so scripts, headers, data files, and
# package RECORD paths remain consistent with runtime pip operations.
COPY --from=python-deps /usr/local /usr/local
COPY --chown=$UID:$GID --from=python-deps /app/backend/data /app/backend/data
COPY --chown=$UID:$GID --from=python-deps /root/nltk_data /root/nltk_data

# Install Ollama if requested
RUN if [ "$USE_OLLAMA" = "true" ]; then \
    date +%s > /tmp/ollama_build_hash && \
    echo "Cache broken at timestamp: `cat /tmp/ollama_build_hash`" && \
    curl -fsSL https://ollama.com/install.sh | sh && \
    rm -rf /var/lib/apt/lists/*; \
    fi

# copy embedding weight from build
# RUN mkdir -p /root/.cache/chroma/onnx_models/all-MiniLM-L6-v2
# COPY --from=build /app/onnx /root/.cache/chroma/onnx_models/all-MiniLM-L6-v2/onnx

# copy built frontend files
COPY --chown=$UID:$GID --from=build /app/build /app/build
COPY --chown=$UID:$GID --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=$UID:$GID --from=build /app/package.json /app/package.json

# copy backend files
COPY --from=build /app/backend .

# Precompile application bytecode without triggering import-time side effects.
RUN python -m compileall -q -j 0 /app/backend/open_webui && \
    find /app/backend/open_webui -type d -name __pycache__ \
    -exec chown -R "$UID:$GID" {} +

EXPOSE 8080

HEALTHCHECK CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

# Minimal, atomic permission hardening for OpenShift (arbitrary UID):
# - Group 0 owns /app and /root
# - Directories are group-writable and have SGID so new files inherit GID 0
RUN if [ "$USE_PERMISSION_HARDENING" = "true" ]; then \
    set -eux; \
    chgrp -R 0 /app /root || true; \
    chmod -R g+rwX /app /root || true; \
    find /app -type d -exec chmod g+s {} + || true; \
    find /root -type d -exec chmod g+s {} + || true; \
    fi

USER $UID:$GID

ARG BUILD_HASH
ENV WEBUI_BUILD_VERSION=${BUILD_HASH}
ENV DOCKER=true

CMD [ "bash", "start.sh"]
