# Microsoft DirectXShaderCompiler (Linux DXC) — canonical HLSL compile-verify for
# zioshade's `just hlsl-dxc` gate (M5.3). Built once; `tools/dxc` runs it per shader.
# Pinned to a specific release for reproducibility (bump DXC_URL to upgrade).
# linux/amd64 is required: DXC ships only an x86-64 Linux binary, so on Apple Silicon
# the container runs under Rosetta (fine for a compile gate, not latency-critical).
FROM --platform=linux/amd64 ubuntu:24.04
ARG DXC_URL=https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2602.24/linux_dxc_2026_05_26.x86_64.tar.gz
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget \
 && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/dxc \
 && wget -qO /tmp/dxc.tar.gz "$DXC_URL" \
 && tar xzf /tmp/dxc.tar.gz -C /opt/dxc \
 && rm /tmp/dxc.tar.gz
ENV LD_LIBRARY_PATH=/opt/dxc/lib
ENTRYPOINT ["/opt/dxc/bin/dxc"]
