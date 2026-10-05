# modules/hermes-agents.nix — declare Hermes Agent specialist profiles in devenv.
#
# The Hermes counterpart of devenv's `claude.code.agents`: each
# `hermes.agents.<name>` becomes a Hermes PROFILE (~/.hermes/profiles/<name>)
# with
#   * profile.yaml `description` — the text the kanban decomposer uses to route
#     tasks to a profile by role (`hermes profile describe`),
#   * SOUL.md — the agent's identity / system prompt,
#   * toolsets enabled/disabled per agent (`hermes -p <name> tools …`),
#   * optional model/provider/reasoning-effort/config overrides.
#
# Profiles live in HERMES_HOME, not in the project, so nothing is written at
# eval time: Nix builds a manifest (+ one SOUL.md per agent) and the
# `hermes-agents-sync` command converges the profiles idempotently (a per-agent
# stamp makes re-runs no-ops until the declaration changes). Set
# `hermes.agentsAutoSync = true` to run it on `devenv shell` entry.
{ pkgs, lib, config, ... }:
let
  cfg = config.hermes;

  agentType = lib.types.submodule ({ name, config, ... }: {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = ''
          One or two sentences on what this agent is good at. Stored as the
          profile description — the kanban decomposer routes tasks on it, so
          say WHEN to use the agent ("use proactively after code changes").
        '';
      };
      prompt = lib.mkOption {
        type = lib.types.lines;
        description = "Instructions appended to the agent's identity in SOUL.md (merged across modules; use lib.mkForce to replace).";
      };
      soul = lib.mkOption {
        type = lib.types.lines;
        default = ''
          # ${name}

          You are **${name}** — ${config.description}

          ${config.prompt}
        '';
        defaultText = lib.literalMD "identity line built from the name and description, followed by `prompt`";
        description = "Full SOUL.md content written into the profile. Override to control the whole file.";
      };
      toolsets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "file" "terminal" "web" ];
        description = "Hermes toolsets to enable for the profile (`hermes tools list` names: file, terminal, web, browser, todo, delegation, memory, skills, …).";
      };
      disabledToolsets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Toolsets to disable explicitly.";
      };
      exclusiveToolsets = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Disable every built-in toolset that is not in `toolsets` (closest to Claude Code's allow-list semantics).";
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "claude-sonnet-4-6";
        description = "Override `model.default` for this profile (null = inherit the cloned/default profile).";
      };
      provider = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "anthropic";
        description = "Override `model.provider` for this profile.";
      };
      reasoningEffort = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "low" "medium" "high" "xhigh" ]);
        default = null;
        description = "Override `agent.reasoning_effort` for this profile.";
      };
      cloneFrom = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "default";
        description = "Profile to clone config/.env/skills from when the profile is first created (`hermes profile create --clone-from`).";
      };
      alias = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Let Hermes create the `~/.hermes/bin/<name>` wrapper script (`--no-alias` when false).";
      };
      extraConfig = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = { "agent.max_turns" = "40"; };
        description = "Additional `hermes -p <name> config set <key> <value>` pairs applied on sync.";
      };
    };
  });

  names = lib.attrNames cfg.agents;

  soulFile = name: a: pkgs.writeText "hermes-agent-${name}-SOUL.md" a.soul;

  agentEntry = name: a:
    let
      entry = {
        inherit (a) description toolsets disabledToolsets exclusiveToolsets model provider reasoningEffort cloneFrom alias extraConfig;
        soul = "${soulFile name a}";
      };
    in
    entry // { stamp = builtins.hashString "sha256" (builtins.toJSON entry); };

  # Skill telling any Hermes profile which specialist agents exist and how to
  # hand work to them (one-shot chat, kanban assignee, swarm).
  delegationSkill = pkgs.writeTextFile {
    name = "hermes-agents-skill";
    destination = "/SKILL.md";
    text = ''
    ---
    name: hermes-agents
    description: "Specialist Hermes agent profiles declared by devenv (${lib.concatStringsSep ", " names}): when to use which and how to delegate to them."
    version: 1.0.0
    license: MIT
    platforms: [linux, macos]
    metadata:
      hermes:
        tags: [agents, delegation, profiles, devenv]
    ---

    # Specialist agents (devenv-hermes-agents)

    These Hermes profiles exist on this machine, converged by `hermes-agents-sync`.
    Pick the one whose description matches the job; keep the main conversation
    for coordination.

    | agent | use when |
    |---|---|
    ${lib.concatMapStringsSep "\n" (n: "| `${n}` | ${cfg.agents.${n}.description} |") names}

    ## How to delegate

    - **One-shot, synchronous** (terminal tool, run in the project directory):
      `hermes -p <agent> chat -q "<task with all needed context>" -Q` — the
      agent answers on stdout; its files edits land in the current directory.
    - **Kanban task**: `hermes kanban create "<title>" --assignee <agent> --workspace dir:<path>`
      — the board dispatches a worker under that profile. The kanban decomposer
      also routes decomposed subtasks by profile description.
    - **Parallel fan-out**: `hermes kanban swarm …` with the agents as workers.

    Each agent only has the toolsets it was declared with; if it needs more,
    change the devenv declaration, not the profile.
  '';
  };

  manifest = pkgs.writeText "hermes-agents.json" (builtins.toJSON {
    agents = lib.mapAttrs agentEntry cfg.agents;
    skill = if cfg.agentsSkill.enable then "${delegationSkill}" else null;
  });

  syncScript = pkgs.writeShellApplication {
    name = "hermes-agents-sync";
    runtimeInputs = [ pkgs.jq pkgs.coreutils pkgs.gnused pkgs.gawk ];
    text = ''
      # hermes-agents-sync — converge Hermes profiles to the devenv declaration.
      MANIFEST="${manifest}"
      HERMES_HOME="''${HERMES_HOME:-$HOME/.hermes}"
      DRY=0 QUIET=0 FORCE=0 LIST=0
      ONLY=()
      usage() {
        cat <<USAGE
      usage: hermes-agents-sync [--list] [--dry-run] [--force] [--only NAME]... [--quiet]
        --list      print the declared agents and exit (no hermes needed)
        --dry-run   show what would change, mutate nothing
        --force     re-apply even when the per-agent stamp matches
        --only NAME converge only this agent (repeatable)
        --quiet     only print changes and errors
      Profiles are converged under HERMES_HOME ($HERMES_HOME).
      USAGE
      }
      while [ $# -gt 0 ]; do
        case "$1" in
          --list) LIST=1 ;;
          --dry-run) DRY=1 ;;
          --force) FORCE=1 ;;
          --quiet) QUIET=1 ;;
          --only) ONLY+=("''${2:?--only needs a name}"); shift ;;
          -h|--help) usage; exit 0 ;;
          *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
        esac
        shift
      done
      log()  { [ "$QUIET" = 1 ] || echo "[hermes-agents] $*"; }
      chg()  { echo "[hermes-agents] $*"; }
      err()  { echo "[hermes-agents] ERROR $*" >&2; }
      run()  { if [ "$DRY" = 1 ]; then echo "[hermes-agents] would: $*"; else "$@"; fi; }

      if [ "$LIST" = 1 ]; then
        jq -r '.agents | to_entries[] | "\(.key)\t\(.value.toolsets | join(","))\t\(.value.description)"' "$MANIFEST" \
          | awk -F'\t' '{ printf "%-24s %-32s %s\n", $1, $2, $3 }'
        exit 0
      fi
      command -v hermes >/dev/null 2>&1 || { err "hermes CLI not on PATH (set hermes.package or enter a shell that provides it)"; exit 1; }

      selected() {  # selected <name> → 0 when --only is empty or contains name
        [ "''${#ONLY[@]}" -eq 0 ] && return 0
        local n; for n in "''${ONLY[@]}"; do [ "$n" = "$1" ] && return 0; done
        return 1
      }
      # profile list: strip the sticky-default marker (◆) and read column 1 past the 2 header lines
      existing_profiles() {
        hermes profile list 2>/dev/null | sed -E 's/^[[:space:]]*◆?//' | awk 'NR>2 && NF {print $1}'
      }
      PROFILES="$(existing_profiles || true)"
      has_profile() { printf '%s\n' "$PROFILES" | grep -Fxq "$1"; }

      changed=0
      while IFS= read -r name; do
        selected "$name" || continue
        entry="$(jq -c --arg n "$name" '.agents[$n]' "$MANIFEST")"
        pdir="$HERMES_HOME/profiles/$name"
        stampfile="$pdir/.devenv-hermes-agents.stamp"
        stamp="$(jq -r '.stamp' <<<"$entry")"
        if [ "$FORCE" = 0 ] && [ -f "$stampfile" ] && [ "$(cat "$stampfile")" = "$stamp" ]; then
          log "$name OK (up to date)"
          continue
        fi
        desc="$(jq -r '.description' <<<"$entry")"
        soul="$(jq -r '.soul' <<<"$entry")"
        clone="$(jq -r '.cloneFrom // empty' <<<"$entry")"
        alias_on="$(jq -r '.alias' <<<"$entry")"
        model="$(jq -r '.model // empty' <<<"$entry")"
        provider="$(jq -r '.provider // empty' <<<"$entry")"
        effort="$(jq -r '.reasoningEffort // empty' <<<"$entry")"
        exclusive="$(jq -r '.exclusiveToolsets' <<<"$entry")"
        mapfile -t toolsets < <(jq -r '.toolsets[]' <<<"$entry")
        mapfile -t disabled < <(jq -r '.disabledToolsets[]' <<<"$entry")

        if ! has_profile "$name"; then
          args=(profile create "$name" --description "$desc")
          [ -n "$clone" ] && args+=(--clone-from "$clone")
          [ "$alias_on" = "false" ] && args+=(--no-alias)
          if [ "$DRY" = 1 ]; then
            run hermes "''${args[@]}"
          else
            hermes "''${args[@]}" >/dev/null || { err "profile create $name failed"; exit 1; }
            chg "CREATED profile $name"
          fi
        else
          run hermes profile describe "$name" --text "$desc" >/dev/null
        fi

        if [ "$DRY" = 0 ]; then
          mkdir -p "$pdir"
          if ! cmp -s "$soul" "$pdir/SOUL.md" 2>/dev/null; then
            install -m 644 "$soul" "$pdir/SOUL.md"
            chg "CONVERGED $name/SOUL.md"
          fi
        else
          cmp -s "$soul" "$pdir/SOUL.md" 2>/dev/null || echo "[hermes-agents] would: write $pdir/SOUL.md"
        fi

        if [ "''${#toolsets[@]}" -gt 0 ]; then
          run hermes -p "$name" tools enable "''${toolsets[@]}" >/dev/null || { err "tools enable failed for $name"; exit 1; }
        fi
        if [ "$exclusive" = "true" ]; then
          # every enabled built-in toolset not declared → disable
          mapfile -t on < <(hermes -p "$name" tools list 2>/dev/null \
            | awk '/^Built-in toolsets/{b=1;next} /^[A-Z]/{b=0} b && /enabled/ {print $3}' | grep -v '^$' || true)
          for t in "''${on[@]}"; do
            keep=0; for w in "''${toolsets[@]}"; do [ "$w" = "$t" ] && keep=1; done
            [ "$keep" = 1 ] || disabled+=("$t")
          done
        fi
        if [ "''${#disabled[@]}" -gt 0 ]; then
          run hermes -p "$name" tools disable "''${disabled[@]}" >/dev/null || { err "tools disable failed for $name"; exit 1; }
        fi
        [ -n "$model" ]    && run hermes -p "$name" config set model.default "$model" >/dev/null
        [ -n "$provider" ] && run hermes -p "$name" config set model.provider "$provider" >/dev/null
        [ -n "$effort" ]   && run hermes -p "$name" config set agent.reasoning_effort "$effort" >/dev/null
        while IFS=$'\t' read -r k v; do
          [ -n "$k" ] || continue
          run hermes -p "$name" config set "$k" "$v" >/dev/null
        done < <(jq -r '.extraConfig | to_entries[] | "\(.key)\t\(.value)"' <<<"$entry")

        if [ "$DRY" = 0 ]; then
          printf '%s\n' "$stamp" > "$stampfile"
          chg "CONVERGED profile $name (toolsets: ''${toolsets[*]})"
        else
          echo "[hermes-agents] would: converge profile $name (toolsets: ''${toolsets[*]})"
        fi
        changed=1
      done < <(jq -r '.agents | keys[]' "$MANIFEST")

      # delegation skill → $HERMES_HOME/skills/hermes-agents (read-only store symlink)
      skill="$(jq -r '.skill // empty' "$MANIFEST")"
      if [ -n "$skill" ]; then
        dst="$HERMES_HOME/skills/hermes-agents"
        if [ -e "$dst" ] && [ ! -L "$dst" ]; then
          log "skills/hermes-agents exists and is not a symlink — left alone"
        elif [ "$(readlink "$dst" 2>/dev/null)" != "$skill" ]; then
          if [ "$DRY" = 1 ]; then echo "[hermes-agents] would: link $dst → $skill"; else
            mkdir -p "$HERMES_HOME/skills" && ln -sfn "$skill" "$dst" && chg "CONVERGED skills/hermes-agents"
          fi
          changed=1
        fi
      fi
      [ "$changed" = 1 ] || log "all agents up to date"
    '';
  };
in
{
  options.hermes = {
    agents = lib.mkOption {
      type = lib.types.attrsOf agentType;
      default = { };
      description = ''
        Hermes Agent specialist profiles to converge on this machine
        (`~/.hermes/profiles/<name>`): description (kanban routing), SOUL.md
        persona, toolsets and model overrides. Run `hermes-agents-sync` (or set
        `hermes.agentsAutoSync`) to apply.
      '';
      example = lib.literalExpression ''
        {
          code-reviewer = {
            description = "Expert code reviewer. Use proactively after code changes.";
            toolsets = [ "file" "terminal" "todo" ];
            prompt = '''
              Review the diff for correctness, security and readability.
              Report critical issues first, with concrete fixes.
            ''';
          };
        }
      '';
    };
    agentsAutoSync = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run `hermes-agents-sync --quiet` on every `devenv shell` entry (needs the hermes CLI on PATH).";
    };
    agentsSkill.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the `hermes-agents` skill (catalog + how to delegate) into `$HERMES_HOME/skills/`.";
    };
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Hermes Agent package to add to the shell (e.g. the NousResearch flake's default package). null = rely on the host PATH.";
    };
  };

  config = lib.mkIf (cfg.agents != { }) {
    assertions = map
      (n: {
        assertion = builtins.match "[a-z0-9][a-z0-9-]*" n != null;
        message = "hermes.agents: profile name '${n}' must be lowercase alphanumeric (hyphens allowed)";
      })
      names;

    packages = [ syncScript ] ++ lib.optional (cfg.package != null) cfg.package;

    env.HERMES_AGENTS_MANIFEST = "${manifest}";

    enterShell =
      if cfg.agentsAutoSync then ''
        hermes-agents-sync --quiet || echo "[hermes-agents] sync failed — run: hermes-agents-sync"
      '' else ''
        if command -v hermes >/dev/null 2>&1; then
          _ha_missing=""
          for _n in ${lib.escapeShellArgs names}; do
            [ -d "''${HERMES_HOME:-$HOME/.hermes}/profiles/$_n" ] || _ha_missing="$_ha_missing $_n"
          done
          [ -z "$_ha_missing" ] || echo "[hermes-agents] profiles not converged:$_ha_missing — run: hermes-agents-sync"
          unset _ha_missing _n
        fi
      '';
  };
}
