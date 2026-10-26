# GridFall web demo: nginx serving the Godot web export, sized for the GMI AgentBox CE container
# tier (2 vCPU, 4 GiB RAM, 10 GiB ephemeral). Build from the repo root after `tools/export.sh web`:
#
#   docker build -t gridfall-web -f deploy/web/Dockerfile .
#
# The root .dockerignore keeps the build context to build/web/ and this config. Stage 1 gzips
# the engine files once so the 2-vCPU box never compresses the ~half-gigabyte .pck per visitor;
# nginx's gzip_static (a core feature, no modules) serves those copies to browsers that accept
# gzip, which is all of them. Brotli would save only a few more percent and needs a non-core
# module, so it is left out.

# --- stage 1: precompress ---------------------------------------------------------
FROM alpine:3.20 AS compress

RUN apk add --no-cache gzip
COPY build/web/ /site/
RUN find /site -type f \( -name '*.wasm' -o -name '*.pck' -o -name '*.js' -o -name '*.html' \) \
	-exec gzip -9 -k {} \;

# --- stage 2: the server -----------------------------------------------------------
FROM nginx:stable-alpine

COPY deploy/web/nginx.conf /etc/nginx/conf.d/gridfall.conf
RUN rm -f /etc/nginx/conf.d/default.conf
COPY --from=compress /site/ /usr/share/nginx/html/

EXPOSE 8080
# The AgentBox gateway health-checks the port; check it locally too.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
	CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
