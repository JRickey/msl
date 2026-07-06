# msl Agent Skill

The `msl/` directory is a portable Agent Skills-compatible skill for people who
want an AI harness to use msl from other projects.

## Codex

Install for one user:

```sh
mkdir -p ~/.agents/skills
cp -R skills/msl ~/.agents/skills/msl
```

Install for a repository:

```sh
mkdir -p .agents/skills
cp -R skills/msl .agents/skills/msl
```

Codex also supports packaging reusable skills as plugins when you want a
marketplace/install flow.

## Claude Code

Install for one user:

```sh
mkdir -p ~/.claude/skills
cp -R skills/msl ~/.claude/skills/msl
```

Install for a repository:

```sh
mkdir -p .claude/skills
cp -R skills/msl .claude/skills/msl
```

Claude Code can also distribute skills through plugins. For claude.ai or the
Claude API, use Anthropic's upload/API flow instead of these filesystem paths.
