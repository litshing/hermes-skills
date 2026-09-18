# Hermes Skills

A curated collection of [Hermes Agent](https://hermes-agent.nousresearch.com/docs) skills,
built and battle-tested on a real macOS workstation.

Each skill is a `SKILL.md` (YAML frontmatter + guidance) optionally with
`scripts/`, `references/`, `templates/` alongside it.

## What's here

Only skills authored/adapted for this setup are published here — third-party
skills (superpowers, Orchestra Research, and other upstream authors) are **not**
redistributed. See `skills.txt` for the exact allowlist.

## Install a skill

Copy any folder into your Hermes skills directory:

```bash
cp -R skills/<category>/<skill-name> ~/.hermes/skills/<category>/
```

Hermes picks up new skills automatically; verify with the skills list in your client.

## Syncing from a live Hermes install

This repo is generated. `sync.sh` copies the allowlisted skills out of
`~/.hermes/skills`, **runs a secret scan, and refuses to commit if anything
key-shaped is found**, then commits and pushes.

```bash
./sync.sh          # rebuild skills/ from allowlist + secret scan + push
```

Edit `skills.txt` (one `category/skill-name` per line) to change what is published.

## Licence

MIT — see [LICENSE](LICENSE). Skills that adapt upstream work credit the
original author in their frontmatter.
