# monthly-render-farm

Generic parallel batch render farm: GitHub Actions runners pull each item's
inputs from a **private** Azure Files share, process it, and push the result back.

This repository intentionally contains **no application logic, no data and no
secrets**. The render scripts, media and credentials all live on the private
share and are fetched at runtime. The only secret is `AZURE_SAS`, a scoped,
time-limited SAS token stored as a GitHub Actions secret.

## Run

Actions → **Monthly Render Farm** → *Run workflow*

| Input | Meaning |
|---|---|
| `job_id` | Batch folder on the share, e.g. `August_2026` |
| `only` | Optional filter, e.g. `Marathi` or `Marathi/Aries`. Blank = whole manifest |
| `upload` | Publish to YouTube after rendering |
| `privacy` | `private` / `unlisted` / `public` |

Outputs land on the share under `<job_id>/outputs/<Language>/`.
