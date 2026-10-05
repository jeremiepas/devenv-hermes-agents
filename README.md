# devenv-hermes-agents

A collection of specialized [Hermes Agent](https://github.com/NousResearch/hermes-agent)
profiles declared with [devenv.sh](https://devenv.sh) — the Hermes counterpart of
[cachix/devenv-ai-agents](https://github.com/cachix/devenv-ai-agents) (Claude Code sub-agents).

Hermes has no project-local sub-agent files: its unit of specialization is the
**profile** (`~/.hermes/profiles/<name>`), with a description the kanban
decomposer routes tasks on, a `SOUL.md` persona, and its own toolsets and model.
This repo adds a `hermes.agents.<name>` devenv option and the
`hermes-agents-sync` command that converges those profiles idempotently.

## Available agents

| Agent | Toolsets | Use when |
|---|---|---|
| **code-reviewer** | file, terminal, todo | Expert code review (quality, security, best practices). Use proactively after code changes. |
| **architecture-designer** | file, web, delegation | System architecture and API design: scalable designs, contracts, schemas, security patterns. |
| **documentation-writer** | file, terminal, web | Docs, API specs, changelogs, PR descriptions. Use proactively when code changes affect docs. |
| **devops-specialist** | file, terminal, web, delegation | CI/CD, deployments, monitoring, infrastructure-as-code. Never applies on its own. |
| **fullstack-developer** | file, terminal, web | Feature implementation across frontend, backend, mobile and data pipelines. |
| **quality-assurance** | file, terminal, web, delegation | Test automation, accessibility audits, dependency hygiene, compliance. |
| **refactoring** | file, terminal, todo | Behaviour-preserving cleanup that reduces cognitive load. |

## Usage

Import this repository in your `devenv.yaml`:

```yaml title="devenv.yaml"
inputs:
  devenv-hermes-agents:
    url: github:jeremiepas/devenv-hermes-agents
    flake: false
imports:
  - devenv-hermes-agents
```

The hermes CLI must be on PATH (host install, or add the NousResearch flake as
an input and set `hermes.package`):

```yaml title="devenv.yaml"
inputs:
  hermes-agent:
    url: github:NousResearch/hermes-agent
```

```nix title="devenv.nix"
{ pkgs, inputs, ... }: {
  hermes.package = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
  hermes.agentsAutoSync = true;   # converge on every `devenv shell` (optional)
}
```

Then converge the profiles:

```bash
devenv shell
hermes-agents-sync            # creates/updates the 7 profiles under $HERMES_HOME
hermes-agents-sync --list     # what is declared
hermes-agents-sync --dry-run  # what would change
hermes-agents-sync --only code-reviewer --force
```

Each run is idempotent: a per-agent stamp (`.devenv-hermes-agents.stamp` in the
profile) skips agents whose declaration has not changed. Without
`agentsAutoSync`, entering the shell only prints a hint when profiles are missing.

## Using the agents from Hermes

- **Chat with one directly**: `hermes -p code-reviewer chat`
- **Delegate from another agent** (one-shot, in the project dir):
  `hermes -p code-reviewer chat -q "Review the current diff" -Q`
- **Kanban**: `hermes kanban create "Review PR #12" --assignee code-reviewer --workspace dir:$PWD`;
  the decomposer routes subtasks on the profile descriptions.
- The sync also installs a `hermes-agents` skill into `$HERMES_HOME/skills/` so
  your main profile knows the catalog and how to hand work over
  (`hermes.agentsSkill.enable = false` to skip).

## Extending agents

Append to a prompt (prompts are `lib.types.lines`, so modules merge):

```nix
{ pkgs, lib, ... }: {
  hermes.agents.code-reviewer.prompt = ''
    NEVER say "You're right"!
  '';
}
```

Replace a prompt, or the whole `SOUL.md`:

```nix
{ pkgs, lib, ... }: {
  hermes.agents.code-reviewer.prompt = lib.mkForce "Do a basic code review.";
  hermes.agents.refactoring.soul = lib.mkForce (builtins.readFile ./souls/refactoring.md);
}
```

Give an agent a model, more tools, or extra config:

```nix
{
  hermes.agents.architecture-designer = {
    model = "claude-sonnet-4-6";
    provider = "anthropic";
    reasoningEffort = "high";
    toolsets = [ "file" "web" "delegation" "browser" ];
    cloneFrom = "default";                 # inherit the default profile's config/.env/skills on creation
    extraConfig."agent.max_turns" = "40";
  };
}
```

Declare your own:

```nix
{
  hermes.agents.release-manager = {
    description = "Prepares releases: version bump, changelog, tag. Use when a release is requested.";
    toolsets = [ "file" "terminal" ];
    exclusiveToolsets = true;              # disable every other built-in toolset
    prompt = "…";
  };
}
```

## Options

| Option | Default | Effect |
|---|---|---|
| `hermes.agents.<name>.description` | — | Profile description (`hermes profile describe`); kanban routing text |
| `hermes.agents.<name>.prompt` | — | Instructions in `SOUL.md` (merged across modules) |
| `hermes.agents.<name>.soul` | identity line + prompt | Full `SOUL.md` content |
| `hermes.agents.<name>.toolsets` | `[ "file" "terminal" "web" ]` | `hermes -p <name> tools enable …` |
| `hermes.agents.<name>.disabledToolsets` | `[ ]` | `tools disable …` |
| `hermes.agents.<name>.exclusiveToolsets` | `false` | Disable every built-in toolset not in `toolsets` |
| `hermes.agents.<name>.model` / `.provider` | `null` | `model.default` / `model.provider` overrides |
| `hermes.agents.<name>.reasoningEffort` | `null` | `agent.reasoning_effort` |
| `hermes.agents.<name>.cloneFrom` | `null` | `hermes profile create --clone-from` on first creation |
| `hermes.agents.<name>.alias` | `true` | Create the `~/.hermes/bin/<name>` wrapper |
| `hermes.agents.<name>.extraConfig` | `{ }` | Extra `config set key value` pairs |
| `hermes.agentsAutoSync` | `false` | Run the sync on `enterShell` |
| `hermes.agentsSkill.enable` | `true` | Install the `hermes-agents` delegation skill |
| `hermes.package` | `null` | Hermes package to put on PATH |

`HERMES_HOME` is honoured (default `~/.hermes`); profiles land in `$HERMES_HOME/profiles/`.

## Differences from Claude Code sub-agents

- Profiles are per machine (`HERMES_HOME`), not files in the project — the
  declaration is in the project, the converged state is in Hermes.
- Hermes does not auto-pick a sub-agent in chat; delegation is explicit
  (`hermes -p <agent> chat -q … -Q`, kanban assignee, swarm) or by the kanban
  decomposer matching descriptions.
- Tool restriction is by toolset (`file`, `terminal`, `web`, …), not per tool name.

## Learn more

- [Hermes Agent](https://hermes-agent.nousresearch.com/docs) — profiles, kanban, skills
- [Composing using imports](https://devenv.sh/composing-using-imports/)
- [devenv.sh documentation](https://devenv.sh)
