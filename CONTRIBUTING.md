# Contribution checklist

This is a public repository. Review the staged changes for private information before submitting a pull request. If a file's suitability is unclear, ask a maintainer.

## Suitable contributions

- Source code, tests, and build scripts, including qmake projects, CMake files, and CI workflows.
- Technical documentation in `docs/`: designs, operating procedures, and architecture notes.
- Vendored dependency changes, submodule revisions, patches, and version pins that match a tested dependency combination.
- Local tools in `scripts/` that address a specific, reproducible problem.
- Translations and interface text.

## Keep out of the repository

- Business materials, customer or deployment documents, project bundles, and commercial or operational records. Store local materials under the ignored `projects/` directory.
- Secrets and credentials: certificates, tokens, passwords, SSH keys, and `.env` files. Real values in examples are still credentials.
- Private network details: internal domains, address ranges, network diagrams, server inventories, and deployment-specific port conventions.
- Local environment files: IDE and agent directories, `build/`, `libs/`, and personal absolute paths.
- Build artifacts and large generated files: binaries, dumps, logs, Makefiles, and object files.

## Before submitting

1. Check `git status` for files that do not belong in the change.
2. Read `git diff --staged`, including any new documentation, and check for tokens, secrets, passwords, private addresses, and deployment details. A keyword search is useful but does not replace reviewing the diff.
3. Review any file larger than 1 MB to ensure it is a source asset rather than a generated artifact or document bundle.
4. Remove specific customer names, private project identifiers, and server names, or move the document to local `projects/` storage.

## Background

On September 18, 2026, business project materials were accidentally included in an upstream pull request and removed by rewriting the branch. The entire `projects/` directory is therefore intentionally ignored.
