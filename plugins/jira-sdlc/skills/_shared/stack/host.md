<!-- Adapted from ControlFreak (controlfreak@7af306f: plugins/controlfreak/skills/space-init/instances/host.md). Owned here. -->

# Host prerequisites

What a repo's instances may need on the machine, how to **check** each
(read-only, no `sudo`), and the **recipe** the human runs when it's
missing. Linux (Ubuntu) first.

**Installing is the human's.** `jst-stack` and the stack only check: each
prerequisite goes into `stack.d/README.md`'s "Host prerequisites" and into the
stack's first step, "Check the host" (in `bootstrap` and `start`), which prints
`NOT DONE: <what>: <recipe>` for a missing one and fails the step before anything
starts; the trial names that step. Never run `sudo`, `apt`, `curl … | sh` or a global
`npm install -g` yourself.

## The table

| What | Check | Recipe (the human) |
| -- | -- | -- |
| git, curl, jq, build tools | `git --version`, `curl --version`, `jq --version`, `cc --version` | `sudo apt-get install -y git curl jq build-essential` |
| Docker Engine + Compose, usable without sudo | `docker info --format '{{.ServerVersion}}'`, `docker compose version` | Docker's apt repository (docs.docker.com → Install Docker Engine on Ubuntu), then `sudo usermod -aG docker "$USER"` and log in again |
| The host reaches Docker bridge networks (an instance on its own subnet) | `ip route` lists the bridge's subnet once a network exists | Linux does this by default. Docker Desktop (macOS, Windows) does not: use published ports instead of a subnet |
| Postgres client tools (optional) | `psql --version`, `pg_dump --version` | `sudo apt-get install -y postgresql-client`; or run them in the database container (`docker exec … pg_dump`), which needs nothing on the host |
| Node + Yarn through fnm | `$HOME/.local/share/fnm/aliases/default/bin/node --version`, same for `yarn` | `curl -fsSL https://fnm.vercel.app/install \| bash`, a new shell, `fnm install <version> && fnm default <version>`, `npm install -g yarn@1.22.22` |
| Python through uv | `$HOME/.local/bin/uv --version`, `uv python find <version>` | `curl -LsSf https://astral.sh/uv/install.sh \| sh`, `uv python install <version>` |
| NVIDIA driver | `nvidia-smi` | `sudo ubuntu-drivers install`, reboot |
| GPU inside Docker | `docker info --format '{{json .Runtimes}}'` lists `nvidia` | NVIDIA Container Toolkit's apt repository, `sudo apt-get install -y nvidia-container-toolkit`, `sudo nvidia-ctk runtime configure --runtime=docker`, `sudo systemctl restart docker` |
| Local TLS (an instance served over HTTPS) | `mkcert -CAROOT` and the CA file in it exists | `sudo apt-get install -y mkcert libnss3-tools`, then `mkcert -install` once (restart the browser) |
| A port is free | `ss -ltnH "sport = :<port>"` prints nothing | stop what holds it, or move the stack's port block (`stack.d/resources.conf`) |

Versions come from the repo: `.nvmrc`, `.node-version`, `engines` in
`package.json`, `.python-version`, `requires-python` in `pyproject.toml`.
Write the version the repo asks for, not the newest.

## Notes

- **Tools outside the default `PATH`**: a caller (the web app, a sandbox) may run `./stack`
  with a small `PATH`.
  Name fnm's and uv's directories in `./stack` (`NODE_BIN`, `UV`), with an override
  variable (`NODE_BIN`), as the example does.
- **Shared services are not prerequisites**: a broker or GPU service the
  main checkout runs is checked by the stack's `start` and started by the human
  in the main checkout (`spec.md`, "Shared services").
- **Downloads at up time** (weights, images): prefer the main checkout's
  copy (hard links on the same file system: `cp -al`, `ln`) or a shared
  cache (the Hugging Face cache, uv's cache). Pull Docker images once
  during the trial, not on every up.
