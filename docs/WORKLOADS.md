# Workload characteristics

How each application stresses the platform. Labels are **dominant** limits, not exclusive ones. Real systems mix CPU, memory, and I/O.

| App | Primary bound | Secondary | Role in the comparison |
|-----|---------------|-----------|------------------------|
| **AniLove** | I/O / database | Network; light CPU | Thin API + Postgres baseline |
| **CSV Processor** | CPU + memory | Upload I/O on large files | Data processing under load |
| **Thumbnail Generator** | CPU + memory peaks | Upload size / decode | Media and image processing |

## AniLove (`apps/anilove`)

**I/O and database bound (latency bound API).**

- Express CRUD with Sequelize against PostgreSQL / RDS
- Most request time waits on the database and network
- Application CPU is light (JSON, bcrypt on auth paths)
- Not a heavy compute loop

**Useful for:** request latency, connection pools, RDS under load, cold start vs warm for a thin API.

**Not ideal for:** pure CPU or pure RAM comparison.

Metrics separate total time from app internal time (DB timing via Sequelize `benchmark`).

## CSV Processor (`apps/csv-processor`)

**CPU bound with memory pressure.**

- Pandas: parse CSV, filter, groupby, aggregate
- **CPU:** parse and aggregation
- **Memory:** DataFrame(s) in process; concurrent `/process` increases RAM use
- BLAS threads pinned to 1 (`OMP_NUM_THREADS` / `OPENBLAS_NUM_THREADS`) for fair 1 vCPU comparison

**On small instances (about 1 GiB):**

- Low concurrency or small files: often **CPU bound**
- Higher concurrency or large CSVs: can become **memory bound** (pressure, thrashing, or OOM)

## Thumbnail Generator (`apps/thumbnail-generator`)

**CPU bound media work with short memory peaks.**

- Sharp: decode, resize, encode
- **CPU:** native image pipeline
- **Memory:** input buffer and working set; peaks track image size and concurrent uploads
- Sharp concurrency set to 1 for fair 1 vCPU comparison

Heavier CPU than AniLove. Usually less bulk RAM than a large pandas job unless images are large or many requests run together.

## Summary

| Workload | Summary |
|----------|---------|
| **AniLove** | I/O and database bound API |
| **CSV** | CPU and memory bound data processing |
| **Thumbnail** | CPU bound media processing (short memory peaks) |

No app is purely memory bound without CPU. **CSV** is most likely to hit **RAM** limits. **Thumbnail** is the clearest **CPU** media case. **AniLove** is the non compute / DB baseline.

## Related

- Applications: [apps/](../apps/)
- Deploy and env: [DEPLOY.md](./DEPLOY.md)
- Infrastructure: [INFRASTRUCTURE.md](./INFRASTRUCTURE.md)
- Parallel load tests: [PARALLEL-BENCHMARK.md](./PARALLEL-BENCHMARK.md)
