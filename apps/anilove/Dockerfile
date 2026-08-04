# EC2 / ECS / local image
# node:22-slim (Debian, glibc) rather than -alpine (musl): the Lambda base
# image is glibc-based, and native modules such as sharp and bcrypt ship
# different prebuilt binaries per C library. Matching libc keeps the compute
# model the only difference between platforms.
# Pinned by digest: node:22-slim is a moving tag. Resolve a new one with
#   docker buildx imagetools inspect node:22-slim --format '{{.Manifest.Digest}}'
FROM node:22-slim@sha256:f32b81066cde10a75dbac96646099533316d94bac4150c55da1636e1f0ffdc46

WORKDIR /app

COPY package*.json ./
# npm ci: installs exactly the locked tree and fails if it disagrees with
# package.json. --omit=dev replaces the deprecated --only=production.
RUN npm ci --omit=dev

COPY . .

EXPOSE 3000

# Healthcheck used by local docker-compose (Node 18+ global fetch)
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["npm", "start"]
