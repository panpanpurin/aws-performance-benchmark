# Shared benchmark scripts

| Script | Purpose |
|--------|---------|
| `run-parallel.sh` | Bash: EC2 + ECS + Lambda Artillery for one suite |
| `run-parallel.ps1` | PowerShell: same |

```bash
./run-parallel.sh anilove
./run-parallel.sh csv-processor
./run-parallel.sh thumbnail-generator
```

```powershell
.\run-parallel.ps1 -Suite anilove
```

Or from repo root: `make artillery-anilove` (and csv / thumbnail).

Thin wrappers under each suite `artillery/` call these scripts so local discovery stays easy.
