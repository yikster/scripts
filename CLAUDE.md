# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A collection of standalone system administration shell scripts. Each script is self-contained and meant to be run directly on a target host — there is no build step, package manifest, or test suite.

## Scripts

- `init-gitlab-ce.sh` — Installs GitLab CE on RHEL-based systems (`dnf`). Adds GitLab's official package repo via the upstream `script.rpm.sh`, then installs `gitlab-ce` with the `EXTERNAL_URL` baked in at install time. Requires `sudo`/root. The `EXTERNAL_URL` (currently `https://gitlab.example.com`) must be edited per deployment before running.

## Running

Scripts target RHEL/Fedora hosts and assume `dnf` and `sudo`. Run directly:

```bash
bash init-gitlab-ce.sh
```

## Conventions

- Scripts are designed to be idempotent-friendly system bootstrapping (`dnf install -y`, `dnf update -y`).
- Inline comments are in English. (The `gitlab-runner/` scripts were originally authored with Korean comments and translated to English; keep new and edited scripts in English.)
