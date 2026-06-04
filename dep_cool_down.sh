#!/usr/bin/env bash
#
# install-pip-cooldown.sh  (cohort-aware)
# ---------------------------------------
# Enforces a package release-age "cooldown" across a heterogeneous macOS fleet
# where some devs run Apple's Python 3.9, some run a newer Python/pip, and some
# use pyenv. It detects the situation per machine and applies the RIGHT fix:
#
#   • Apple Python 3.9 (pip can't reach >=26.1) ........ install uv + pip SHIM
#   • Newer Python with pip >= 26.1 ................... native cooldown (pip.conf)
#   • Newer Python with old pip ...................... try upgrading pip, else SHIM
#   • pyenv ........................................... upgrade pip in each version
#        (its shims shadow ours, so cooldown must come from native pip.conf)
#
# pip.conf is written on every machine (pinned index + only-binary). The native
# relative cooldown line is added ONLY when a reachable pip is >= 26.1, because
# pip 26.0 and older choke on / ignore the relative "P7D" form.
#
# Honest gaps (any client-side approach): `python3 -m pip`, absolute paths,
# `pip download`/`wheel`, `--user`. Only a date-filtering index proxy closes
# those. The pip.conf hardening still applies on those paths.
#
# Usage:
#   ./install-pip-cooldown.sh                 # detect + install
#   ./install-pip-cooldown.sh --uninstall
#   COOLDOWN_DAYS=14 ./install-pip-cooldown.sh
#   UPGRADE_PIP=0 ./install-pip-cooldown.sh   # don't auto-upgrade pyenv/modern pip
#   REQUIRE_VENV=1 ./install-pip-cooldown.sh  # also enforce require-virtualenv
#
set -euo pipefail

# ---- config -----------------------------------------------------------------
COOLDOWN_DAYS="${COOLDOWN_DAYS:-7}"
COOLDOWN_UV="${COOLDOWN_DAYS} days"          # uv-friendly duration
COOLDOWN_PIP="P${COOLDOWN_DAYS}D"            # ISO-8601 duration for pip
UPGRADE_PIP="${UPGRADE_PIP:-1}"              # auto-upgrade old pip where safe
REQUIRE_VENV="${REQUIRE_VENV:-0}"            # add require-virtualenv to pip.conf
PIP_MIN_COOLDOWN="26.1"                      # first pip with RELATIVE cooldown
PY_MIN_FOR_MODERN_PIP="3.10"                 # pip 26.1 requires Python >= 3.10

SHIM_MARKER="pip-cooldown-shim"          # version-agnostic detector (any vN)
PIPCONF_MARKER="pip-cooldown-managed"    # version-agnostic detector (any vN)
PIPCONF_LINE="# pip-cooldown-managed v3" # what we actually write
UV_CFG="$HOME/.config/uv/uv.toml"
PIP_CFG="$HOME/.config/pip/pip.conf"
UV_BIN=""                                    # resolved at runtime (uv's real path)

# Bin dirs that can precede /usr/bin on PATH. Install the shim into whichever
# exist (creating /usr/local/bin if needed) so neither Intel nor Apple-Silicon
# layouts can shadow us. We do NOT require any specific one to exist.
SHIM_DIRS=("/usr/local/bin")
[ -d "/opt/homebrew/bin" ] && SHIM_DIRS+=("/opt/homebrew/bin")

# ---- helpers ----------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

maybe_sudo() { if [ -w "$1" ]; then printf ''; else printf 'sudo'; fi; }
is_marked()  { [ -f "$1" ] && grep -q "$2" "$1" 2>/dev/null; }

# ver_ge A B  -> succeeds if version A >= version B
ver_ge() {
  [ "$1" = "$2" ] && return 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

py_minor()  { "$1" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null; }
pip_ver()   { "$1" -m pip --version 2>/dev/null | awk '{print $2}'; }

# ---- uninstall --------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
  for dir in "${SHIM_DIRS[@]}"; do
    for name in pip pip3; do
      f="$dir/$name"
      if is_marked "$f" "$SHIM_MARKER"; then
        SUDO="$(maybe_sudo "$dir")"
        $SUDO rm -f "$f"
        [ -f "$f.pre-cooldown.bak" ] && $SUDO mv "$f.pre-cooldown.bak" "$f"
        log "removed shim $f"
      fi
    done
  done
  if is_marked "$PIP_CFG" "$PIPCONF_MARKER"; then
    rm -f "$PIP_CFG"
    [ -f "$PIP_CFG.pre-cooldown.bak" ] && mv "$PIP_CFG.pre-cooldown.bak" "$PIP_CFG"
    log "restored $PIP_CFG"
  fi
  log "uninstalled. (uv binary and uv.toml left in place)"
  exit 0
fi

# ---- write managed pip.conf -------------------------------------------------
# $1 = native_ok (1 = a reachable pip is >=26.1, so the relative cooldown line
# is safe to write; 0 = omit it, cooldown comes from the shim instead).
write_pip_conf() {
  local native_ok="$1"
  mkdir -p "$(dirname "$PIP_CFG")"
  if [ -e "$PIP_CFG" ] && ! is_marked "$PIP_CFG" "$PIPCONF_MARKER"; then
    cp "$PIP_CFG" "$PIP_CFG.pre-cooldown.bak"
    warn "backed up existing pip.conf -> $PIP_CFG.pre-cooldown.bak"
  fi
  {
    echo "$PIPCONF_LINE"
    echo "[global]"
    echo "index-url = https://pypi.org/simple   # single pinned index (dep-confusion safe)"
    [ "$REQUIRE_VENV" = "1" ] && echo "require-virtualenv = true"
    echo "disable-pip-version-check = true"
    echo ""
    echo "[install]"
    echo "only-binary = :all:                   # no setup.py execution at install time"
    if [ "$native_ok" = "1" ]; then
      echo "# Native relative cooldown — requires pip >= ${PIP_MIN_COOLDOWN}."
      echo "uploaded-prior-to = ${COOLDOWN_PIP}"
    else
      echo "# Cooldown handled by the uv shim on this machine (active pip < ${PIP_MIN_COOLDOWN},"
      echo "# which would reject the relative '${COOLDOWN_PIP}' form). Re-run after upgrading pip."
    fi
  } > "$PIP_CFG"
  log "wrote managed pip.conf (cooldown_line=${native_ok}, require-virtualenv=${REQUIRE_VENV})"
}

# ---- write uv.toml (only if absent) -----------------------------------------
write_uv_toml() {
  if [ -f "$UV_CFG" ]; then log "kept existing $UV_CFG"; return; fi
  mkdir -p "$(dirname "$UV_CFG")"
  cat > "$UV_CFG" <<EOF
# Created by install-pip-cooldown.sh
index-strategy = "first-index"
index-url = "https://pypi.org/simple"
exclude-newer = "${COOLDOWN_UV}"

[pip]
only-binary = [":all:"]
EOF
  log "wrote $UV_CFG"
}

# ---- install uv and resolve its real path (no symlink games) ----------------
install_uv() {
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
  else
    log "installing uv (Astral official installer)…"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    UV_BIN="$HOME/.local/bin/uv"; [ -x "$UV_BIN" ] || UV_BIN="$HOME/.cargo/bin/uv"
  fi
  [ -x "$UV_BIN" ] || die "uv installed but not found (looked in PATH, ~/.local/bin, ~/.cargo/bin)"
  log "using uv at $UV_BIN"
  "$UV_BIN" pip install --help 2>/dev/null | grep -q -- '--exclude-newer' \
    || warn "this uv lacks --exclude-newer; run 'uv self update'."
}

# ---- write pip / pip3 shims -------------------------------------------------
install_shims() {
  [ -n "$UV_BIN" ] || die "internal: UV_BIN not set before install_shims"
  local installed=0
  for dir in "${SHIM_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
      local s; s="$(maybe_sudo "$(dirname "$dir")")"
      if ! $s mkdir -p "$dir" 2>/dev/null; then
        warn "could not create $dir — skipping it."; continue
      fi
    fi
    for name in pip pip3; do write_shim "$dir/$name" || warn "failed to write $dir/$name"; done
    installed=1
  done
  [ "$installed" = "1" ] || die "could not install the shim into any PATH dir"
}
write_shim() {
  local target="$1" dir SUDO tmp
  dir="$(dirname "$target")"; SUDO="$(maybe_sudo "$dir")"
  if [ -e "$target" ] && ! is_marked "$target" "$SHIM_MARKER"; then
    $SUDO mv "$target" "$target.pre-cooldown.bak"
    warn "backed up $target -> $target.pre-cooldown.bak"
  fi
  tmp="$(mktemp)"
  cat > "$tmp" <<'SHIM'
#!/usr/bin/env bash
# pip-cooldown-shim v3
# Routes `pip install` through uv to enforce a release-age cooldown.
# Managed by install-pip-cooldown.sh — do not edit (re-run the installer).
set -u
UV="@@UV@@"
COOLDOWN="@@COOLDOWN@@"
PY="$(command -v python3 || true)"
if [ "${1:-}" != "install" ]; then exec "$PY" -m pip "$@"; fi
for a in "$@"; do
  if [ "$a" = "--user" ]; then
    echo "pip-cooldown: --user unsupported by uv; using system pip (NO cooldown)." >&2
    exec "$PY" -m pip "$@"
  fi
done
[ -n "$PY" ] || { echo "pip-cooldown: no python3 on PATH" >&2; exit 1; }
if [ -n "${VIRTUAL_ENV:-}" ]; then
  exec "$UV" pip install --exclude-newer "$COOLDOWN" "${@:2}"
else
  exec "$UV" pip install --exclude-newer "$COOLDOWN" --python "$PY" --system "${@:2}"
fi
SHIM
  sed -i '' -e "s|@@UV@@|$UV_BIN|g" -e "s|@@COOLDOWN@@|$COOLDOWN_UV|g" "$tmp"
  chmod 0755 "$tmp"; $SUDO mv "$tmp" "$target"
  log "installed shim $target"
}

# ---- ensure a given python's pip is >= PIP_MIN_COOLDOWN ----------------------
# returns 0 if pip ends up >= min, 1 otherwise
ensure_modern_pip() {
  local py="$1" pv
  pv="$(pip_ver "$py")"
  if [ -n "$pv" ] && ver_ge "$pv" "$PIP_MIN_COOLDOWN"; then return 0; fi
  if [ "$UPGRADE_PIP" != "1" ]; then return 1; fi
  log "  upgrading pip for $py (have ${pv:-none}, want >= ${PIP_MIN_COOLDOWN})…"
  PIP_REQUIRE_VIRTUALENV=0 "$py" -m pip install -U pip >/dev/null 2>&1 || true
  pv="$(pip_ver "$py")"
  [ -n "$pv" ] && ver_ge "$pv" "$PIP_MIN_COOLDOWN"
}

# =============================================================================
# main: detect cohort -> set NATIVE_OK / SHIM_NEEDED -> write config -> act
# =============================================================================
PY3="$(command -v python3 || true)"
[ -n "$PY3" ] || die "no python3 on PATH"

NATIVE_OK=0       # a reachable pip supports relative cooldown
SHIM_NEEDED=0     # this machine needs the uv shim

HAS_PYENV=0
if command -v pyenv >/dev/null 2>&1 || [ -d "$HOME/.pyenv/versions" ]; then HAS_PYENV=1; fi

if [ "$HAS_PYENV" = "1" ]; then
  log "COHORT: pyenv detected — shims shadow PATH, so cooldown is native (pip.conf)."
  shopt -s nullglob
  covered=0; stuck=0
  for vpy in "$HOME"/.pyenv/versions/*/bin/python; do
    [ -x "$vpy" ] || continue
    minor="$(py_minor "$vpy")"; [ -n "$minor" ] || continue
    if ! ver_ge "$minor" "$PY_MIN_FOR_MODERN_PIP"; then
      warn "  $vpy is Python $minor (<$PY_MIN_FOR_MODERN_PIP): can't get native cooldown."
      stuck=$((stuck+1)); continue
    fi
    if ensure_modern_pip "$vpy"; then
      log "  $vpy (Python $minor): native cooldown active."; NATIVE_OK=1; covered=$((covered+1))
    else
      warn "  $vpy: pip still < ${PIP_MIN_COOLDOWN}; run 'pip install -U pip' in this version."
    fi
  done
  shopt -u nullglob
  log "pyenv: ${covered} covered natively, ${stuck} too old for native cooldown."

else
  PYMINOR="$(py_minor "$PY3")"; PIPV="$(pip_ver "$PY3")"
  log "COHORT: non-pyenv. python3=$PYMINOR pip=${PIPV:-none}"
  if ver_ge "$PYMINOR" "$PY_MIN_FOR_MODERN_PIP"; then
    if ensure_modern_pip "$PY3"; then
      log "Native cooldown active (pip >= ${PIP_MIN_COOLDOWN}). No shim needed."; NATIVE_OK=1
    else
      warn "pip < ${PIP_MIN_COOLDOWN} and couldn't upgrade (externally-managed?). Using shim."
      SHIM_NEEDED=1
    fi
  else
    log "Python $PYMINOR can't reach pip >= ${PIP_MIN_COOLDOWN} (e.g. Apple Python 3.9)."
    log "Will install uv + shim to enforce cooldown on this interpreter."
    SHIM_NEEDED=1
  fi
fi

write_pip_conf "$NATIVE_OK"
write_uv_toml
if [ "$SHIM_NEEDED" = "1" ]; then install_uv; install_shims; fi

# ---- verify -----------------------------------------------------------------
hash -r 2>/dev/null || true
log "verifying pip cooldown…"
PIPV_NOW="$(pip_ver "$PY3" 2>/dev/null || true)"
RESOLVED="$(command -v pip3 || true)"
if is_marked "$RESOLVED" "$SHIM_MARKER"; then
  log "OK: pip3 -> cooldown shim ($RESOLVED), cooldown=${COOLDOWN_UV}."
elif [ -n "$PIPV_NOW" ] && ver_ge "$PIPV_NOW" "$PIP_MIN_COOLDOWN"; then
  log "OK: pip3 ($PIPV_NOW) honors native uploaded-prior-to=${COOLDOWN_PIP}."
else
  warn "No cooldown on default pip3 ($RESOLVED, pip ${PIPV_NOW:-?})."
  warn "If a pyenv shell: run 'pip install -U pip' here; otherwise re-run the installer."
fi

cat <<EOF

Done.  Cooldown target: ${COOLDOWN_DAYS} days.
Residual bypasses (need an index proxy to close): python3 -m pip, absolute /usr/bin/pip3,
pip download/wheel, --user.
Uninstall:  $0 --uninstall
EOF
