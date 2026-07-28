# Thumbnail Generator API

Node.js + Express + Sharp API that resizes uploaded images.

**One codebase** for **EC2**, **ECS**, and **AWS Lambda**.

**Workload profile:** CPU-bound media processing with short memory peaks (Sharp). See [docs/WORKLOADS.md](../../docs/WORKLOADS.md).

---

## Features

- `POST /thumbnail`: upload image, return resized image
- Formats: jpeg, png, webp
- Query params: `width`, `height`, `format`, `quality`
- Prometheus metrics (total + Sharp internal + CPU/RAM; cold start on Lambda)

Total execution is measured **after** multer parses the body so EC2/ECS and Lambda Function URL compare the same phase.

---

## Project layout

```text
apps/thumbnail-generator/
├── src/
│   ├── app.js
│   ├── metrics.js
│   ├── controllers/
│   ├── middlewares/
│   └── routes/
├── server.js            # EC2 / ECS
├── index.js             # Lambda handler
├── Dockerfile
└── Dockerfile.lambda
```

Benchmarks: [`benchmarks/suites/thumbnail-generator`](../../benchmarks/suites/thumbnail-generator). Deploy: [`docs/DEPLOY.md`](../../docs/DEPLOY.md).

---

## Local

```bash
npm install
npm start
# default port 3001
```

---

## Docker: EC2 / ECS

```bash
# from repo root
docker build -t thumbnail-generator:ec2-ecs -f apps/thumbnail-generator/Dockerfile apps/thumbnail-generator
docker run -d -p 3001:3001 thumbnail-generator:ec2-ecs
```

## Docker: Lambda

```bash
docker build -t thumbnail-generator:lambda -f apps/thumbnail-generator/Dockerfile.lambda apps/thumbnail-generator
# Handler: index.handler
```

---

## API

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/thumbnail?width=200&height=200&format=jpeg&quality=80` | Multipart field `image` |
| `GET` | `/health` | Health |
| `GET` | `/metrics` | Prometheus |

Sharp cache is disabled and concurrency is set to `1` for fair 1-vCPU comparison.
