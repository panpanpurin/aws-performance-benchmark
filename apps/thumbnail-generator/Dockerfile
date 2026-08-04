# EC2 / ECS image
# node:22-slim (Debian, glibc) rather than -alpine (musl): the Lambda base
# image is glibc-based, and native modules such as sharp and bcrypt ship
# different prebuilt binaries per C library. Matching libc keeps the compute
# model the only difference between platforms.
# Pinned by digest. Matters most here: sharp is this workload's cost and ships
# prebuilt native binaries.
FROM node:22-slim@sha256:f32b81066cde10a75dbac96646099533316d94bac4150c55da1636e1f0ffdc46

WORKDIR /app

COPY package*.json ./
# npm ci: pins the sharp version to the locked tree.
RUN npm ci --omit=dev

COPY . .

EXPOSE 3001

# Matches the healthcheck in apps/anilove/Dockerfile; used by local compose.
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:3001/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["npm", "start"]
