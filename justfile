default:
    @just --list

build *ARGS:
    cargo build {{ARGS}}

# Types only, no codegen, no lints. Add `-p <crate>` to make it cheaper still.
check *ARGS:
    cargo check --workspace --tests {{ARGS}}

run *ARGS:
    cargo run {{ARGS}}

test *ARGS:
    cargo nextest run --workspace {{ARGS}}

lint:
    cargo clippy --all --tests -- -D warnings

lint-fix:
    cargo clippy --all --tests --fix

fmt-check:
    cargo fmt --all -- --check
    stylua --check plugins/

fmt:
    cargo fmt --all
    stylua plugins/

# Point git at the checked-in hooks (once per clone).
hooks:
    git config core.hooksPath .githooks

pylint:
    ruff check scripts/
    ty check scripts/

gen-docs:
    cargo run -p maki-docgen

gen-docs-check:
    cargo run -p maki-docgen -- --check

machete:
    cargo machete

# Lists TODO/FIXME debt markers in comments. Never fails; CI prints the inventory.
todos:
    rg -n --no-heading '(//|#|--)[^\n]*\b(TODO|FIXME)\b' -g '*.rs' -g '*.nix' -g '*.lua' -g '*.py' -g '*.toml' || true

# Fails when a member crate pins its own dependency version instead of
# inheriting [workspace.dependencies], the single source of truth.
dep-drift:
    #!/usr/bin/env bash
    set -euo pipefail
    drift=$(rg -n '^\s*[A-Za-z0-9_-]+\s*=\s*(\{[^}]*\b(version|git)\b|"[0-9])' -g 'maki-*/Cargo.toml' || true)
    if [ -n "$drift" ]; then
        echo "member crates must inherit workspace dependencies:" >&2
        printf '%s\n' "$drift" >&2
        exit 1
    fi

# Fails when AGENTS.md or CONTRIBUTING.md mentions a `just <recipe>` that no longer exists.
agents-md-check:
    #!/usr/bin/env bash
    set -euo pipefail
    status=0
    for recipe in $(grep -hoE '`just [a-z][a-z0-9-]*`' AGENTS.md CONTRIBUTING.md | sed -e 's/^`just //' -e 's/`$//' | sort -u); do
        just --summary | tr ' ' '\n' | grep -qx "$recipe" || {
            echo "docs mention a missing recipe: just $recipe" >&2
            status=1
        }
    done
    exit $status

# Full CI check
ci: fmt-check lint pylint test gen-docs-check machete dep-drift agents-md-check
