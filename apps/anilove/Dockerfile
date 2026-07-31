# EC2 / ECS / local image
# node:22-slim (Debian, glibc) rather than -alpine (musl): the Lambda base
# image is glibc-based, and native modules such as sharp and bcrypt ship
# different prebuilt binaries per C library. Matching libc keeps the compute
# model the only difference between platforms.
FROM node:22-slim

WORKDIR /app

COPY package*.json ./
# --omit=dev replaces the deprecated --only=production flag.
# No package-lock.json is committed, so dependency versions resolve at build
# time and can differ between builds. See docs/PAPER-SSCAD-2026.md.
RUN npm install --omit=dev

COPY . .

EXPOSE 3000

# Healthcheck used by local docker-compose (Node 18+ global fetch)
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["npm", "start"]
