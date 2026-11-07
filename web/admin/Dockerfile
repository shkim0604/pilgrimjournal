# Pilgrim admin console. Build context is the repository root:
#   docker compose -f web/admin/docker-compose.yml up -d --build
FROM node:24-alpine

WORKDIR /app/web/admin
COPY web/admin/package.json web/admin/package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY web/admin/src ./src
COPY web/admin/public ./public
COPY web/admin/snapshot ./snapshot
# Tracking docs read by the dashboard, and the support page served at /.
COPY docs/*.md /app/docs/
COPY site/index.html /app/site/index.html

ENV NODE_ENV=production \
    ADMIN_REPO_ROOT=/app \
    ADMIN_DB_PATH=/data/admin.sqlite \
    PORT=8420

RUN mkdir -p /data && chown node:node /data
USER node
VOLUME ["/data"]
EXPOSE 8420

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD wget -qO- http://127.0.0.1:8420/healthz || exit 1

CMD ["node", "--disable-warning=ExperimentalWarning", "src/main.ts"]
