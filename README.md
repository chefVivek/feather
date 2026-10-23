# atlas

Deployment and skills layer for running [Hermes Agent](https://github.com/NousResearch/hermes-agent)
as a 24x7 personal agent on a low-RAM laptop.

This is **not** another agent framework. Hermes already is one, and a good one.
This repo is the thin layer around it that Hermes deliberately leaves to you:
host preparation, cost governance, and personal skills.

---

## Why this layer exists

Hermes already ships most of what a "JARVIS-style" setup needs. Before building
anything here, these were confirmed in the upstream source and docs:

| Capability | Where it already lives upstream |
|---|---|
| Remembers your logins, fills them, generates TOTP 2FA | Credential vault (`hermes vault`) |
| Saved cards and addresses, filled at checkout | Credential vault |
| **Card fills refuse to run in headless sessions** (cron, webhook, API) | Credential vault — a prompt-injected page can ask, but cannot spend |
| Cheapest-provider routing | `provider_routing.sort: price` |
| Automatic failover on 429/5xx/auth errors | `fallback_providers` |
| Keep working until a goal is met, with quality gates | `/goal` (Ralph loop + judge model) |
| Many parallel tasks with dependencies and handoffs | Kanban board + worker lanes |
| Writes and improves its own skills | Curator + autonomous skill creation |
| Telegram / Discord / Slack / WhatsApp / Signal / email | Single gateway process |
| Scheduled natural-language tasks | Built-in cron |
| Runs on local, Docker, SSH, Modal, Daytona, Vercel Sandbox | Terminal backends |
| Network egress control | `iron-proxy`, network isolation |

**Do not reimplement any of the above.** The gap this repo fills is narrow:

1. **Host preparation for an 8 GB laptop** — swap, zram, vm tunables, lid
   behaviour, battery charge cap, inbound tunnelling. Not upstream's job.
2. **A hard spend ceiling.** Upstream has billing plumbing in its internals but
   no user-facing budget cap. On a metered API key that is a real exposure.
3. **Personal skills** — resume, job applications, media-to-spec-to-build.
4. **A cost-tiered model config** rather than one model for everything.

---

## Status

| Piece | State |
|---|---|
| `scripts/preflight.sh` | ✅ Working, tested |
| `scripts/setup-host.sh` | ✅ Working, dry-run tested |
| `config/config.lowmem.yaml` | ✅ Written, schema-validated |
| Spend cap hook | ⬜ Not started |
| Personal skills | ⬜ Not started |
| Deploy runbook | ⬜ Not started |

Caveat worth stating plainly: the scripts are syntax- and shellcheck-clean and
`preflight.sh` has been run end to end, but `setup-host.sh` has only been
exercised with `--dry-run` — this build container has no systemd, no battery and
no writable swap. Run it with `--dry-run` first on your own machine and read the
plan before applying.

---

## Usage

```bash
# 1. Will this machine hold the stack? Changes nothing.
bash scripts/preflight.sh

# 2. Review what host setup would change.
sudo bash scripts/setup-host.sh --dry-run

# 3. Apply it (prompts before touching anything).
sudo bash scripts/setup-host.sh

# 4. Confirm the warnings cleared.
bash scripts/preflight.sh

# 5. Install Hermes itself (upstream installer).
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
source ~/.bashrc
hermes setup

# 6. Apply the cost-tiered config.
hermes config set model.provider openrouter
hermes config set model.default z-ai/glm-5.2
hermes config set provider_routing.sort price
#   ...or merge config/config.lowmem.yaml into ~/.hermes/config.yaml by hand.
```

### Hardware notes

Targets a Ryzen 7 4700U / 8 GB / SSD laptop. The stack fits in roughly
**1.5 GB idle, 2.5 GB active, 5–6 GB while a build agent runs** — but only with:

- **Ubuntu Server bare-metal, not Windows + WSL2.** On 8 GB, Windows alone takes
  half the machine, and WSL does not survive lid-close reliably.
- **SQLite only.** No Postgres anywhere in the stack.
- **One concurrent browser.**
- **Swap and zram configured** — `setup-host.sh` does this. Without swap an
  8 GB host gets OOM-killed mid-build rather than merely running slowly.

Adding a single 16 GB SODIMM (most 4700U Vivobooks have one free slot — verify
your model) removes every constraint in this section.

---

## Security posture

The threat model is not hypothetical. Comparable personal-agent deployments in
2026 saw tens of thousands of internet-exposed instances, credential theft from
on-disk config, and malicious marketplace skills. An agent holding your email,
calendar and payment details is a high-value target, and **prompt injection is
structural, not a bug** — any page, email or transcript it reads can carry
instructions, and persistent memory means an injection can outlive the session.

Non-negotiables for this deployment:

- Dashboard stays bound to `127.0.0.1`. Reach it over an SSH tunnel
  (`ssh -L 9119:localhost:9119`), never `--host 0.0.0.0`.
- `~/.hermes/.env` is `0600`, `~/.hermes/vault/` is `0700`. `preflight.sh`
  checks both.
- A dedicated email address, a second phone number, and a **prepaid card with a
  low limit**. Never the primary bank account.
- Audit every third-party skill before installing. Treat skill hubs like npm.
- Keep the API server disabled unless it is genuinely needed, and never without
  `API_SERVER_KEY`.

---

## Attribution

Hermes Agent is MIT-licensed, by [Nous Research](https://github.com/NousResearch/hermes-agent).
This repo only configures and extends it.
