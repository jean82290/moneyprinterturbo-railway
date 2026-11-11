# MoneyPrinterTurbo on Railway
#
# Builds a pinned MoneyPrinterTurbo release from source, without the files in
# the upstream repository that are not freely licensed (see
# scripts/prepare-source.sh), and puts a password-protected front door (Caddy)
# in front of the web UI and the API.
#
# To upgrade MoneyPrinterTurbo: change MPT_VERSION and MPT_COMMIT below to a
# newer release tag and its commit, then redeploy. The build stops with a clear
# message if the new release moved something this template relies on.

ARG MPT_VERSION=v1.3.10
ARG MPT_COMMIT=8b0206be2c7977e3bc3cf25ff99a2adc3c9c65f9
ARG CADDY_VERSION=2.11.7
ARG CADDY_SHA512=a7a433a1b133efc3c8d10eb0b99d52a24b5ef5c322dc77f5282182b1c0402139ab83f3a99f0c52409df77d20123fb0b523edad8a66d8f5e49136197bf61ef0e7

# ---------------------------------------------------------------------------
# fetch: download the pinned source and Caddy, then clean the source tree.
# Nothing removed here reaches the final image, not even in a hidden layer.
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS fetch
ARG MPT_VERSION
ARG MPT_COMMIT
ARG CADDY_VERSION
ARG CADDY_SHA512
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /fetch

# The archive is addressed by commit, so it cannot change under the same name.
RUN set -eu; \
    curl -fsSL --retry 3 -o source.tar.gz \
      "https://codeload.github.com/harry0703/MoneyPrinterTurbo/tar.gz/${MPT_COMMIT}"; \
    mkdir /src; \
    tar -xzf source.tar.gz -C /src --strip-components=1; \
    rm source.tar.gz; \
    grep -q "^version = \"${MPT_VERSION#v}\"" /src/pyproject.toml \
      || { echo "MPT_COMMIT is not release ${MPT_VERSION}" >&2; exit 1; }

COPY scripts/prepare-source.sh /fetch/prepare-source.sh
RUN sh /fetch/prepare-source.sh /src

RUN set -eu; \
    asset="caddy_${CADDY_VERSION}_linux_amd64.tar.gz"; \
    curl -fsSL --retry 3 -o "${asset}" \
      "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/${asset}"; \
    echo "${CADDY_SHA512}  ${asset}" | sha512sum -c -; \
    tar -xzf "${asset}" caddy LICENSE; \
    install -m 0755 caddy /caddy; \
    cp LICENSE /CADDY-LICENSE

# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------
FROM python:3.11-slim-trixie
ARG MPT_VERSION

# ffmpeg: rendering. tini: a real init as PID 1 (signals, zombie processes).
# fonts-noto-cjk: Noto Sans CJK (SIL Open Font License), the default subtitle
# font here; it covers Latin, Chinese, Japanese and Korean.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg tini fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --no-create-home --home-dir /data/.home --shell /usr/sbin/nologin mpt \
    && mkdir -p /data /app /opt/railway /usr/share/doc/caddy /usr/share/doc/moneyprinterturbo-railway

COPY --from=ghcr.io/astral-sh/uv:0.12.12 /uv /usr/local/bin/uv

# Python dependencies, exactly as locked by upstream for this release
# (uv.lock), every file checked against its SHA-256.
COPY --from=fetch /src/pyproject.toml /src/uv.lock /app/
RUN cd /app \
    && uv export --frozen --no-dev --no-emit-project --no-header -o /tmp/requirements.lock \
    && uv pip install --system --no-cache --require-hashes -r /tmp/requirements.lock \
    && rm /tmp/requirements.lock \
    && python -c "import streamlit, fastapi, moviepy, edge_tts"

COPY --from=fetch /src /app

# Put the free CJK font next to the fonts kept from upstream, under the names
# the patched defaults expect.
RUN set -eu; \
    for weight in Bold Regular; do \
      src="/usr/share/fonts/opentype/noto/NotoSansCJK-${weight}.ttc"; \
      [ -f "$src" ] || { echo "missing $src" >&2; exit 1; }; \
      cp "$src" "/app/resource/fonts/NotoSansCJK-${weight}.ttc"; \
    done; \
    cp /usr/share/doc/fonts-noto-cjk/copyright /usr/share/doc/moneyprinterturbo-railway/NotoSansCJK-copyright; \
    python -c "from PIL import ImageFont; ImageFont.truetype('/app/resource/fonts/NotoSansCJK-Bold.ttc', 60)"

COPY --from=fetch /caddy /usr/local/bin/caddy
COPY --from=fetch /CADDY-LICENSE /usr/share/doc/caddy/LICENSE
COPY NOTICE /usr/share/doc/moneyprinterturbo-railway/NOTICE
COPY licenses/ /usr/share/doc/moneyprinterturbo-railway/licenses/
COPY Caddyfile bootstrap.py entrypoint.sh selftest.py /opt/railway/
RUN chmod 0755 /opt/railway/entrypoint.sh \
    && cp /app/LICENSE /usr/share/doc/moneyprinterturbo-railway/MoneyPrinterTurbo-LICENSE \
    && python -m compileall -q /app/app /app/webui

LABEL org.opencontainers.image.title="MoneyPrinterTurbo for Railway" \
      org.opencontainers.image.description="MoneyPrinterTurbo AI short-video generator: password-protected web UI and API, packaged for Railway" \
      org.opencontainers.image.source="https://github.com/jean82290/moneyprinterturbo-railway" \
      org.opencontainers.image.licenses="MIT"

ENV PORT=8080 \
    MPT_DATA_DIR=/data \
    MPT_VERSION=${MPT_VERSION} \
    PYTHONPATH=/app \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/railway/entrypoint.sh"]
