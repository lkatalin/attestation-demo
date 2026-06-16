# Inference image: kbs-client must include az-snp-vtpm-attester for DEK fetch inside peer pods.
# Staged kbs-client-image is built without attesters (always "sample" fallback).
FROM python:3.12-slim-bookworm

ARG KBS_CLIENT_BIN=artifacts/kbs-client
ARG CDH_TOOL_BIN=artifacts/ttrpc-cdh-tool

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssl \
    xxd \
    curl \
    ca-certificates \
    libtss2-esys-3.0.2-0 \
    libtss2-tctildr0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Pre-build with: scripts/build-kbs-client.sh (from ../trustee)
COPY ${KBS_CLIENT_BIN} /usr/local/bin/kbs-client
RUN chmod +x /usr/local/bin/kbs-client && kbs-client --version 2>/dev/null || true

# Runtime DEK fetch in peer pods: CDH GetResource over unix socket (SNP attestation in guest AA).
COPY ${CDH_TOOL_BIN} /usr/local/bin/ttrpc-cdh-tool
RUN chmod +x /usr/local/bin/ttrpc-cdh-tool

COPY container/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY container/model_arch.py container/server.py ./
COPY container/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY artifacts/model.pt.enc artifacts/manifest.json /app/encrypted/
COPY artifacts/model.pt /app/plaintext/model.pt

# sandboxed-containers-operator-scc requires MustRunAsNonRoot; bake non-root USER into image metadata.
RUN groupadd -r inference -g 1001 \
    && useradd -r -u 1001 -g inference -d /app -s /usr/sbin/nologin inference \
    && chown -R inference:inference /app /entrypoint.sh

ENV PORT=8080
EXPOSE 8080
USER 1001

ENTRYPOINT ["/entrypoint.sh"]
