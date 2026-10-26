# Build from the repo root after tools/export.sh web. Compression happens once at image build
# time, never on the 2-vCPU AgentBox. Source assets, saves and keys never enter the image.
FROM alpine:3.20 AS compress

RUN apk add --no-cache brotli gzip
COPY build/web/ /site/
# Any sidecars from a previous run are stale; rebuild them from the export being shipped.
RUN find /site \( -name '*.gz' -o -name '*.br' \) -delete
# The .pck and .wasm are the two big payloads; the loader and manifest ride along for free.
RUN find /site -type f \( -name '*.wasm' -o -name '*.pck' -o -name '*.js' -o -name '*.html' \
		-o -name '*.json' \) -exec sh -c 'brotli -q 11 -k "$1" && gzip -9 -k "$1"' _ {} \;

FROM caddy:2-alpine

COPY deploy/web/Caddyfile /etc/caddy/Caddyfile
COPY --from=compress /site/ /srv/

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
	CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
