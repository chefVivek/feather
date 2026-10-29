# Setup

Takes about 20 minutes. Windows path first, since that is the most common
cheap-laptop case; Linux below it.

**Nothing in this document should be handed to a chat session on another
machine.** API keys go into files on your own computer, with your own hands.
No agent, local or remote, needs to see their values.

---

## Before you start

Four things, one of which costs money:

| | Where | Cost |
|---|---|---|
| OpenRouter API key | <https://openrouter.ai/keys> | **~$10 credit** |
| Telegram bot token | `@BotFather` → `/newbot` | free |
| Your Telegram user ID | `@userinfobot` → it replies with a number | free |
| A dedicated email address | anywhere | free |

The user ID is not optional. Without it, anyone who finds your bot can command
your agent.

---

## Windows (native)

No WSL, no Docker. Hermes is Tier 1 here.

### 1. Install

```powershell
iex (irm https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1)
```

No admin rights needed. Installs to `%LOCALAPPDATA%\hermes` and adds `hermes`
to your user PATH. **Open a new terminal afterwards** or the command won't
resolve.

### 2. Configure the model

```powershell
hermes setup
```

Choose OpenRouter and paste your key when prompted. Then apply cost tiering —
a cheap model handles the ~90% of calls that are routing and summarising, and
you escalate per-task for hard work:

```powershell
hermes config set model.provider openrouter
hermes config set model.default deepseek/deepseek-v4.1-flash
hermes config set provider_routing.sort price
```

Verify the model ids against your own account with `hermes model` — the
catalog is live and ids rotate.

### 3. Install the standing brief

This is what makes the agent self-sufficient rather than something you teach
task by task. Fill in the PRINCIPAL block first.

```powershell
copy bootstrap\SOUL.template.md $env:LOCALAPPDATA\hermes\SOUL.md
notepad $env:LOCALAPPDATA\hermes\SOUL.md
```

### 4. Put a ceiling on spend

```powershell
$env:OPENROUTER_API_KEY="sk-or-..."
python bin\feather-spend serve --daily 5 --monthly 50
```

Leave that running, and in another terminal point the agent at it:

```powershell
hermes config set model.base_url http://127.0.0.1:8787/v1
```

Every call now goes through the meter. At the cap the proxy returns HTTP 402
and the agent stops instead of retrying. Check spend any time with
`python bin\feather-spend status`.

### 5. Connect Telegram

```powershell
hermes gateway setup      # paste bot token + your user ID
hermes gateway install    # auto-start at logon, no admin
hermes gateway status
```

Message your bot. If it answers, you're done.

### Two caveats for an always-on Windows host

- `hermes gateway install` registers a **logon** task, not a boot service. The
  machine has to be logged in.
- Windows Update reboots on its own schedule.

Neither is fatal. A Linux box is steadier for genuine 24×7, which is what
`scripts/setup-host.sh` is for.

---

## Linux (Ubuntu/Debian)

```bash
bash scripts/preflight.sh              # read-only: will this machine hold it?
sudo bash scripts/setup-host.sh --dry-run
sudo bash scripts/setup-host.sh        # swap, zram, lid, battery cap
bash scripts/preflight.sh              # confirm warnings cleared

curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
source ~/.bashrc && hermes setup

cp bootstrap/SOUL.template.md ~/.hermes/SOUL.md && "${EDITOR:-nano}" ~/.hermes/SOUL.md

export OPENROUTER_API_KEY=sk-or-...
bin/feather-spend serve --daily 5 --monthly 50 &
hermes config set model.base_url http://127.0.0.1:8787/v1

hermes gateway setup && hermes gateway install
```

On Linux the gateway is a systemd service, so it survives reboots without a
login. That is the main reason to prefer it for an always-on host.

---

## Then: don't teach it, use it

Resist the urge to pre-write skills. Hermes has a curator that writes and
refines its own skills from work that actually succeeded, and a skill written
from imagination is usually wrong in ways you only discover later.

Give it real work and watch where it struggles:

```
Find 10 backend jobs posted this week that match my background,
and send me the three best with a tailored CV for each.
```

```
Read this video and build what it describes. Ask me only if you
hit something you genuinely cannot resolve: <url>
```

```
Every weekday at 08:00, check my calendar and inbox and send me a
short brief on Telegram.
```

Then intervene **only where it repeatedly fails.** That is the difference
between a system that improves and one you maintain forever.

---

## If something breaks

```
hermes doctor          # diagnoses most install and config problems
hermes gateway status  # is the gateway actually running?
hermes pm doctor       # managed dependency problems
```

Spend not adding up? `feather-spend status` reports **unpriced** calls
separately — those are calls where the provider returned no cost and the model
wasn't in the price table, recorded as `$0`. If that count is non-zero, your
real spend is higher than the tally shows.
