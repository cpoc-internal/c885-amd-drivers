#!/usr/bin/env bash
#
# install-mi350-rocm.sh
#
# Full driver + ROCm stack installation for AMD Instinct MI350X / MI355X (gfx950).
#
# Target:   Debian 13 (trixie) and Ubuntu 22.04 / 24.04, x86_64
# Installs: amdgpu-dkms kernel driver (30.20) + ROCm 7.1 compute stack
#
# Safe to re-run: every step is idempotent and skips work already done.
#
# Usage:
#   sudo ./install-mi350-rocm.sh              # full install
#   sudo ./install-mi350-rocm.sh verify       # verification only, changes nothing
#   sudo ./install-mi350-rocm.sh --no-reload  # install but don't touch the running module
#
# NOTE ON DEBIAN: Debian is not on AMD's official ROCm support matrix. This script
# installs AMD's Ubuntu "jammy" packages, and applies a source patch to amdgpu-dkms
# when the running kernel needs it (see patch_dkms_source below). That patch is
# applied ONLY if the kernel actually requires it, so this script is also correct
# on Ubuntu, where no patch is needed.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration -- bump these together when moving to a newer ROCm release.
# ---------------------------------------------------------------------------
ROCM_VER="7.1"              # https://repo.radeon.com/rocm/apt/
AMDGPU_VER="30.20"          # https://repo.radeon.com/amdgpu/
GRAPHICS_VER="7.1"          # https://repo.radeon.com/graphics/
AMD_CODENAME="jammy"        # AMD package flavour to pull (Ubuntu 22.04 packages)
KEYRING="/etc/apt/keyrings/rocm.gpg"
KEY_URL="https://repo.radeon.com/rocm/rocm.gpg.key"

KVER="$(uname -r)"
RELOAD_MODULE=1
MODE="install"

for arg in "$@"; do
    case "$arg" in
        verify)      MODE="verify" ;;
        --no-reload) RELOAD_MODULE=0 ;;
        -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
    C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_ERR=""; C_HEAD=""; C_OFF=""
fi
step() { printf '\n%s==> %s%s\n' "$C_HEAD" "$*" "$C_OFF"; }
ok()   { printf '%s  [ok]%s %s\n'   "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '%s  [warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '%s  [fail]%s %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
preflight() {
    step "Preflight checks"

    [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

    [ -r /etc/os-release ] || die "/etc/os-release missing; unsupported system"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "$ID" in
        debian|ubuntu) ok "OS: $PRETTY_NAME" ;;
        *) die "unsupported distro '$ID' (this script handles debian/ubuntu only)" ;;
    esac
    [ "$ID" = "debian" ] && warn "Debian is not on AMD's official ROCm support matrix"

    [ "$(uname -m)" = "x86_64" ] || die "x86_64 required, found $(uname -m)"
    ok "Kernel: $KVER"

    # gfx950 = MI350X (0x75a0) / MI355X (0x75a3). Accept any AMD "Processing
    # accelerator" so this still reports usefully on other Instinct parts.
    local n
    n="$(lspci -nn 2>/dev/null | grep -ci '\[1002:75a[03]\]' || true)"
    if [ "$n" -gt 0 ]; then
        ok "Found $n MI350-class GPU(s) on the PCI bus"
    else
        warn "No 1002:75a0/75a3 device found. Continuing, but check the GPUs are seated/enabled."
        lspci -nn | grep -i '1002:' | head -5 || true
    fi

    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        warn "Secure Boot is ENABLED. The DKMS module is self-signed; you must enroll"
        warn "  /var/lib/dkms/mok.pub via 'mokutil --import' or the module will not load."
    else
        ok "Secure Boot disabled (or not applicable)"
    fi
}

# ---------------------------------------------------------------------------
# 2. Build prerequisites -- the #1 cause of "GPU not detected" is missing headers,
#    which makes amdgpu-dkms silently stay in the 'added' state and never build.
# ---------------------------------------------------------------------------
install_build_deps() {
    step "Installing build prerequisites and kernel headers for $KVER"
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq

    # Debian and Ubuntu both name the per-kernel header package this way.
    local hdr="linux-headers-${KVER}"

    # amdgpu-dkms may already be unpacked from a previous partial run; its
    # postinst autoinstall can fail here and that is fine -- we build explicitly later.
    apt-get install -y \
        "$hdr" build-essential dkms gcc make \
        curl ca-certificates gnupg lsb-release pciutils kmod \
        || warn "apt reported an error (likely a DKMS autoinstall failure) -- continuing"

    local build_dir="/lib/modules/${KVER}/build"
    [ -e "$build_dir" ] || die "kernel headers still missing: $build_dir not found"
    ok "Kernel headers present: $build_dir"
}

# ---------------------------------------------------------------------------
# 3. AMD repositories
# ---------------------------------------------------------------------------
setup_repos() {
    step "Configuring repo.radeon.com repositories"

    install -d -m 0755 /etc/apt/keyrings
    if [ ! -s "$KEYRING" ]; then
        curl -fsSL "$KEY_URL" | gpg --dearmor -o "$KEYRING"
        chmod 0644 "$KEYRING"
        ok "Installed AMD signing key -> $KEYRING"
    else
        ok "AMD signing key already present"
    fi

    # Compute-only node: amd64 is sufficient. The i386 slices of the graphics
    # repo are only needed for 32-bit OpenGL, which an Instinct node has no use for.
    cat > /etc/apt/sources.list.d/rocm.list <<EOF
deb [arch=amd64 signed-by=${KEYRING}] https://repo.radeon.com/rocm/apt/${ROCM_VER} ${AMD_CODENAME} main
EOF
    cat > /etc/apt/sources.list.d/amdgpu.list <<EOF
deb [arch=amd64 signed-by=${KEYRING}] https://repo.radeon.com/amdgpu/${AMDGPU_VER}/ubuntu ${AMD_CODENAME} main
EOF
    cat > /etc/apt/sources.list.d/amdgpu-graphics.list <<EOF
deb [arch=amd64 signed-by=${KEYRING}] https://repo.radeon.com/graphics/${GRAPHICS_VER}/ubuntu ${AMD_CODENAME} main
EOF

    # Without this pin, distro packages (e.g. Debian's own libdrm) outrank AMD's
    # and you end up with a half-distro/half-AMD userspace that fails at runtime.
    cat > /etc/apt/preferences.d/rocm-pin-600 <<'EOF'
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

    apt-get update -qq
    ok "Repositories configured (ROCm ${ROCM_VER}, amdgpu ${AMDGPU_VER})"
}

# ---------------------------------------------------------------------------
# 4. Driver + ROCm packages
#
#    amdgpu-dkms      kernel mode driver (this is what makes the GPUs appear)
#    amdgpu-core      shared driver plumbing + libdrm-amdgpu userspace
#    rocm             full compute metapackage: HIP, ROCr, rocBLAS, MIOpen,
#                     RCCL, rocprofiler, amd-smi, rocm-smi, rocminfo, ...
#    *-udev-rules     0666 on /dev/kfd + renderD* so non-root can use the GPUs
# ---------------------------------------------------------------------------
install_packages() {
    step "Installing amdgpu-dkms and the ROCm ${ROCM_VER} stack"
    export DEBIAN_FRONTEND=noninteractive

    # The DKMS postinst builds the module immediately. On kernels that need the
    # source patch below, that build fails -- expected. We let it fail, patch,
    # then build explicitly and reconcile dpkg state in finalize_dpkg().
    apt-get install -y amdgpu-dkms amdgpu-core amdgpu-install \
        || warn "amdgpu-dkms build failed during unpack -- will patch and rebuild"

    apt-get install -y rocm \
        || warn "rocm install reported an error -- will retry after DKMS is fixed"

    apt-get install -y amdgpu-insecure-instinct-udev-rules \
        || warn "could not install Instinct udev rules (non-fatal; root access still works)"
}

# ---------------------------------------------------------------------------
# 5. Kernel API compatibility patch
#
#    Debian backported the newer 4-argument form of pci_resize_resource()
#        int pci_resize_resource(struct pci_dev *dev, int i, int size, int exclude_bars)
#    into its 6.12.x stable kernels, while AMD's 30.20 driver source still calls
#    the 3-argument form. Result: the DKMS build dies with
#        amdgpu_device.c: error: too few arguments to function 'pci_resize_resource'
#    and the GPUs fall back to the in-tree amdgpu, which has no gfx950 support,
#    so every GPU fails probe with "Fatal error during GPU init ... error -22".
#
#    exclude_bars is a bitmask of BARs to keep rather than release, so passing 0
#    reproduces the old 3-argument behaviour exactly.
#
#    We detect the kernel's actual signature, so this is a no-op on Ubuntu and on
#    any kernel that still uses the 3-argument form.
# ---------------------------------------------------------------------------
patch_dkms_source() {
    step "Checking amdgpu source against this kernel's pci_resize_resource() API"

    local src_dir src pci_h
    src_dir="$(find /usr/src -maxdepth 1 -type d -name 'amdgpu-*' | sort -V | tail -1)"
    [ -n "$src_dir" ] || die "amdgpu DKMS source not found under /usr/src"
    src="${src_dir}/amd/amdgpu/amdgpu_device.c"
    [ -f "$src" ] || die "expected source file missing: $src"

    # -L so we follow Debian's build -> /usr/src/linux-headers-*-common symlinks.
    pci_h="$(find -L "/lib/modules/${KVER}/build" -maxdepth 3 -path '*/include/linux/pci.h' -print -quit 2>/dev/null || true)"
    if [ -z "$pci_h" ]; then
        warn "could not locate kernel pci.h; skipping compatibility check"
        return 0
    fi

    if ! grep -A2 'pci_resize_resource' "$pci_h" | grep -q 'exclude_bars'; then
        ok "Kernel uses the 3-argument API -- no patch needed"
        return 0
    fi

    if ! grep -q 'pci_resize_resource(adev->pdev, 0, rbar_size);' "$src"; then
        ok "Kernel uses the 4-argument API -- source already compatible/patched"
        return 0
    fi

    warn "Kernel uses the 4-argument API but the driver source does not -- patching"
    [ -f "${src}.orig" ] || cp -a "$src" "${src}.orig"
    sed -i \
        's|r = pci_resize_resource(adev->pdev, 0, rbar_size);|r = pci_resize_resource(adev->pdev, 0, rbar_size, 0); /* local patch: 4-arg pci_resize_resource */|' \
        "$src"
    grep -q 'rbar_size, 0)' "$src" || die "patch did not apply to $src"
    ok "Patched $src (original saved as ${src##*/}.orig)"
}

# ---------------------------------------------------------------------------
# 6. Build and install the DKMS module
# ---------------------------------------------------------------------------
build_dkms() {
    step "Building amdgpu DKMS module for $KVER"

    local ver
    ver="$(find /usr/src -maxdepth 1 -type d -name 'amdgpu-*' | sort -V | tail -1 | sed 's#.*/amdgpu-##')"
    [ -n "$ver" ] || die "cannot determine amdgpu DKMS version"

    if dkms status -m amdgpu -v "$ver" -k "$KVER" 2>/dev/null | grep -q 'installed'; then
        ok "amdgpu/$ver already installed for $KVER"
        return 0
    fi

    # Clear any half-built state from the failed postinst run.
    dkms remove "amdgpu/$ver" -k "$KVER" >/dev/null 2>&1 || true

    if ! dkms build "amdgpu/$ver" -k "$KVER"; then
        echo
        warn "Build failed. Errors from the DKMS log:"
        grep -E 'error:' "/var/lib/dkms/amdgpu/$ver/build/make.log" 2>/dev/null | head -20 || true
        die "DKMS build failed -- see /var/lib/dkms/amdgpu/$ver/build/make.log"
    fi

    dkms install "amdgpu/$ver" -k "$KVER" --force
    ok "amdgpu/$ver built and installed"
}

# ---------------------------------------------------------------------------
# 7. Reconcile dpkg, initramfs, runtime config
# ---------------------------------------------------------------------------
finalize() {
    step "Finalizing system configuration"
    export DEBIAN_FRONTEND=noninteractive

    # The earlier DKMS failure leaves linux-headers-* unconfigured; now that the
    # module builds, these succeed.
    dpkg --configure -a || true
    apt-get install -f -y >/dev/null 2>&1 || true
    apt-get install -y rocm >/dev/null 2>&1 || warn "rocm metapackage still incomplete"
    if dpkg --audit 2>/dev/null | grep -q .; then
        warn "dpkg reports packages still not fully configured:"
        dpkg --audit | head -10
    else
        ok "dpkg state clean"
    fi

    update-initramfs -u -k all >/dev/null 2>&1 || true
    ok "initramfs regenerated"

    local rocm_lib
    rocm_lib="$(find /opt -maxdepth 1 -name 'rocm-*' -type d | sort -V | tail -1)"
    if [ -n "$rocm_lib" ]; then
        echo "${rocm_lib}/lib" > /etc/ld.so.conf.d/rocm.conf
        ldconfig
        ok "Linker path configured: ${rocm_lib}/lib"
    fi

    cat > /etc/profile.d/rocm.sh <<'EOF'
# ROCm toolchain on PATH for all users
if [ -d /opt/rocm/bin ]; then
    case ":$PATH:" in
        *:/opt/rocm/bin:*) ;;
        *) PATH="/opt/rocm/bin:$PATH"; export PATH ;;
    esac
fi
EOF
    ok "/etc/profile.d/rocm.sh written (adds /opt/rocm/bin to PATH)"

    # Non-root GPU access requires membership in render + video.
    getent group render >/dev/null || groupadd -r render
    getent group video  >/dev/null || groupadd -r video
    local u
    u="${SUDO_USER:-}"
    if [ -n "$u" ] && [ "$u" != "root" ]; then
        usermod -aG render,video "$u"
        ok "Added '$u' to render+video groups (re-login required to take effect)"
    else
        warn "Run 'usermod -aG render,video <user>' for each non-root GPU user"
    fi

    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 8. Load the driver without a reboot, if possible
# ---------------------------------------------------------------------------
reload_module() {
    [ "$RELOAD_MODULE" -eq 1 ] || { warn "--no-reload given; reboot to activate the driver"; return 0; }

    step "Activating the new driver"

    local running
    running="$(cat /sys/module/amdgpu/version 2>/dev/null || echo none)"

    if ! modprobe -r amdgpu 2>/dev/null; then
        warn "Could not unload the running amdgpu (GPUs in use?). Reboot to activate."
        return 0
    fi
    sleep 2
    if ! modprobe amdgpu; then
        warn "modprobe amdgpu failed; check 'dmesg | grep amdgpu'. Reboot to retry."
        return 0
    fi
    sleep 10

    local now
    now="$(cat /sys/module/amdgpu/version 2>/dev/null || echo none)"
    ok "amdgpu module version: ${running} -> ${now}"
}

# ---------------------------------------------------------------------------
# 9. Verification
# ---------------------------------------------------------------------------
verify() {
    step "Verification"
    local rc=0

    local ver
    ver="$(cat /sys/module/amdgpu/version 2>/dev/null || true)"
    if [ -n "$ver" ]; then ok "amdgpu loaded, version $ver"
    else warn "amdgpu not loaded"; rc=1; fi

    if dkms status 2>/dev/null | grep -q 'amdgpu.*installed'; then
        ok "DKMS: $(dkms status | grep -m1 amdgpu)"
    else
        warn "DKMS module not installed for this kernel"; rc=1
    fi

    # Confirm the DKMS module -- not the distro in-tree one -- wins at boot.
    if grep -q 'updates/dkms/amdgpu.ko' "/lib/modules/${KVER}/modules.dep" 2>/dev/null; then
        ok "modules.dep resolves amdgpu to the DKMS build (persists across reboot)"
    else
        warn "amdgpu does not resolve to updates/dkms -- the in-tree driver may win at boot"; rc=1
    fi

    if [ -c /dev/kfd ]; then ok "/dev/kfd present"; else warn "/dev/kfd missing"; rc=1; fi

    # Only probe failures newer than the last successful init matter -- a box that
    # was just fixed still carries the old failures in its ring buffer.
    local ts='s/^\[ *\([0-9.]*\)\].*/\1/'
    local last_fatal last_init fatal inited
    last_fatal="$(dmesg 2>/dev/null | grep 'Fatal error during GPU init' | tail -1 | sed "$ts")"
    last_init="$(dmesg  2>/dev/null | grep 'Initialized amdgpu .* for 0000:' | tail -1 | sed "$ts")"
    fatal="$(dmesg 2>/dev/null | grep -c 'Fatal error during GPU init' || true)"
    inited="$(dmesg 2>/dev/null | grep -c 'Initialized amdgpu .* for 0000:' || true)"

    ok "GPUs successfully initialized in dmesg: $inited"
    if [ "$fatal" -gt 0 ]; then
        if [ -n "$last_init" ] && [ -n "$last_fatal" ] \
           && awk "BEGIN{exit !($last_init > $last_fatal)}"; then
            ok "$fatal stale 'Fatal error during GPU init' line(s) predate the last successful init -- ignore"
        else
            warn "$fatal 'Fatal error during GPU init' line(s) are NEWER than the last successful init"
            rc=1
        fi
    fi

    if command -v rocminfo >/dev/null 2>&1; then
        local agents
        agents="$(rocminfo 2>/dev/null | grep -c 'gfx950' || true)"
        if [ "$agents" -gt 0 ]; then ok "rocminfo reports gfx950 agents (count incl. ISA lines: $agents)"
        else warn "rocminfo found no gfx950 agents"; rc=1; fi
    fi

    if command -v rocm-smi >/dev/null 2>&1; then
        echo
        rocm-smi 2>/dev/null | grep -vi 'low-power state' || true
        echo
        # rocm-smi false-positives this on GPUs with compute partitions; check the
        # physical devices directly instead.
        local bad=0 d
        for d in /sys/bus/pci/drivers/amdgpu/0000:*; do
            [ -e "$d/power/runtime_status" ] || continue
            [ "$(cat "$d/power/runtime_status")" = "active" ] || bad=$((bad+1))
        done
        if [ "$bad" -eq 0 ]; then ok "all bound GPUs report runtime_status=active"
        else warn "$bad GPU(s) not in active power state"; rc=1; fi
    fi

    if command -v amd-smi >/dev/null 2>&1; then
        local ngpu
        ngpu="$(amd-smi list 2>/dev/null | grep -c '^GPU:' || true)"
        if [ "$ngpu" -gt 0 ]; then ok "amd-smi enumerates $ngpu GPU(s)"
        else warn "amd-smi enumerates no GPUs"; rc=1; fi
    fi

    # SMI tools can enumerate GPUs that HIP still cannot use; compile and run a
    # real kernel so the result means something.
    if [ -x /opt/rocm/bin/hipcc ]; then
        step "End-to-end HIP test (compile + launch a real kernel)"
        local tmp; tmp="$(mktemp -d)"
        cat > "$tmp/t.cpp" <<'EOF'
#include <hip/hip_runtime.h>
#include <cstdio>
__global__ void k(float* a) { a[threadIdx.x] = threadIdx.x * 2.0f; }
int main() {
    int n = 0;
    if (hipGetDeviceCount(&n) != hipSuccess || n == 0) { printf("no HIP devices\n"); return 1; }
    printf("HIP devices: %d\n", n);
    for (int i = 0; i < n; i++) {
        hipDeviceProp_t p;
        if (hipGetDeviceProperties(&p, i) != hipSuccess) continue;
        printf("  [%d] %s  arch=%s  VRAM=%.1f GB  CUs=%d\n",
               i, p.name, p.gcnArchName, p.totalGlobalMem / 1073741824.0, p.multiProcessorCount);
    }
    float *d = nullptr, h[64] = {0};
    if (hipSetDevice(0) != hipSuccess || hipMalloc(&d, sizeof(h)) != hipSuccess) return 1;
    hipLaunchKernelGGL(k, dim3(1), dim3(64), 0, 0, d);
    if (hipDeviceSynchronize() != hipSuccess) { printf("sync failed\n"); return 1; }
    if (hipMemcpy(h, d, sizeof(h), hipMemcpyDeviceToHost) != hipSuccess) return 1;
    hipFree(d);
    printf("kernel result h[10]=%.1f (expected 20.0) -> %s\n", h[10], h[10] == 20.0f ? "PASS" : "FAIL");
    return h[10] == 20.0f ? 0 : 1;
}
EOF
        if /opt/rocm/bin/hipcc -w -o "$tmp/t" "$tmp/t.cpp" >/dev/null 2>&1 && "$tmp/t"; then
            ok "HIP compute verified end-to-end"
        else
            warn "HIP test failed -- driver is up but the compute stack is not usable"; rc=1
        fi
        rm -rf "$tmp"
    fi

    echo
    if [ "$rc" -eq 0 ]; then
        printf '%s==> MI350 driver + ROCm stack is operational.%s\n' "$C_OK" "$C_OFF"
    else
        printf '%s==> Completed with warnings -- review the output above.%s\n' "$C_WARN" "$C_OFF"
        printf '    Useful next steps: dmesg | grep -i amdgpu ; dkms status ; journalctl -b -k\n'
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    if [ "$MODE" = "verify" ]; then
        [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
        # shellcheck disable=SC1091
        . /etc/os-release
        verify
        exit $?
    fi

    preflight
    install_build_deps
    setup_repos
    install_packages
    patch_dkms_source
    build_dkms
    finalize
    reload_module
    verify || true

    step "Done"
    cat <<EOF
  If any GPU is still missing, reboot and re-run:  sudo $0 verify

  Maintenance notes:
    * Kernel upgrades are handled automatically -- DKMS rebuilds from /usr/src,
      where the compatibility patch lives.
    * Upgrading amdgpu-dkms itself REPLACES /usr/src and drops the patch. After
      any ROCm/amdgpu package upgrade, re-run this script; it will re-detect and
      re-apply the patch only if the kernel still needs it.
    * Every installed kernel needs its own DKMS build. Check with 'dkms status';
      booting a kernel with no build means no GPUs.
EOF
}

main
