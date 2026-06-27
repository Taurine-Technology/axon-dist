#!/usr/bin/env bash
#
# axon-agent token-install orchestrator.
#
# This is the script served by the controller at
# GET /api/v2/enrollment/install-script/ (the controller bakes AXON_CONTROLLER_URL
# and, when configured, AXON_DOWNLOAD_BASE onto the top of it before serving).
#
# It detects the host architecture, downloads the matching Go agent tarball from
# AXON_DOWNLOAD_BASE (a locally-hosted file server or a release CDN), verifies its
# checksum, unpacks it, and runs the bundled packaging/install.sh — enrolling the
# device and, for mirror deployments, writing classifier_config.json.
#
# install.sh is transactional: if it fails partway it rolls back every system
# mutation (slots, symlink, units, OVS rules) to the pre-install state via its own
# journal/trap. This orchestrator therefore reverts system state on failure simply
# by surfacing the installer's non-zero exit (after the installer has already
# rolled itself back) — beyond cleaning the temp download workdir.
#
# One-liner (switching, the default):
#   curl -fsSL "$CONTROLLER/api/v2/enrollment/install-script/" \
#     | sudo -E AXON_TOKEN=axn_… bash
#
# One-liner (mirror SPAN device):
#   curl -fsSL "$CONTROLLER/api/v2/enrollment/install-script/" \
#     | sudo -E AXON_TOKEN=axn_… AXON_DEPLOYMENT_MODE=mirror \
#             AXON_MONITOR_INTERFACE=eth1 bash
#
set -euo pipefail

log() { printf 'axon-bootstrap: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

# ── Inputs (env) ────────────────────────────────────────────────────────────
: "${AXON_TOKEN:?AXON_TOKEN is required (the axn_… enrollment token)}"
AXON_CONTROLLER_URL="${AXON_CONTROLLER_URL:-https://controller.axon.local}"
AXON_DOWNLOAD_BASE="${AXON_DOWNLOAD_BASE:-}"   # baked by controller or set by operator
AXON_AGENT_URL="${AXON_AGENT_URL:-}"           # full tarball URL override
AXON_AGENT_SHA256="${AXON_AGENT_SHA256:-}"     # expected sha256 for a custom AXON_AGENT_URL (required for remote URLs without channel checksums)
AXON_VERSION="${AXON_VERSION:-}"               # pin a version; else read <base>/<channel>/latest
# Release stream: alpha|beta|main (default main). AXON_RELEASE_CHANNEL is the
# controller/UI-facing name (baked by the enrollment install-script endpoint and
# emitted in the UI one-liner); AXON_CHANNEL is the legacy alias and wins if both
# are set. The --channel flag (below) overrides either.
AXON_CHANNEL="${AXON_CHANNEL:-${AXON_RELEASE_CHANNEL:-main}}"
AXON_DEPLOYMENT_MODE="${AXON_DEPLOYMENT_MODE:-switching}"
AXON_MONITOR_INTERFACE="${AXON_MONITOR_INTERFACE:-}"
AXON_PRIMARY_INTERFACE="${AXON_PRIMARY_INTERFACE:-eth0}"
AXON_SITE_ID="${AXON_SITE_ID:-}"
AXON_DEVICE_ID="${AXON_DEVICE_ID:-}"

# ── CLI flags ─────────────────────────────────────────────────────────────────
# Usually invoked as `curl … | bash` (env-driven), but `--channel` may also be
# passed via `bash -s -- --channel beta`. CLI wins over the AXON_CHANNEL env.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --channel)
            AXON_CHANNEL="${2:?missing channel}"
            shift 2
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

# Resolve the release channel and fail fast on anything outside the allowed set
# so a typo never silently falls back to a different stream.
case "$AXON_CHANNEL" in
    alpha|beta|main) ;;
    *) die "invalid channel '$AXON_CHANNEL' (expected one of: alpha, beta, main)" ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar  >/dev/null 2>&1 || die "tar is required"

# ── Architecture ────────────────────────────────────────────────────────────
case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac

workdir="$(mktemp -d "${TMPDIR:-/tmp}/axon-agent.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

# ── Resolve + download the tarball ──────────────────────────────────────────
# The channel is a path segment under the download base: latest, the tarball, and
# checksums.txt all live under <base>/<channel>/… (see docs/release-index.md). An
# AXON_AGENT_URL full-URL override bypasses channel resolution entirely.
channel="$AXON_CHANNEL"
channel_base=""
if [ -n "$AXON_AGENT_URL" ]; then
    url="$AXON_AGENT_URL"
else
    [ -n "$AXON_DOWNLOAD_BASE" ] || \
        die "set AXON_DOWNLOAD_BASE (or AXON_AGENT_URL) to locate the agent tarball"
    channel_base="${AXON_DOWNLOAD_BASE%/}/$channel"
    version="$AXON_VERSION"
    if [ -z "$version" ]; then
        version="$(curl -fsSL "$channel_base/latest" 2>/dev/null | tr -d '[:space:]' || true)"
        [ -n "$version" ] || die "no AXON_VERSION and could not read $channel_base/latest"
    fi
    url="$channel_base/axon-agent_${version}_linux_${arch}.tar.gz"
fi

# Derive a sanitized artifact name (basename with any ?query-string stripped) for
# both the local filename and the log line. AXON_AGENT_URL may be a presigned /
# credential-bearing URL, so never log $url itself — that would leak the signature
# into stderr/install logs. Stripping the query string also keeps the on-disk
# filename and the checksums.txt lookup clean.
artifact_name="$(basename "${url%%\?*}")"
tarball="$workdir/$artifact_name"
log "downloading $artifact_name (channel=$channel)"
curl -fSL "$url" -o "$tarball"

# ── Integrity verification (FAIL CLOSED for remote downloads) ────────────────
# The downloaded tarball is unpacked and its install.sh is executed as root, so a
# remote (network) payload MUST be integrity-verified before extraction. We refuse
# to run an unverified remote download (missing/unfetchable checksums, no matching
# entry, or no sha256sum) — only a local file:// source may skip (operator's call).
bn="$artifact_name"
case "$url" in
    file://*) remote=false ;;
    *) remote=true ;;
esac

if [ -n "$channel_base" ]; then
    # Enrollment / channel-base path: verify against <base>/<channel>/checksums.txt.
    if [ "$remote" = true ]; then
        command -v sha256sum >/dev/null 2>&1 \
            || die "sha256sum is required to verify the downloaded agent ($bn); refusing to run an unverified root install"
        curl -fsSL "$channel_base/checksums.txt" -o "$workdir/checksums.txt" 2>/dev/null \
            || die "could not fetch $channel_base/checksums.txt to verify $bn; refusing to run an unverified download"
        grep -q "[ *]$bn\$" "$workdir/checksums.txt" 2>/dev/null \
            || die "no checksum entry for $bn in checksums.txt; refusing to run an unverified download"
        ( cd "$workdir" && grep "[ *]$bn\$" checksums.txt | sha256sum -c - ) \
            || die "checksum verification failed for $bn"
        log "checksum verified ($bn)"
    else
        log "local file:// channel source; skipping checksum verification ($bn)"
    fi
else
    # Custom AXON_AGENT_URL (no channel checksums available): verify against
    # AXON_AGENT_SHA256 when provided; require it for a remote URL.
    if [ -n "$AXON_AGENT_SHA256" ]; then
        command -v sha256sum >/dev/null 2>&1 \
            || die "sha256sum is required to verify AXON_AGENT_SHA256 for $bn"
        printf '%s  %s\n' "$AXON_AGENT_SHA256" "$bn" >"$workdir/expected.sha256"
        ( cd "$workdir" && sha256sum -c expected.sha256 ) \
            || die "AXON_AGENT_SHA256 verification failed for $bn"
        log "checksum verified against AXON_AGENT_SHA256 ($bn)"
    elif [ "$remote" = true ]; then
        die "remote AXON_AGENT_URL requires AXON_AGENT_SHA256 (or a channel checksums.txt) to verify the root-executed download; refusing to run unverified"
    else
        log "local file:// source without AXON_AGENT_SHA256; skipping checksum verification ($bn)"
    fi
fi

# ── Unpack ──────────────────────────────────────────────────────────────────
pkgdir="$workdir/pkg"
mkdir -p "$pkgdir"
tar -xzf "$tarball" -C "$pkgdir"
root="$pkgdir/axon-agent"
[ -d "$root" ] || root="$pkgdir"
[ -f "$root/install.sh" ] || die "install.sh not found in tarball"
chmod +x "$root/install.sh" 2>/dev/null || true

# ── Run the installer ───────────────────────────────────────────────────────
# Pass the channel through so install.sh records it on the host and points the
# agent's self-update default (AXON_UPDATE_INDEX_URL) at this channel's index.
# The download base lets install.sh build {base}/{channel}/index.json; when only
# AXON_AGENT_URL is set (no base) the channel is still recorded.
set -- --enrollment-token "$AXON_TOKEN" --controller-url "$AXON_CONTROLLER_URL" \
    --channel "$channel"
[ -n "$AXON_DOWNLOAD_BASE" ] && set -- "$@" --download-base "${AXON_DOWNLOAD_BASE%/}"
[ -n "$AXON_PRIMARY_INTERFACE" ] && set -- "$@" --primary-interface "$AXON_PRIMARY_INTERFACE"
if [ "$AXON_DEPLOYMENT_MODE" = "mirror" ]; then
    set -- "$@" --deployment-mode mirror
    [ -n "$AXON_MONITOR_INTERFACE" ] && set -- "$@" --monitor-interface "$AXON_MONITOR_INTERFACE"
    [ -n "$AXON_SITE_ID" ]  && set -- "$@" --site-id "$AXON_SITE_ID"
    [ -n "$AXON_DEVICE_ID" ] && set -- "$@" --device-id "$AXON_DEVICE_ID"
fi

log "installing (deployment_mode=$AXON_DEPLOYMENT_MODE)"
# Run the transactional installer. On failure it has already rolled back every
# system mutation to the pre-install state via its own journal/trap; we surface
# the non-zero exit (and the temp workdir is removed by the EXIT trap above).
if ! AXON_PACKAGE_DIR="$root" "$root/install.sh" "$@"; then
    die "install failed; the installer rolled back system state to its pre-install condition (see axon-install logs above)"
fi
log "done"
