# Account Safety — Staying on the Right Side of the Subscription Rules

Why this doc exists: this stack runs entirely on subscription auth
(Claude Max, ChatGPT Plus), and in early 2026 Anthropic went from
"gray area" to active enforcement against subscription tokens in
third-party tools. This project's architecture was designed on the
safe side of that line before the crackdown — this doc records
where the line actually is, why this stack is on the right side of
it, and the habits that keep it that way.

Written from the then-current policy state. Policies
move; the authoritative source is Anthropic's own legal-and-
compliance page in the Claude Code docs — re-check it before
changing anything auth-related.

## 1. The hard rule (Anthropic, as of Feb 2026)

OAuth tokens obtained through Claude Free, Pro, or Max accounts
are licensed for **Claude Code and Claude.ai only**. Using them in
ANY other product, tool, or service — explicitly including
Anthropic's own Agent SDK — violates the Consumer Terms of
Service.

This is enforced, not theoretical. Timeline: blocking of Max OAuth
in third-party clients began January 9, 2026; the docs were
updated to state the rule explicitly February 19; server-side
blocks rolled out through February–March; full enforcement April
4. Tools like OpenClaw and OpenCode that let users paste a
subscription token were the targets. Also prohibited: any third
party offering Claude.ai login or proxying requests through
Free/Pro/Max credentials.

The subscription terms also use "ordinary, individual usage"
language — flat-rate pricing assumes a human using it like a
human. Anthropic's stated objection to third-party harnesses is
that they generate unusual traffic patterns without the telemetry
the official Claude Code harness provides.

**The OpenAI side is currently the opposite:** OpenAI permits
Codex subscription use inside third-party clients. Don't assume
the two providers' rules are symmetric, in either direction — and
don't assume OpenAI's permissiveness is permanent.

## 2. Why THIS stack is on the right side of the line

The critical distinction: **Hermes never authenticates as Claude
or GPT.** What the banned tools did was take the OAuth token and
speak to the API directly with it — impersonating Claude Code.
What this stack does is shell out to the **official CLI binaries**,
which handle their own auth exactly as licensed:

- Hermes's brain is a local Ollama model — no Anthropic/OpenAI
  auth involved at all.
- Delegation runs `claude -p "..."` — the real Claude Code, using
  its own credential from the mounted `claude-home`. The harness
  IS Claude Code. Same for `codex exec` on the Codex side.
- The credential mounts expose tokens only to containers whose
  purpose is running those official CLIs — never into Hermes's
  own config, never as an env var Hermes could consume.
- One human, one account, one machine, personal use.

This is why the architecture ruled out "Hermes powered by the
Claude subscription directly" early (features.md, Resolved): that
would have been exactly the banned pattern.

## 3. Rules to keep it that way

1. **Never paste the OAuth token (or `claude setup-token` output)
   into any third-party tool's config** — not Hermes's
   config.yaml, not Open WebUI, not any "bring your own key" box
   in anything that isn't Claude Code itself. If a future tool's
   setup wizard asks for it (some literally prompt for it and
   appear to work), that's the tool inviting a ToS violation, not
   permission.
2. **The Agent SDK needs an API key.** If a future feature ever
   builds on Anthropic's Agent SDK, that's API-key territory by
   explicit rule — subscription auth is not permitted there even
   though it's Anthropic's own SDK.
3. **Keep delegation human-shaped.** One person asking for tasks
   conversationally is ordinary individual usage. Unattended
   loops hammering delegations all night, parallel fan-out
   automation, or retry storms are the "unusual traffic" pattern
   enforcement is aimed at. If a workload wants to run like a
   service, that's what API keys are for.
4. **VPS = API keys, never subscription credentials.** Already
   pre-decided in this project's VPS plan, and the 2026 crackdown
   validates it hard: subscription sessions from a datacenter IP
   running automated workloads is the exact profile that gets
   flagged. A remote box holds a revocable, spend-capped key.
5. **Don't share, resell, or multi-user the account.** The
   credential files in `~/.secrets` are portable backups for YOUR
   rebuilds — not something to hand to another person or machine
   acting as a different user.
6. **Keep `ANTHROPIC_API_KEY` out of the environment** unless
   deliberately switching to metered billing — it silently
   overrides the subscription (authentication.md), which is a
   billing surprise rather than a ban risk, but the same
   discipline covers both.
7. **Re-check the policy before adopting any new tool** from the
   alternatives list (features.md) — several of them (OpenCode,
   OpenClaw-alikes) are exactly the category the Anthropic
   enforcement targeted. A tool being popular, open-source, or
   having a config slot for a Claude token is not evidence it's
   permitted.

## 4. What enforcement looks like, if it ever hits

Reported experience from affected users: auth errors and rejected
tokens **in the third-party context only** — the official Claude
Code CLI and Claude.ai kept working on the same account. Blocks
arrived as warnings rather than instant account deletion. So the
blast radius of a mistake is likely a blocked integration, not a
lost account — but "likely" is carrying weight in that sentence;
Anthropic reserves the right to act without notice, and this
stack's answer is simply to never be in that category.

## 5. One-line summary

Local model thinks for free; frontier models are only ever
invoked as their own official CLIs, at human pace, on one
person's machine — and anything that stops looking like that
(remote, unattended, high-volume, third-party-authenticated)
switches to API keys first.
