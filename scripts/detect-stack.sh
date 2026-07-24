#!/usr/bin/env bash
# detect-stack.sh — the "any tech stack" brain of the AI harness.
#
# Inspects a repository and prints the gate commands the harness should run
# (install / lint / typecheck / test / build / format / docs), plus the VCS
# host, default branch, and an honest confidence rating. Output is both
# human-readable and machine-parseable (`harness.KEY=VALUE` lines).
#
# Modes
#   detect-stack.sh [path]               single-root report (default: cwd)
#   detect-stack.sh --json [path]        same, as a JSON object
#   detect-stack.sh --roots [path]       list sub-project roots in a monorepo
#   detect-stack.sh --affected [base] [path]
#                                        map changed files (vs base + working
#                                        tree) to affected sub-projects and
#                                        print each one's gate
#
# No dependencies beyond POSIX tools + git. Best-effort: probes never abort.

# Best-effort detection: never abort on a probe that returns non-zero.
set -u

MODE="report"
BASE=""
ROOT="."

case "${1:-}" in
  --json)     MODE="json"; ROOT="${2:-.}" ;;
  --roots)    MODE="roots"; ROOT="${2:-.}" ;;
  --affected) MODE="affected"
              # forms: --affected <base> <path> | --affected <path> | --affected <base>
              if   [ $# -ge 3 ];               then BASE="$2"; ROOT="$3"
              elif [ $# -eq 2 ] && [ -d "$2" ]; then ROOT="$2"
              else                                  BASE="${2:-}"; fi ;;
  "")         : ;;
  *)          ROOT="$1" ;;
esac

cd "$ROOT" 2>/dev/null || { echo "cannot enter $ROOT" >&2; exit 1; }
ROOT="$(pwd)"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

have()   { command -v "$1" >/dev/null 2>&1; }
exists() { [ -e "$1" ]; }
# has_script NAME -> true if package.json defines that npm script.
# Scoped to the "scripts" object so a dependency named "lint" can't trigger it.
has_script() {
  [ -f package.json ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" <<'PY' 2>/dev/null
import json, sys
try:
    scripts = json.load(open("package.json")).get("scripts", {})
    sys.exit(0 if sys.argv[1] in scripts else 1)
except Exception:
    sys.exit(1)
PY
  else
    sed -n '/"scripts"[[:space:]]*:[[:space:]]*{/,/}/p' package.json \
      | grep -Eq "\"$1\"[[:space:]]*:"
  fi
}
# has_make_target NAME -> true if Makefile defines that target
has_make_target() { [ -f Makefile ] && grep -Eq "^$1[[:space:]]*:" Makefile; }

# ---------------------------------------------------------------------------
# Monorepo root discovery
# ---------------------------------------------------------------------------
PRUNE='-name node_modules -o -name .git -o -name .venv -o -name venv -o -name vendor -o -name dist -o -name build -o -name .build -o -name target -o -name __pycache__ -o -name .next -o -name .tox -o -name .cache -o -name .idea -o -name .vscode -o -name .harness'
MARKERS='-name package.json -o -name pyproject.toml -o -name requirements.txt -o -name setup.py -o -name go.mod -o -name Cargo.toml -o -name pom.xml -o -name build.gradle -o -name build.gradle.kts -o -name build.sbt -o -name Gemfile -o -name composer.json -o -name mix.exs -o -name Package.swift -o -name pubspec.yaml -o -name "*.csproj"'

# ecosystem_of <marker-filename> -> family name, so nested same-family dirs
# (npm workspace members, python sub-packages) collapse into their parent.
ecosystem_of() {
  case "$1" in
    package.json) echo node ;;
    pyproject.toml|requirements.txt|setup.py) echo python ;;
    go.mod) echo go ;;
    Cargo.toml) echo rust ;;
    pom.xml|build.gradle|build.gradle.kts|build.sbt) echo jvm ;;
    Gemfile) echo ruby ;;
    composer.json) echo php ;;
    mix.exs) echo elixir ;;
    Package.swift) echo swift ;;
    pubspec.yaml) echo dart ;;
    *.csproj) echo dotnet ;;
    *) echo other ;;
  esac
}

# ancestor_has_family <dir> <family> -> 0 if a dir between ROOT and dir
# (inclusive of ROOT, exclusive of dir) has a marker of the same family.
ancestor_has_family() {
  local d="$1" fam="$2" cur
  cur="$(dirname "$d")"
  while :; do
    case "$fam" in
      node)   [ -f "$cur/package.json" ] && return 0 ;;
      python) { [ -f "$cur/pyproject.toml" ] || [ -f "$cur/requirements.txt" ] || [ -f "$cur/setup.py" ]; } && return 0 ;;
      go)     [ -f "$cur/go.mod" ] && return 0 ;;
      rust)   [ -f "$cur/Cargo.toml" ] && return 0 ;;
      jvm)    { [ -f "$cur/pom.xml" ] || [ -f "$cur/build.gradle" ] || [ -f "$cur/build.gradle.kts" ] || [ -f "$cur/build.sbt" ]; } && return 0 ;;
      ruby)   [ -f "$cur/Gemfile" ] && return 0 ;;
      php)    [ -f "$cur/composer.json" ] && return 0 ;;
      elixir) [ -f "$cur/mix.exs" ] && return 0 ;;
      swift)  [ -f "$cur/Package.swift" ] && return 0 ;;
      dart)   [ -f "$cur/pubspec.yaml" ] && return 0 ;;
      dotnet) ls "$cur"/*.csproj >/dev/null 2>&1 && return 0 ;;
    esac
    [ "$cur" = "$ROOT" ] && return 1
    [ "$cur" = "/" ] && return 1
    cur="$(dirname "$cur")"
  done
}

# discover_roots -> newline list of primary sub-project dirs (absolute).
# A dir is primary when no ancestor inside the repo shares its ecosystem
# (npm-workspace members and nested sub-packages collapse into the parent).
discover_roots() {
  local f d fam out=""
  while IFS= read -r f; do
    d="$(dirname "$f")"
    fam="$(ecosystem_of "$(basename "$f")")"
    if [ "$d" = "$ROOT" ] || ! ancestor_has_family "$d" "$fam"; then
      out="${out}${d}\n"
    fi
  done < <(eval "find \"\$ROOT\" -maxdepth 4 \\( $PRUNE \\) -prune -o -type f \\( $MARKERS \\) -print" 2>/dev/null)
  printf '%b' "$out" | sort -u
}

if [ "$MODE" = "roots" ]; then
  echo "=== AI harness · sub-project roots ==="
  n=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    rel="${d#"$ROOT"}"; rel="${rel#/}"; [ -z "$rel" ] && rel="."
    printf 'harness.project=%s\n' "$rel"
    n=$((n+1))
  done < <(discover_roots)
  [ "$n" -eq 0 ] && echo "harness.project=."
  exit 0
fi

if [ "$MODE" = "affected" ]; then
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "not a git repository: $ROOT" >&2; exit 1; }
  # Anchor to the git top-level so changed-file paths (which git reports
  # relative to the repo root) line up with sub-project matching below.
  ROOT="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$ROOT")"
  # Resolve a base for the committed range (best-effort).
  if [ -z "$BASE" ]; then
    BASE="$(git -C "$ROOT" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/@@')"
  fi
  CHANGED="$( {
      [ -n "$BASE" ] && git -C "$ROOT" diff --name-only "$BASE"...HEAD 2>/dev/null
      git -C "$ROOT" diff --name-only 2>/dev/null
      git -C "$ROOT" diff --name-only --staged 2>/dev/null
      git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null
    } | sort -u)"
  if [ -z "$CHANGED" ]; then
    echo "=== AI harness · affected projects ==="
    echo "No changed files detected (base: ${BASE:-<none>})."
    exit 0
  fi
  echo "=== AI harness · affected projects (base: ${BASE:-working tree only}) ==="
  FOUND=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    rel="${d#"$ROOT"}"; rel="${rel#/}"
    if [ -z "$rel" ]; then
      hit="$CHANGED"                                # root project: any change counts
    else
      hit="$(printf '%s\n' "$CHANGED" | grep -E "^$rel/" || true)"
    fi
    if [ -n "$hit" ]; then
      FOUND=1
      echo
      echo "--- affected: ${rel:-.} ($(printf '%s\n' "$hit" | grep -c .) changed files) ---"
      bash "$SELF" "$d" | grep -E '^harness\.' | sed "s|^harness\.|harness.${rel:-root}.|"
    fi
  done < <(discover_roots)
  [ "$FOUND" -eq 0 ] && echo "Changed files map to no detected sub-project (docs/CI only?)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Single-root detection
# ---------------------------------------------------------------------------
LANGS=""; PM=""
INSTALL=""; LINT=""; TYPECHECK=""; TEST=""; BUILD=""; FORMAT=""; DOCS=""

add_lang() { case " $LANGS " in *" $1 "*) : ;; *) LANGS="${LANGS:+$LANGS }$1";; esac; }

# ------------------------------------------------------------- Node / JS-TS
if exists package.json; then
  add_lang "node"
  if   exists bun.lockb;      then PM="bun"
  elif exists pnpm-lock.yaml; then PM="pnpm"
  elif exists yarn.lock;      then PM="yarn"
  else                             PM="npm"; fi
  case "$PM" in
    bun)  INSTALL="bun install" ;;
    pnpm) INSTALL="pnpm install --frozen-lockfile" ;;
    yarn) INSTALL="yarn install --frozen-lockfile" ;;
    npm)  if exists package-lock.json || exists npm-shrinkwrap.json; then INSTALL="npm ci"; else INSTALL="npm install"; fi ;;
  esac
  run() { case "$PM" in bun) echo "bun run $1";; pnpm) echo "pnpm $1";; yarn) echo "yarn $1";; *) echo "npm run $1";; esac; }
  has_script lint      && LINT="$(run lint)"
  has_script typecheck && TYPECHECK="$(run typecheck)"
  has_script test      && TEST="$(run test)"
  has_script build     && BUILD="$(run build)"
  has_script format    && FORMAT="$(run format)"
  if   has_script docs;       then DOCS="$(run docs)"
  elif has_script build:docs; then DOCS="$(run build:docs)"; fi
  # tsconfig without a typecheck script -> offer tsc directly
  [ -z "$TYPECHECK" ] && exists tsconfig.json && TYPECHECK="npx tsc --noEmit"
fi

# ------------------------------------------------------------- Python
if exists pyproject.toml || exists requirements.txt || exists setup.py || exists setup.cfg; then
  add_lang "python"
  if   exists uv.lock;      then PY="uv";     INSTALL="${INSTALL:+$INSTALL && }uv sync"
  elif exists poetry.lock;  then PY="poetry"; INSTALL="${INSTALL:+$INSTALL && }poetry install"
  elif exists Pipfile.lock; then PY="pipenv"; INSTALL="${INSTALL:+$INSTALL && }pipenv install --dev"
  else                           PY="pip";    INSTALL="${INSTALL:+$INSTALL && }pip install -e . 2>/dev/null || pip install -r requirements.txt"; fi
  pyrun() { case "$PY" in uv) echo "uv run $*";; poetry) echo "poetry run $*";; pipenv) echo "pipenv run $*";; *) echo "$*";; esac; }
  if grep -Eqi 'ruff' pyproject.toml 2>/dev/null || exists ruff.toml || exists .ruff.toml; then
    LINT="${LINT:+$LINT && }$(pyrun ruff check .)"; FORMAT="${FORMAT:+$FORMAT && }$(pyrun ruff format .)"
  elif exists .flake8 || grep -Eqi 'flake8' pyproject.toml setup.cfg 2>/dev/null; then
    LINT="${LINT:+$LINT && }$(pyrun flake8)"
  fi
  if grep -Eqi 'mypy' pyproject.toml setup.cfg 2>/dev/null || exists mypy.ini; then
    TYPECHECK="${TYPECHECK:+$TYPECHECK && }$(pyrun mypy .)"
  elif grep -Eqi 'pyright' pyproject.toml 2>/dev/null; then
    TYPECHECK="${TYPECHECK:+$TYPECHECK && }$(pyrun pyright)"
  fi
  TEST="${TEST:+$TEST && }$(pyrun pytest -q)"
  { exists mkdocs.yml && DOCS="${DOCS:+$DOCS && }$(pyrun mkdocs build)"; } || \
  { exists docs/conf.py && DOCS="${DOCS:+$DOCS && }$(pyrun sphinx-build -b html docs docs/_build)"; }
fi

# ------------------------------------------------------------- Go
if exists go.mod; then
  add_lang "go"
  INSTALL="${INSTALL:+$INSTALL && }go mod download"
  LINT="${LINT:+$LINT && }go vet ./...$(have golangci-lint && echo ' && golangci-lint run' || true)"
  TEST="${TEST:+$TEST && }go test ./..."
  BUILD="${BUILD:+$BUILD && }go build ./..."
  FORMAT="${FORMAT:+$FORMAT && }gofmt -l ."
fi

# ------------------------------------------------------------- Rust
if exists Cargo.toml; then
  add_lang "rust"
  INSTALL="${INSTALL:+$INSTALL && }cargo fetch"
  LINT="${LINT:+$LINT && }cargo clippy -- -D warnings"
  TEST="${TEST:+$TEST && }cargo test"
  BUILD="${BUILD:+$BUILD && }cargo build"
  FORMAT="${FORMAT:+$FORMAT && }cargo fmt --check"
fi

# ------------------------------------------------------------- JVM
if exists pom.xml; then
  add_lang "java"; TEST="${TEST:+$TEST && }mvn -B test"; BUILD="${BUILD:+$BUILD && }mvn -B package"
elif exists build.gradle || exists build.gradle.kts; then
  add_lang "jvm"; W="gradle"; exists ./gradlew && W="./gradlew"
  TEST="${TEST:+$TEST && }$W test"; BUILD="${BUILD:+$BUILD && }$W build"
elif exists build.sbt; then
  add_lang "scala"; TEST="${TEST:+$TEST && }sbt test"; BUILD="${BUILD:+$BUILD && }sbt compile"
fi

# ------------------------------------------------------------- Others
exists Gemfile        && { add_lang ruby;   INSTALL="${INSTALL:+$INSTALL && }bundle install"; TEST="${TEST:+$TEST && }bundle exec rake test"; }
exists composer.json  && { add_lang php;    INSTALL="${INSTALL:+$INSTALL && }composer install"; TEST="${TEST:+$TEST && }composer test"; }
ls ./*.csproj >/dev/null 2>&1 && { add_lang dotnet; INSTALL="${INSTALL:+$INSTALL && }dotnet restore"; TEST="${TEST:+$TEST && }dotnet test"; BUILD="${BUILD:+$BUILD && }dotnet build"; }
exists mix.exs        && { add_lang elixir; INSTALL="${INSTALL:+$INSTALL && }mix deps.get"; TEST="${TEST:+$TEST && }mix test"; }
exists Package.swift  && { add_lang swift;  TEST="${TEST:+$TEST && }swift test"; BUILD="${BUILD:+$BUILD && }swift build"; }
if exists pubspec.yaml; then
  add_lang dart
  if grep -q 'flutter' pubspec.yaml 2>/dev/null; then
    INSTALL="${INSTALL:+$INSTALL && }flutter pub get"; LINT="${LINT:+$LINT && }flutter analyze"; TEST="${TEST:+$TEST && }flutter test"
  else
    INSTALL="${INSTALL:+$INSTALL && }dart pub get"; LINT="${LINT:+$LINT && }dart analyze"; TEST="${TEST:+$TEST && }dart test"
  fi
fi

# ------------------------------------------------------------- Terraform / Docker
IAC=no
if find . -maxdepth 2 -name '*.tf' -not -path './.git/*' 2>/dev/null | grep -q .; then
  IAC=yes
  add_lang terraform
  LINT="${LINT:+$LINT && }terraform fmt -check -recursive"
fi
DOCKERFILE=no
if exists Dockerfile; then
  DOCKERFILE=yes
  have hadolint && LINT="${LINT:+$LINT && }hadolint Dockerfile"
fi

# ------------------------------------------------------------- Makefile fallback
if exists Makefile; then
  [ -z "$LINT" ]  && has_make_target lint  && LINT="make lint"
  [ -z "$TEST" ]  && has_make_target test  && TEST="make test"
  [ -z "$BUILD" ] && has_make_target build && BUILD="make build"
  [ "$LANGS" = "" ] && { has_make_target test || has_make_target build; } && add_lang make
fi

# ------------------------------------------------------------- generic docs/notebooks
[ -z "$DOCS" ] && exists docusaurus.config.js && DOCS="npm run build"
NOTEBOOKS=no
find . -maxdepth 3 -name '*.ipynb' -not -path './.git/*' -not -path '*/node_modules/*' -not -path '*/.venv/*' 2>/dev/null | grep -q . && NOTEBOOKS=yes

# ------------------------------------------------------------- VCS host + default branch
HOST="unknown"; BRANCH="main"; REMOTE=""
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REMOTE="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  case "$REMOTE" in
    *github.com*) HOST="github" ;;
    *gitlab*)     HOST="gitlab" ;;
    *bitbucket*)  HOST="bitbucket" ;;
  esac
  [ "$HOST" = "unknown" ] && { exists .github && HOST="github"; exists .gitlab-ci.yml && HOST="gitlab"; exists bitbucket-pipelines.yml && HOST="bitbucket"; }
  BRANCH="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || echo main)"
  DEF="$(git -C "$ROOT" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
  [ -n "$DEF" ] && BRANCH="$DEF"
fi

[ -z "$LANGS" ] && LANGS="unknown"
# Surface the Python package manager when no JS one set PM.
[ -z "$PM" ] && PM="${PY:-}"

# ------------------------------------------------------------- confidence
# high  = lint-or-typecheck AND test detected (a real gate exists)
# low   = something detected, but the gate is thin — treat green with caution
# none  = nothing detected — a "passing" gate here proves NOTHING
if [ "$LANGS" = "unknown" ]; then CONFIDENCE="none"
elif [ -n "$TEST" ] && { [ -n "$LINT" ] || [ -n "$TYPECHECK" ]; }; then CONFIDENCE="high"
else CONFIDENCE="low"; fi

# ------------------------------------------------------------- output
if [ "$MODE" = "json" ]; then
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  printf '{\n'
  printf '  "languages": "%s",\n' "$(esc "$LANGS")"
  printf '  "package_manager": "%s",\n' "$(esc "$PM")"
  printf '  "host": "%s",\n' "$(esc "$HOST")"
  printf '  "default_branch": "%s",\n' "$(esc "$BRANCH")"
  printf '  "confidence": "%s",\n' "$CONFIDENCE"
  printf '  "notebooks": "%s",\n' "$NOTEBOOKS"
  printf '  "iac": "%s",\n' "$IAC"
  printf '  "dockerfile": "%s",\n' "$DOCKERFILE"
  printf '  "install": "%s",\n' "$(esc "$INSTALL")"
  printf '  "lint": "%s",\n' "$(esc "$LINT")"
  printf '  "typecheck": "%s",\n' "$(esc "$TYPECHECK")"
  printf '  "test": "%s",\n' "$(esc "$TEST")"
  printf '  "build": "%s",\n' "$(esc "$BUILD")"
  printf '  "format": "%s",\n' "$(esc "$FORMAT")"
  printf '  "docs": "%s"\n' "$(esc "$DOCS")"
  printf '}\n'
  exit 0
fi

echo   "=== AI harness · stack report ==="
printf 'Repository     : %s\n' "$ROOT"
printf 'Languages      : %s\n' "$LANGS"
printf 'Package manager: %s\n' "${PM:-n/a}"
printf 'VCS host       : %s  (default branch: %s)\n' "$HOST" "$BRANCH"
printf 'Confidence     : %s\n' "$CONFIDENCE"
case "$CONFIDENCE" in
  none) echo 'WARNING        : could not determine a gate — a "green" run proves nothing; verify by hand' ;;
  low)  echo 'WARNING        : gate is thin (missing lint/typecheck or tests) — green means less than it looks' ;;
esac
[ "$NOTEBOOKS" = yes ]  && echo 'Note           : notebooks present — treat as inspect-only unless a runner is configured'
[ "$IAC" = yes ]        && echo 'Note           : infrastructure-as-code present — fmt/validate only, NEVER auto-apply'
[ "$DOCKERFILE" = yes ] && echo 'Note           : Dockerfile present — image build kept out of the default gate (heavy)'
echo
echo   "--- recommended gate (run in this order; skip empty steps) ---"
printf 'harness.install=%s\n'   "$INSTALL"
printf 'harness.lint=%s\n'      "$LINT"
printf 'harness.typecheck=%s\n' "$TYPECHECK"
printf 'harness.test=%s\n'      "$TEST"
printf 'harness.build=%s\n'     "$BUILD"
printf 'harness.format=%s\n'    "$FORMAT"
printf 'harness.docs=%s\n'      "$DOCS"
printf 'harness.host=%s\n'      "$HOST"
printf 'harness.default_branch=%s\n' "$BRANCH"
printf 'harness.confidence=%s\n' "$CONFIDENCE"

# Monorepo hint: other primary roots exist below this one.
OTHERS="$(discover_roots | grep -vx "$ROOT" || true)"
if [ -n "$OTHERS" ]; then
  echo
  echo "--- monorepo: additional sub-projects detected (use --roots / --affected) ---"
  printf '%s\n' "$OTHERS" | while IFS= read -r d; do
    printf 'harness.subproject=%s\n' "${d#"$ROOT"/}"
  done
fi
