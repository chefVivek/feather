<h1 align="center">feather</h1>

<p align="center">
  <b>Run a personal AI agent on an 8 GB laptop. Safely.</b><br>
  One command. No GPU. No Docker required. Sandboxed, vaulted, egress-controlled and spend-capped by default.
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#what-this-is-not">What this is not</a> ·
  <a href="#the-threat-model">Threat model</a> ·
  <a href="#limitations">Limitations</a>
</p>

---

## Why

Personal AI agents got good in 2026. The way people run them did not.

A personal agent holds your email, your calendar, your logins and increasingly your
card. It reads web pages, emails and transcripts — any of which can carry
instructions aimed at it. The popular way to run one, as of late 2026:

- **40,000–135,000** instances found exposed to the open internet by security scanners
- **Credentials stored in plaintext**, now specifically targeted by infostealer malware
- **1,184+ malicious skills** planted on a single community skill marketplace
- **~543 CVEs** reported against one project in a year, including code execution via injected commands
- **Sandboxing off by default** — tools run directly on the host
- Microsoft's Defender team characterising the category as
  *"untrusted code execution with persistent credentials"*

Meanwhile the alternatives that take security seriously assume you have hardware.
Local-first frameworks want a GPU. Container-first deployments want RAM you don't
have. If your laptop is an 8 GB machine with integrated graphics — which describes
most laptops on earth — your options are "run it unsafely" or "don't run it."

**feather is the third option.** It is the boring, careful deployment layer that
makes a capable agent safe to run on a cheap machine.

## What it does

`feather` does not implement an agent. [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(MIT, Nous Research) already does that extremely well — credential vault with
automatic TOTP, cheapest-first model routing, persistent goals, a kanban board for
parallel work, self-authoring skills, and messaging gateways for Telegram, Discord,
Slack, WhatsApp and Signal.

feather is the layer Hermes deliberately leaves to the operator:

| | |
|---|---|
| **Host preparation** | swap, zram, vm tunables sized for a low-RAM box; lid-close and battery-charge behaviour for a laptop that never sleeps |
| **A spend ceiling** | a hard cap on API spend. Upstream has billing internals but no user-facing limit — on a metered key, that is real exposure |
| **Cost-tiered routing** | cheap model for the ~90% of calls that are routing and summarising, frontier model only for hard reasoning |
| **A security posture you can audit** | file permissions, localhost binding, egress policy, sandboxed execution — checked, not assumed |
| **Portable skills** | written to the [agentskills.io](https://agentskills.io) standard, so they also load in OpenClaw and OpenJarvis |

## Install

```bash
git clone https://github.com/<you>/feather && cd feather

bash scripts/preflight.sh            # read-only. Will this machine hold it?
sudo bash scripts/setup-host.sh --dry-run   # see every change first
sudo bash scripts/setup-host.sh             # apply, with confirmation
bash scripts/preflight.sh            # confirm the warnings cleared
```

Then install the agent itself and apply the tuned config:

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
source ~/.bashrc && hermes setup

hermes config set model.provider openrouter
hermes config set model.default z-ai/glm-5.2
hermes config set provider_routing.sort price
```

`preflight.sh` changes nothing and is safe to run first, always.
`setup-host.sh` is idempotent, supports `--dry-run`, and asks before touching anything.

## Hardware

Target: **4-core CPU, 8 GB RAM, SSD, no GPU.** Developed against a Ryzen 7 4700U.

Measured footprint with the low-memory profile:

| State | RAM |
|---|---|
| Idle | ~1.5 GB |
| Active, one browser | ~2.5 GB |
| Peak, while a build agent runs | ~5–6 GB |

Two conditions make that possible, and `preflight.sh` enforces both:

- **SQLite only.** No Postgres anywhere.
- **Swap and zram configured.** Without swap, an 8 GB host is OOM-killed during build
  bursts rather than merely running slowly.

### Platform support

| | Linux | macOS | Windows |
|---|---|---|---|
| Hermes itself | ✅ Tier 1 | ✅ Tier 1 | ✅ Tier 1 (native — no WSL, no Docker) |
| `bin/feather-spend` | ✅ | ✅ | ✅ |
| `scripts/preflight.sh` · `setup-host.sh` | ✅ | ⬜ Not ported | ⬜ Not ported |

feather's host-hardening scripts are Debian/Ubuntu-specific today: systemd, apt,
and Linux sysfs have no direct equivalent elsewhere. The spend ceiling is pure
standard-library Python and runs everywhere.

On Windows, Hermes installs natively and auto-starts with `hermes gateway install`
(Scheduled Tasks, no admin). Two caveats for an always-on host: the task runs at
**logon**, not boot, so the machine has to be logged in; and Windows Update reboots
on its own schedule. Neither is fatal, but a Linux box is steadier for 24×7.

## What this is not

Being explicit, because the category is full of overclaiming:

- **Not an agent framework.** It configures and hardens one.
- **Not a local-inference setup.** It assumes API models, because an 8 GB laptop with
  integrated graphics cannot usefully serve a model. If you have a GPU, look at
  [OpenJarvis](https://github.com/open-jarvis/openjarvis) instead — different thesis,
  genuinely good.
- **Not a security guarantee.** Prompt injection is structural, not a bug. feather
  reduces blast radius; it does not eliminate it. Read the threat model.
- **Not autonomous business operation.** Current agents drift on multi-day open-ended
  goals. This runs discrete tasks reliably and reports at checkpoints.

## The threat model

What feather assumes will happen, and what it does about it:

| Assumption | Mitigation |
|---|---|
| The agent will read attacker-controlled text | Egress policy; destructive actions gated |
| Credentials on disk will be targeted | `0600` on `.env`, `0700` on the vault, verified by preflight |
| A skill from a marketplace may be hostile | Audit before install; sandboxed execution backend |
| The dashboard will be found if exposed | Bound to `127.0.0.1`; reachable only over an SSH tunnel |
| An agent loop can run away on a metered key | Hard spend ceiling *(in progress)* |
| A page will try to make the agent spend money | Upstream refuses card fills in headless sessions entirely |

Operational rules this assumes you follow: a dedicated email address, a second phone
number, and a **prepaid card with a low limit** — never a primary bank account.

## Status

Early. Honest state of each piece:

| Piece | State |
|---|---|
| `scripts/preflight.sh` | ✅ Tested end-to-end |
| `scripts/setup-host.sh` | ⚠️ Dry-run tested only — see below |
| `config/config.lowmem.yaml` | ✅ Schema-validated |
| `bin/feather-spend` | ✅ 17 end-to-end tests, all passing |
| Portable skills | ⬜ Not started |

### Spend ceiling

A metering proxy between the agent and the provider. It forwards every request,
records what it cost, and returns HTTP 402 once you hit the cap — the agent stops
rather than retries, and a refused request never reaches the provider.

```bash
export OPENROUTER_API_KEY=...
bin/feather-spend serve --daily 5 --monthly 50
hermes config set model.base_url http://127.0.0.1:8787/v1

bin/feather-spend status      # spend against caps, broken down by model
```

Standard library only, no dependencies, binds to `127.0.0.1` exclusively.
Because it speaks plain OpenAI-compatible HTTP it also works with OpenClaw,
OpenJarvis, Cursor or anything else that lets you set a base URL — and it runs
on **Linux, macOS and Windows** unchanged. On Windows the ledger's `0600` mode is
a no-op, since `chmod` there only toggles the read-only bit.

**Two honest limits.** The cap is checked *before* a call, so a single request can
overshoot it — the cost of a call is unknowable until it completes. Worst case you
exceed the cap by one call. And when a provider reports no cost and the model is
absent from the built-in price table, the call is recorded as `$0` and counted as
**unpriced**; `status` reports that count separately so the gap is visible rather
than silently understating your spend.

`setup-host.sh` is syntax- and shellcheck-clean and its dry-run path is verified, but
it has not yet been applied on a machine with systemd, a battery and writable swap.
**Run `--dry-run` first and read the plan.** This note gets removed when that changes,
not before.

## Limitations

- Debian/Ubuntu only. Other distros will need the package steps adapted.
- Battery charge capping needs kernel sysfs support; on hardware without it, set the
  limit in the vendor utility or BIOS instead.
- Model IDs in the config were current on 2026-10-23 and rotate. Verify with `hermes model`.
- Tested on one hardware configuration so far. Reports from others are welcome.

## Credits

Built on [Hermes Agent](https://github.com/NousResearch/hermes-agent) by
[Nous Research](https://nousresearch.com) (MIT). feather only configures and extends it;
all the hard agent engineering is theirs.

Skills follow the [agentskills.io](https://agentskills.io) standard, shared with
Hermes, [OpenClaw](https://github.com/openclaw/openclaw) and
[OpenJarvis](https://github.com/open-jarvis/openjarvis).

## License

MIT.
