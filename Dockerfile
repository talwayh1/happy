# Standalone happy-server: single container, no external dependencies
# Uses PGlite (embedded Postgres), local filesystem storage, no Redis

# Stage 1: install dependencies
FROM node:20 AS deps

RUN apt-get update && apt-get install -y python3 make g++ build-essential && rm -rf /var/lib/apt/lists/*
RUN corepack enable && corepack prepare pnpm@10.11.0 --activate

WORKDIR /repo

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY scripts ./scripts
COPY patches ./patches

RUN mkdir -p packages/happy-app packages/happy-server packages/happy-cli packages/happy-agent packages/happy-wire

COPY packages/happy-app/package.json packages/happy-app/
COPY packages/happy-server/package.json packages/happy-server/
COPY packages/happy-cli/package.json packages/happy-cli/
COPY packages/happy-agent/package.json packages/happy-agent/
COPY packages/happy-wire/package.json packages/happy-wire/

# Workspace postinstall requirements
COPY packages/happy-app/patches packages/happy-app/patches
COPY packages/happy-server/prisma packages/happy-server/prisma
COPY packages/happy-cli/scripts packages/happy-cli/scripts
COPY packages/happy-cli/tools packages/happy-cli/tools

RUN SKIP_HAPPY_WIRE_BUILD=1 pnpm install

# Stage 2: copy source and type-check
FROM deps AS builder

COPY packages/happy-wire ./packages/happy-wire
COPY packages/happy-server ./packages/happy-server

RUN pnpm --filter @slopus/happy-wire build
RUN pnpm --filter happy-server build && cd packages/happy-server && npx prisma generate
# Save generated Prisma client so runner doesn't need 67 MB prisma CLI
# pnpm may hoist .prisma to root node_modules; -L dereferences any symlinks
RUN cp -rL node_modules/.prisma /tmp/prisma-client 2>/dev/null || \
    cp -rL packages/happy-server/node_modules/.prisma /tmp/prisma-client

# Stage 3: runtime — uses pnpm deploy for clean production deps
FROM node:20-slim AS runner

WORKDIR /repo

# Only curl needed at runtime (ffmpeg removed — 0 references in source, saves 637 MB)
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production
ENV DATA_DIR=/data
ENV PGLITE_DIR=/data/pglite

# Copy workspace metadata + built packages (needed by pnpm deploy)
COPY --from=builder /repo/package.json /repo/pnpm-lock.yaml /repo/pnpm-workspace.yaml /repo/.npmrc /repo/
COPY --from=builder /repo/packages/happy-wire /repo/packages/happy-wire
COPY --from=builder /repo/packages/happy-server /repo/packages/happy-server

# pnpm deploy creates a standalone directory with production deps only (~5-10s)
# rm prisma CLI: @prisma/client's optional dep pulls it in despite being in devDeps
RUN corepack enable && corepack prepare pnpm@10.11.0 --activate \
    && pnpm --filter happy-server deploy --legacy --prod --ignore-scripts /app \
    && rm -rf /app/node_modules/prisma

# Restore pre-generated Prisma client from builder (avoids 67 MB prisma CLI at runtime)
COPY --from=builder /tmp/prisma-client /app/node_modules/.prisma

VOLUME /data
EXPOSE 3005

WORKDIR /app

CMD ["sh", "-c", "./node_modules/.bin/tsx sources/standalone.ts migrate && exec ./node_modules/.bin/tsx sources/standalone.ts serve"]
