# syntax=docker/dockerfile:1

FROM python:3.13-slim AS base
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/.venv/bin:$PATH"
WORKDIR /app


# --- dependency layer ------------------------------------------------------
FROM base AS deps
COPY --from=ghcr.io/astral-sh/uv:0.7.13 /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv

COPY pyproject.toml uv.lock ./
# Project code is not installed — it is copied in below / bind-mounted in dev,
# so editing a file never invalidates this cached layer.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev


# --- runtime (no dev deps) -------------------------------------------------
FROM base AS runtime
RUN groupadd --gid 1000 enka \
    && useradd --uid 1000 --gid 1000 --create-home enka \
    && mkdir -p /data/audio \
    && chown -R enka:enka /data

COPY --from=deps --chown=enka:enka /app/.venv /app/.venv
COPY --chown=enka:enka . /app

RUN chmod +x /app/docker-entrypoint.sh
USER enka
EXPOSE 8000
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]


# --- dev (adds pytest/ruff; used by docker-compose.override.yml) -----------
FROM runtime AS dev
USER root
COPY --from=ghcr.io/astral-sh/uv:0.7.13 /uv /usr/local/bin/uv
ENV UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --extra dev \
    && chown -R enka:enka /app/.venv
USER enka
