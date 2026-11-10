#!/usr/bin/env bash
# wLua preflight: compatibility checks and startup diagnostics.
# Sourced by start.sh. Safe to source from tests (no work at import time).
# This library never changes kernel sysctl, never elevates privileges,
# never builds the project, and never attaches to a process until the
# caller explicitly runs the injection path.

# Exit codes (stable; documented in docs/COMPATIBILITY.md)
WLUA_EX_OK=0
WLUA_EX_USAGE=1
WLUA_EX_NO_PROCESS=2
WLUA_EX_PERM_PROCESS=3
WLUA_EX_NO_LIB=4
WLUA_EX_NO_HOOKSO=5
WLUA_EX_NO_GDB=6
WLUA_EX_UNSUPPORTED=7
WLUA_EX_LUA_COMPAT=8
WLUA_EX_SYMBOLS=9
WLUA_EX_PTRACE=10
WLUA_EX_SYMBOL_RESOLVE=11
WLUA_EX_INJECT=12

WLUA_REQUIRED_SYMBOLS=(
    luaO_nilobject_
    luaH_resize
    luaH_get
    luaH_set
    luaC_fullgc
    luaC_step
    luaC_newobj
    luaS_new
    luaS_newlstr
)

WLUA_HOOK_FUNCS=(
    luaH_resize
    luaH_get
    luaH_set
    luaC_fullgc
    luaC_step
    luaC_newobj
    luaS_new
    luaS_newlstr
)

# Vendored interpreter this tree is compiled against (lua/lua.h).
WLUA_BUNDLED_LUA_VERSION="5.3.4"

wlua_err() { printf 'Error: %s\n' "$*" >&2; }
wlua_note() { printf '%s\n' "$*" >&2; }
wlua_hint() { printf '  %s\n' "$*" >&2; }

wlua_cmd_exists() {
    local name="$1"
    case ",${WLUA_HIDE_CMDS-}," in
        *,"$name",*) return 1 ;;
    esac
    command -v "$name" >/dev/null 2>&1
}

wlua_self_pid() {
    if [[ -n "${WLUA_SELF_PID-}" ]]; then
        printf '%s\n' "$WLUA_SELF_PID"
        return 0
    fi
    printf '%s\n' "$$"
}

wlua_self_euid() {
    if [[ -n "${WLUA_SELF_EUID-}" ]]; then
        printf '%s\n' "$WLUA_SELF_EUID"
        return 0
    fi
    id -u
}

wlua_uname() {
    if [[ -n "${WLUA_UNAME-}" ]]; then
        # shellcheck disable=SC2086
        $WLUA_UNAME "$@"
        return
    fi
    uname "$@"
}

wlua_proc_root() {
    printf '%s\n' "${WLUA_PROC_ROOT:-/proc}"
}

wlua_proc_path() {
    local pid="$1"
    local rest="$2"
    printf '%s/%s/%s\n' "$(wlua_proc_root)" "$pid" "$rest"
}

wlua_print_usage() {
    cat <<EOF
Usage: ${WLUA_APP_NAME:-start.sh} [--dry-run|--check] <PID>
       ${WLUA_APP_NAME:-start.sh} --help

Attach wLua to a running Linux x86_64 process that embeds PUC-Rio Lua 5.3.

  --dry-run, --check   Run compatibility and startup diagnostics only; do not inject.
  --help, -h           Show this help.

Exit codes:
  0  success (dry-run: preflight passed; otherwise hooks installed)
  1  usage or argument error
  2  process does not exist or has exited
  3  process records are not accessible
  4  libwlua.so is missing or not a usable shared library
  5  hookso is missing or not executable
  6  gdb is missing
  7  unsupported platform or architecture
  8  Lua version unknown or unsupported
  9  required Lua symbols were not found
  10 ptrace or attach permission is restricted
  11 symbol address resolution failed
  12 injection or hook installation failed

wLua will not change kernel.yama.ptrace_scope, elevate privileges, or build
missing artifacts. A detected Lua 5.3 version string is not proof of ABI
compatibility. See docs/COMPATIBILITY.md.
EOF
}

# Parse argv. Sets WLUA_ARG_PID, WLUA_DRY_RUN (0/1). Returns usage code on error.
wlua_parse_args() {
    WLUA_ARG_PID=""
    if [[ "${WLUA_DRY_RUN-}" != "1" ]]; then
        WLUA_DRY_RUN=0
    fi

    if [[ $# -lt 1 ]]; then
        wlua_err "missing PID."
        wlua_print_usage >&2
        return "$WLUA_EX_USAGE"
    fi

    case "$1" in
        -h|--help)
            wlua_print_usage
            return 99
            ;;
        --dry-run|--check)
            WLUA_DRY_RUN=1
            if [[ $# -lt 2 ]]; then
                wlua_err "--dry-run requires a PID."
                wlua_print_usage >&2
                return "$WLUA_EX_USAGE"
            fi
            if [[ $# -gt 2 ]]; then
                wlua_err "unexpected argument: $3"
                wlua_print_usage >&2
                return "$WLUA_EX_USAGE"
            fi
            WLUA_ARG_PID="$2"
            ;;
        --)
            shift
            if [[ $# -ne 1 ]]; then
                wlua_err "expected a single PID."
                wlua_print_usage >&2
                return "$WLUA_EX_USAGE"
            fi
            WLUA_ARG_PID="$1"
            ;;
        -*)
            wlua_err "unknown option: $1"
            wlua_print_usage >&2
            return "$WLUA_EX_USAGE"
            ;;
        *)
            if [[ $# -ne 1 ]]; then
                wlua_err "unexpected argument: $2"
                wlua_print_usage >&2
                return "$WLUA_EX_USAGE"
            fi
            WLUA_ARG_PID="$1"
            ;;
    esac
    return 0
}

wlua_validate_pid() {
    local pid="$1"
    if [[ -z "$pid" ]]; then
        wlua_err "missing PID."
        wlua_hint "Usage: ${WLUA_APP_NAME:-start.sh} [--dry-run] <PID>"
        wlua_hint "PID must be a positive integer."
        return "$WLUA_EX_USAGE"
    fi
    if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
        wlua_err "invalid PID '$pid'."
        wlua_hint "Usage: ${WLUA_APP_NAME:-start.sh} [--dry-run] <PID>"
        wlua_hint "PID must be a positive integer (digits only). This rejects path-like values."
        return "$WLUA_EX_USAGE"
    fi
    return 0
}

# Returns 0 if host is a supported Linux x86_64 environment.
wlua_check_platform() {
    local sys mach
    sys="$(wlua_uname -s 2>/dev/null || true)"
    mach="$(wlua_uname -m 2>/dev/null || true)"
    if [[ "$sys" != "Linux" ]]; then
        wlua_err "unsupported platform '${sys:-unknown}/${mach:-unknown}'. wLua only supports Linux x86_64."
        wlua_hint "The injector (hookso), gdb attach, and /proc-based checks are Linux-specific."
        return "$WLUA_EX_UNSUPPORTED"
    fi
    case "$mach" in
        x86_64|amd64)
            return 0
            ;;
        *)
            wlua_err "unsupported architecture '${mach:-unknown}'. wLua only supports Linux x86_64."
            wlua_hint "Other Linux architectures (including aarch64 and i386) are unproven and are rejected."
            wlua_hint "This script will not attempt injection on an unproven platform."
            return "$WLUA_EX_UNSUPPORTED"
            ;;
    esac
}

wlua_process_dir() {
    local pid="$1"
    printf '%s/%s\n' "$(wlua_proc_root)" "$pid"
}

# Read a field from /proc/<pid>/status. Prints empty if missing.
wlua_status_field() {
    local pid="$1"
    local field="$2"
    local status
    status="$(wlua_proc_path "$pid" status)"
    if [[ ! -r "$status" ]]; then
        return 1
    fi
    awk -v f="$field" 'BEGIN{FS=":"} $1==f {sub(/^[ \t]+/, "", $2); print $2; exit}' "$status"
}

wlua_check_process() {
    local pid="$1"
    local dir status
    dir="$(wlua_process_dir "$pid")"
    status="$(wlua_proc_path "$pid" status)"

    if [[ ! -e "$dir" && ! -d "$dir" ]]; then
        wlua_err "process $pid does not exist or has already exited."
        wlua_hint "Check the PID (ps -p $pid) and restart the target if needed."
        return "$WLUA_EX_NO_PROCESS"
    fi

    if [[ ! -r "$status" ]]; then
        if [[ -e "$dir" ]]; then
            wlua_err "process $pid exists but its /proc records are not accessible (permission denied)."
            wlua_hint "Run as the same user as the target, or as root. wLua will not change credentials or ptrace sysctl."
            return "$WLUA_EX_PERM_PROCESS"
        fi
        wlua_err "process $pid does not exist or has already exited."
        wlua_hint "Check the PID (ps -p $pid) and restart the target if needed."
        return "$WLUA_EX_NO_PROCESS"
    fi

    local state
    state="$(wlua_status_field "$pid" State || true)"
    case "$state" in
        Z*)
            wlua_err "process $pid is a zombie and cannot be attached."
            wlua_hint "The process has already exited; its parent has not reaped it yet. Restart the target."
            return "$WLUA_EX_NO_PROCESS"
            ;;
        X*)
            wlua_err "process $pid is dead and cannot be attached."
            return "$WLUA_EX_NO_PROCESS"
            ;;
    esac
    return 0
}

wlua_find_libwlua() {
    local script_dir="$1"
    local candidate
    if [[ -n "${WLUA_LIB_SO-}" ]]; then
        candidate="$WLUA_LIB_SO"
        if [[ ! -f "$candidate" ]]; then
            wlua_err "libwlua.so not found at WLUA_LIB_SO=$candidate."
            wlua_hint "Build it first with ./build.sh (this script will not build it automatically)."
            return "$WLUA_EX_NO_LIB"
        fi
        printf '%s\n' "$candidate"
        return 0
    fi

    for candidate in "${script_dir}/libwlua.so" "${script_dir}/build/libwlua.so"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    wlua_err "libwlua.so not found in ${script_dir} or ${script_dir}/build."
    wlua_hint "Build it first with ./build.sh (or cmake; see README). This script will not build it automatically."
    return "$WLUA_EX_NO_LIB"
}

wlua_find_hookso() {
    local script_dir="$1"
    local local_bin="${script_dir}/hookso"
    if [[ -n "${WLUA_HOOKSO-}" ]]; then
        if [[ -f "$WLUA_HOOKSO" || -x "$WLUA_HOOKSO" ]] && [[ "$WLUA_HOOKSO" == /* || "$WLUA_HOOKSO" == ./* || "$WLUA_HOOKSO" == *"/"* ]]; then
            if [[ ! -e "$WLUA_HOOKSO" ]]; then
                wlua_err "hookso not found at WLUA_HOOKSO=$WLUA_HOOKSO."
                wlua_hint "Download and build hookso from https://github.com/esrrhs/hookso and place the binary in ${script_dir} or PATH."
                return "$WLUA_EX_NO_HOOKSO"
            fi
            if [[ ! -x "$WLUA_HOOKSO" ]]; then
                wlua_err "hookso at $WLUA_HOOKSO is not executable."
                wlua_hint "chmod +x \"$WLUA_HOOKSO\". wLua will not change file permissions for you."
                return "$WLUA_EX_NO_HOOKSO"
            fi
            printf '%s\n' "$WLUA_HOOKSO"
            return 0
        fi
        if wlua_cmd_exists "$WLUA_HOOKSO"; then
            command -v "$WLUA_HOOKSO"
            return 0
        fi
        if [[ -x "$WLUA_HOOKSO" ]]; then
            printf '%s\n' "$WLUA_HOOKSO"
            return 0
        fi
        wlua_err "hookso not found at WLUA_HOOKSO=$WLUA_HOOKSO."
        wlua_hint "Download and build hookso from https://github.com/esrrhs/hookso and place the binary in ${script_dir} or PATH."
        return "$WLUA_EX_NO_HOOKSO"
    fi

    if [[ -e "$local_bin" ]]; then
        if [[ ! -x "$local_bin" ]]; then
            wlua_err "hookso was found at $local_bin but is not executable."
            wlua_hint "chmod +x \"$local_bin\". wLua will not change file permissions for you, and will not silently use another hookso from PATH."
            return "$WLUA_EX_NO_HOOKSO"
        fi
        printf '%s\n' "$local_bin"
        return 0
    fi

    if wlua_cmd_exists hookso; then
        command -v hookso
        return 0
    fi

    wlua_err "hookso binary not found in ${script_dir} or PATH."
    wlua_hint "Download and build hookso from https://github.com/esrrhs/hookso and place the binary in ${script_dir} or PATH."
    return "$WLUA_EX_NO_HOOKSO"
}

wlua_check_gdb() {
    local gdb_cmd="${WLUA_GDB:-gdb}"
    if ! wlua_cmd_exists "$gdb_cmd"; then
        wlua_err "gdb is required but was not found in PATH (${gdb_cmd})."
        wlua_hint "Install gdb (for example: apt install gdb / yum install gdb / pacman -S gdb)."
        wlua_hint "gdb is used at attach time to resolve symbol addresses. This script will not install it."
        return "$WLUA_EX_NO_GDB"
    fi
    return 0
}

# Print: CLASS WORDSIZE MACHINE   e.g.  ELF 64 x86_64
# Returns 1 if the file is not a readable ELF.
wlua_elf_info() {
    local file="$1"
    if [[ ! -r "$file" ]]; then
        return 1
    fi
    local bytes
    if wlua_cmd_exists od; then
        bytes="$(od -An -t u1 -N 20 "$file" 2>/dev/null | tr -s '[:space:]' ' ')"
        bytes="${bytes# }"
        bytes="${bytes% }"
    elif wlua_cmd_exists python3; then
        bytes="$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(20); print(" ".join(str(b) for b in d))' "$file" 2>/dev/null || true)"
    else
        return 1
    fi
    # shellcheck disable=SC2206
    local b=($bytes)
    if [[ ${#b[@]} -lt 20 ]]; then
        return 1
    fi
    # 0x7F E L F
    if [[ "${b[0]}" != "127" || "${b[1]}" != "69" || "${b[2]}" != "76" || "${b[3]}" != "70" ]]; then
        return 1
    fi
    local cls data em_lo em_hi mach word
    cls="${b[4]}"
    data="${b[5]}"
    if [[ "$data" == "1" ]]; then
        em_lo="${b[18]}"
        em_hi="${b[19]}"
    elif [[ "$data" == "2" ]]; then
        em_lo="${b[19]}"
        em_hi="${b[18]}"
    else
        return 1
    fi
    mach=$((em_lo + em_hi * 256))
    case "$cls" in
        1) word=32 ;;
        2) word=64 ;;
        *) return 1 ;;
    esac
    local name="unknown($mach)"
    case "$mach" in
        3) name="i386" ;;
        62) name="x86_64" ;;
        40) name="arm" ;;
        183) name="aarch64" ;;
        243) name="riscv" ;;
    esac
    printf 'ELF %s %s\n' "$word" "$name"
    return 0
}

wlua_elf_machine() {
    local info
    info="$(wlua_elf_info "$1")" || return 1
    # shellcheck disable=SC2086
    set -- $info
    printf '%s\n' "$3"
}

wlua_require_elf_x86_64() {
    local path="$1"
    local what="$2"
    local info word mach
    if ! info="$(wlua_elf_info "$path")"; then
        wlua_err "$what at $path is not a readable ELF file."
        wlua_hint "A Linux x86_64 ELF is required. Rebuild or replace this file."
        return "$WLUA_EX_UNSUPPORTED"
    fi
    # shellcheck disable=SC2086
    set -- $info
    word="$2"
    mach="$3"
    if [[ "$word" != "64" || "$mach" != "x86_64" ]]; then
        wlua_err "$what at $path is ELF ${word}-bit ${mach}, but wLua only supports Linux x86_64."
        wlua_hint "Rebuild $what for x86_64, or use a matching target. Other architectures are unproven and are rejected."
        return "$WLUA_EX_UNSUPPORTED"
    fi
    return 0
}

wlua_target_exe() {
    local pid="$1"
    local exe
    exe="$(wlua_proc_path "$pid" exe)"
    printf '%s\n' "$exe"
}

wlua_check_arch_compat() {
    local pid="$1"
    local so_path="$2"
    local hookso_path="$3"
    local rc=0

    wlua_require_elf_x86_64 "$so_path" "libwlua.so" || return "$?"
    wlua_require_elf_x86_64 "$hookso_path" "hookso" || return "$?"

    local exe
    exe="$(wlua_target_exe "$pid")"
    if [[ ! -e "$exe" && ! -L "$exe" ]]; then
        wlua_err "cannot read the executable for process $pid to determine architecture."
        wlua_hint "The process may have exited, or /proc/$pid/exe is not accessible."
        if [[ ! -d "$(wlua_process_dir "$pid")" ]]; then
            return "$WLUA_EX_NO_PROCESS"
        fi
        wlua_hint "wLua will not inject when the target architecture cannot be determined."
        return "$WLUA_EX_UNSUPPORTED"
    fi
    if [[ ! -r "$exe" ]]; then
        wlua_err "cannot read the executable for process $pid to determine architecture (permission denied)."
        wlua_hint "Run as the same user as the target, or as root. wLua will not change credentials."
        return "$WLUA_EX_PERM_PROCESS"
    fi

    local info word mach
    if ! info="$(wlua_elf_info "$exe")"; then
        wlua_err "the executable of process $pid is not a readable ELF file; architecture is unknown."
        wlua_hint "wLua will not inject into an unknown or non-ELF target."
        return "$WLUA_EX_UNSUPPORTED"
    fi
    # shellcheck disable=SC2086
    set -- $info
    word="$2"
    mach="$3"
    if [[ "$word" != "64" || "$mach" != "x86_64" ]]; then
        wlua_err "target process $pid is ELF ${word}-bit ${mach}, which is not a supported/proven platform (Linux x86_64 only)."
        wlua_hint "libwlua.so and hookso must also match the target architecture; mixed ELF classes would crash or fail to inject."
        return "$WLUA_EX_UNSUPPORTED"
    fi

    local so_m hook_m
    so_m="$(wlua_elf_machine "$so_path")"
    hook_m="$(wlua_elf_machine "$hookso_path")"
    if [[ "$so_m" != "$mach" || "$hook_m" != "$mach" ]]; then
        wlua_err "architecture mismatch: target=$mach libwlua.so=$so_m hookso=$hook_m."
        wlua_hint "Rebuild libwlua.so and hookso for the target architecture. wLua will not inject a mismatched library."
        return "$WLUA_EX_UNSUPPORTED"
    fi
    return 0
}

wlua_hex_to_dec() {
    local h="$1"
    h="${h#0x}"
    h="${h#0X}"
    printf '%d\n' "$((16#$h))"
}

# CAP_SYS_PTRACE is bit 19.
wlua_self_has_cap_sys_ptrace() {
    local status="${WLUA_SELF_STATUS-}"
    if [[ -z "$status" ]]; then
        status="$(wlua_proc_root)/self/status"
    fi
    if [[ ! -r "$status" ]]; then
        return 1
    fi
    local cap
    cap="$(awk -F: '$1=="CapEff" {gsub(/^[ \t]+/, "", $2); print $2; exit}' "$status")"
    if [[ -z "$cap" ]]; then
        return 1
    fi
    local dec
    dec="$(wlua_hex_to_dec "$cap")"
    if (( dec & 0x80000 )); then
        return 0
    fi
    return 1
}

wlua_ptrace_scope_path() {
    printf '%s\n' "${WLUA_PTRACE_SCOPE_FILE:-/proc/sys/kernel/yama/ptrace_scope}"
}

wlua_read_ptrace_scope() {
    local f
    f="$(wlua_ptrace_scope_path)"
    if [[ ! -r "$f" ]]; then
        return 1
    fi
    tr -d ' \t\r\n' < "$f"
}

wlua_check_ptrace() {
    local pid="$1"
    local euid uid0 ppid tracer dumpable scope
    euid="$(wlua_self_euid)"

    local uid_line
    uid_line="$(wlua_status_field "$pid" Uid || true)"
    # Uid: real effective saved fs
    uid0="${uid_line%%$'\t'*}"
    uid0="${uid0%% *}"

    ppid="$(wlua_status_field "$pid" PPid || true)"
    ppid="${ppid%% *}"
    tracer="$(wlua_status_field "$pid" TracerPid || true)"
    tracer="${tracer%% *}"
    dumpable="$(wlua_status_field "$pid" Dumpable || true)"
    dumpable="${dumpable%% *}"

    if [[ -n "$tracer" && "$tracer" != "0" ]]; then
        wlua_err "process $pid is already being traced (TracerPid=$tracer)."
        wlua_hint "Another debugger or injector is attached. Detach it first, then retry."
        wlua_hint "wLua will not steal an existing ptrace session."
        return "$WLUA_EX_PTRACE"
    fi

    local privileged=0
    if [[ "$euid" == "0" ]] || wlua_self_has_cap_sys_ptrace; then
        privileged=1
    fi

    if [[ -n "$uid0" && "$uid0" != "$euid" && "$privileged" -ne 1 ]]; then
        wlua_err "process $pid runs as uid $uid0, but this tool is running as uid $euid."
        wlua_hint "ptrace to a different user is not permitted without privilege."
        wlua_hint "Re-run as the target user or as root. wLua will not change credentials or sysctl."
        return "$WLUA_EX_PTRACE"
    fi

    if [[ -n "$dumpable" && "$dumpable" != "1" && "$privileged" -ne 1 ]]; then
        wlua_err "process $pid is not dumpable (Dumpable=$dumpable), so ptrace attach is likely blocked."
        wlua_hint "The target (or its sandbox) cleared PR_SET_DUMPABLE. wLua will not change that flag."
        wlua_hint "Re-run as root, or use a target that remains dumpable for debugging."
        return "$WLUA_EX_PTRACE"
    fi

    if scope="$(wlua_read_ptrace_scope)"; then
        case "$scope" in
            3)
                wlua_err "ptrace is disabled (kernel.yama.ptrace_scope=3)."
                wlua_hint "Attach is not possible with the current kernel policy."
                wlua_hint "wLua will not change this setting. An administrator would need to adjust ptrace policy, or you can run in an environment that allows ptrace."
                return "$WLUA_EX_PTRACE"
                ;;
            2)
                if [[ "$privileged" -ne 1 ]]; then
                    wlua_err "kernel.yama.ptrace_scope=2 allows only a privileged process to attach, and CAP_SYS_PTRACE/root was not detected."
                    wlua_hint "Re-run as root, or have an administrator adjust ptrace policy."
                    wlua_hint "wLua will not change sysctl or elevate privileges."
                    return "$WLUA_EX_PTRACE"
                fi
                ;;
            1)
                local self
                self="$(wlua_self_pid)"
                if [[ "$privileged" -ne 1 && "$ppid" != "$self" ]]; then
                    wlua_err "kernel.yama.ptrace_scope=1 only allows a parent process (or a privileged process) to attach."
                    wlua_hint "This process (pid $self) is not the parent of $pid (PPid=${ppid:-unknown}), and CAP_SYS_PTRACE/root was not detected."
                    wlua_hint "Re-run from the target's parent, as root, or have an administrator adjust ptrace policy."
                    wlua_hint "wLua will not change sysctl or elevate privileges."
                    return "$WLUA_EX_PTRACE"
                fi
                ;;
            0)
                ;;
            "")
                ;;
            *)
                # Unknown yama value: do not claim it is safe.
                wlua_err "unknown kernel.yama.ptrace_scope value '$scope'; attach policy cannot be verified."
                wlua_hint "wLua will not inject when ptrace policy is unknown, and will not change sysctl."
                return "$WLUA_EX_PTRACE"
                ;;
        esac
    else
        wlua_note "Note: kernel.yama.ptrace_scope is not readable; no Yama restriction was detected."
        wlua_hint "ptrace may still be blocked by LSM, seccomp, or a container policy. That can only be confirmed if attach fails later."
    fi
    return 0
}

# List unique mapped file paths for a pid, plus the exe path.
wlua_mapped_files() {
    local pid="$1"
    local maps exe
    maps="$(wlua_proc_path "$pid" maps)"
    exe="$(wlua_target_exe "$pid")"
    local -A seen=()
    if [[ -e "$exe" || -L "$exe" ]]; then
        printf '%s\n' "$exe"
        seen["$exe"]=1
    fi
    if [[ ! -r "$maps" ]]; then
        return 0
    fi
    awk '{
        path=""
        if (NF >= 6) {
            path=$6
            for (i=7; i<=NF; i++) path=path " " $i
        }
        if (path != "" && path !~ /^\[/) print path
    }' "$maps" | while IFS= read -r p; do
        if [[ -n "$p" && -z "${seen[$p]+x}" ]]; then
            # The subshell cannot update parent seen; uniqueness below.
            printf '%s\n' "$p"
        fi
    done | awk '!( $0 in seen ){ seen[$0]=1; print }'
}

wlua_path_lua_kind() {
    local path="$1"
    local base
    base="$(basename -- "$path" 2>/dev/null || basename "$path")"
    local lower
    lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"

    case "$lower" in
        *luajit*)
            printf 'luajit\n'
            return 0
            ;;
    esac

    local ver=""
    if [[ "$lower" =~ liblua\.so\.([0-9]+)\.([0-9]+) ]]; then
        ver="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$lower" =~ liblua([0-9]+)\.([0-9]+) ]]; then
        ver="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$lower" =~ liblua-([0-9]+)\.([0-9]+) ]]; then
        ver="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ "$lower" =~ (^|[^a-z])lua([0-9]+)\.([0-9]+) ]]; then
        ver="${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
    elif [[ "$lower" =~ liblua\.so\.([0-9]+)([^0-9]|$) ]]; then
        ver="${BASH_REMATCH[1]}"
    elif [[ "$lower" =~ liblua([0-9]+)([^0-9.]|$) ]]; then
        # liblua53.so / lua53 / lua54
        local compact="${BASH_REMATCH[1]}"
        if [[ ${#compact} -eq 2 ]]; then
            ver="${compact:0:1}.${compact:1:1}"
        elif [[ ${#compact} -ge 3 ]]; then
            ver="${compact:0:1}.${compact:1}"
        fi
    elif [[ "$lower" =~ (^|[^a-z])lua([0-9][0-9])([^0-9]|$) ]]; then
        ver="${BASH_REMATCH[2]:0:1}.${BASH_REMATCH[2]:1:1}"
    fi

    if [[ -n "$ver" ]]; then
        printf 'lua%s\n' "$ver"
        return 0
    fi

    if [[ "$lower" == liblua.so* || "$lower" == liblua-*.so* ]]; then
        printf 'lua-unknown\n'
        return 0
    fi
    return 1
}

# Best-effort strings scan. Never used as ABI proof.
wlua_file_lua_strings() {
    local file="$1"
    if [[ ! -r "$file" ]]; then
        return 1
    fi
    local hits=""
    if wlua_cmd_exists grep; then
        hits="$(grep -aoE 'LuaJIT [0-9.]+|Lua 5\.[0-9]+(\.[0-9]+)?' "$file" 2>/dev/null | head -n 20 || true)"
    fi
    if [[ -z "$hits" ]]; then
        return 1
    fi
    if printf '%s\n' "$hits" | grep -q 'LuaJIT'; then
        printf 'luajit\n'
        return 0
    fi
    local vers
    vers="$(printf '%s\n' "$hits" | grep -oE 'Lua 5\.[0-9]+' | sed 's/Lua /lua/' | sort -u)"
    local n
    n="$(printf '%s\n' "$vers" | grep -c . || true)"
    if [[ "$n" -eq 1 ]]; then
        printf '%s\n' "$vers"
        return 0
    fi
    if [[ "$n" -gt 1 ]]; then
        printf 'lua-unknown\n'
        return 0
    fi
    return 1
}

# List symbol names present in a file (best effort, no process attach).
wlua_list_symbols() {
    local file="$1"
    if [[ ! -r "$file" ]]; then
        return 1
    fi
    if wlua_cmd_exists readelf; then
        # -s includes .symtab when present; dynsym otherwise.
        readelf -W -s "$file" 2>/dev/null | awk '{
            # last field is the name; skip empty / reserved
            name=$NF
            if (name != "" && name != "Name" && name != "ABS" && name !~ /^\[/) print name
        }'
        return 0
    fi
    if wlua_cmd_exists nm; then
        { nm -a "$file" 2>/dev/null || true; nm -D "$file" 2>/dev/null || true; } | awk '{print $NF}'
        return 0
    fi
    if wlua_cmd_exists objdump; then
        objdump -t "$file" 2>/dev/null | awk '{print $NF}'
        objdump -T "$file" 2>/dev/null | awk '{print $NF}'
        return 0
    fi
    return 2
}

wlua_file_has_symbol() {
    local file="$1"
    local sym="$2"
    local list rc=0
    list="$(wlua_list_symbols "$file")" || rc=$?
    if [[ $rc -eq 2 ]]; then
        return 2
    fi
    if [[ $rc -ne 0 ]]; then
        return 1
    fi
    printf '%s\n' "$list" | grep -Fxq -- "$sym"
}

wlua_classify_lua_kind() {
    local kind="$1"
    case "$kind" in
        luajit) printf 'luajit\n' ;;
        lua5.1|lua5.2|lua5.4|lua5.5|lua5.6|lua5.7) printf '%s\n' "$kind" ;;
        lua5.3) printf 'lua5.3\n' ;;
        lua5) printf 'lua5\n' ;;  # unversioned major from liblua.so.5
        lua-unknown) printf 'lua-unknown\n' ;;
        *) printf '%s\n' "$kind" ;;
    esac
}

# Inspect the target and set:
#   WLUA_DETECTED_LUA   (lua5.3 / luajit / lua5.4 / none / lua-unknown / ...)
#   WLUA_LUA_EVIDENCE   (human-readable)
#   WLUA_LUA_IMAGES     (newline-separated files considered)
wlua_inspect_lua() {
    local pid="$1"
    WLUA_DETECTED_LUA="none"
    WLUA_LUA_EVIDENCE=""
    WLUA_LUA_IMAGES=""

    local -a images=()
    local -a kinds=()
    local f kind
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # Skip clearly non-regular mappings that are not readable files.
        kind=""
        if kind="$(wlua_path_lua_kind "$f")"; then
            images+=("$f")
            kinds+=("$kind")
        else
            # Still consider the main exe for strings/symbols even if the name
            # is not lua-like; handled after the loop.
            :
        fi
    done < <(wlua_mapped_files "$pid")

    local exe
    exe="$(wlua_target_exe "$pid")"
    local exe_included=0
    for f in "${images[@]+"${images[@]}"}"; do
        if [[ "$f" == "$exe" ]]; then
            exe_included=1
            break
        fi
    done
    if [[ "$exe_included" -eq 0 && -r "$exe" ]]; then
        images+=("$exe")
        if kind="$(wlua_path_lua_kind "$exe")"; then
            kinds+=("$kind")
        else
            kinds+=("")
        fi
    fi

    local i
    for i in "${!images[@]}"; do
        f="${images[$i]}"
        kind="${kinds[$i]}"
        if [[ -z "$kind" || "$kind" == "lua-unknown" ]]; then
            local sk=""
            if sk="$(wlua_file_lua_strings "$f")"; then
                if [[ -z "$kind" || "$kind" == "lua-unknown" ]]; then
                    kinds[$i]="$sk"
                    kind="$sk"
                fi
                WLUA_LUA_EVIDENCE="${WLUA_LUA_EVIDENCE}strings in $f => $sk; "
            fi
        fi
        if [[ -n "$kind" ]]; then
            WLUA_LUA_EVIDENCE="${WLUA_LUA_EVIDENCE}path $f => $kind; "
        fi
    done

    WLUA_LUA_IMAGES="$(printf '%s\n' "${images[@]+"${images[@]}"}")"

    local -A uniq=()
    for kind in "${kinds[@]+"${kinds[@]}"}"; do
        [[ -z "$kind" ]] && continue
        uniq["$kind"]=1
    done

    if [[ ${#uniq[@]} -eq 0 ]]; then
        WLUA_DETECTED_LUA="none"
        return 0
    fi

    if [[ -n "${uniq[luajit]+x}" ]]; then
        WLUA_DETECTED_LUA="luajit"
        return 0
    fi

    local k supported=0 unsupported=""
    for k in "${!uniq[@]}"; do
        case "$k" in
            lua5.3) supported=1 ;;
            lua-unknown|lua5) ;; # inconclusive on its own
            lua5.*)
                unsupported="${unsupported}${k} "
                ;;
        esac
    done
    if [[ -n "$unsupported" ]]; then
        # Prefer a concrete unsupported version over "maybe 5.3".
        WLUA_DETECTED_LUA="$(printf '%s\n' $unsupported | head -n 1)"
        return 0
    fi
    if [[ "$supported" -eq 1 ]]; then
        WLUA_DETECTED_LUA="lua5.3"
        return 0
    fi
    WLUA_DETECTED_LUA="lua-unknown"
    return 0
}

wlua_symbol_search_files() {
    local pid="$1"
    # Prefer lua-related mapped objects; always include exe.
    local f kind
    local -A seen=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if kind="$(wlua_path_lua_kind "$f")"; then
            if [[ -z "${seen[$f]+x}" ]]; then
                printf '%s\n' "$f"
                seen["$f"]=1
            fi
        fi
    done < <(wlua_mapped_files "$pid")
    local exe
    exe="$(wlua_target_exe "$pid")"
    if [[ -z "${seen[$exe]+x}" ]]; then
        printf '%s\n' "$exe"
    fi
}

wlua_check_required_symbols() {
    local pid="$1"
    local -a files=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done < <(wlua_symbol_search_files "$pid")

    if [[ ${#files[@]} -eq 0 ]]; then
        wlua_err "no readable process image was found to search for Lua symbols in PID $pid."
        wlua_hint "The process may have exited, or /proc maps and exe are not accessible."
        if [[ ! -d "$(wlua_process_dir "$pid")" ]]; then
            return "$WLUA_EX_NO_PROCESS"
        fi
        return "$WLUA_EX_SYMBOLS"
    fi

    # If no symbol tool is available, we cannot prove symbols exist.
    local tool_rc=0
    local sample="${files[0]}"
    wlua_list_symbols "$sample" >/dev/null || tool_rc=$?
    if [[ $tool_rc -eq 2 ]]; then
        wlua_err "cannot inspect symbols: readelf, nm, and objdump were not found."
        wlua_hint "Install binutils (readelf or nm). wLua will not treat an unreadable symbol table as sufficient."
        wlua_hint "A Lua version string alone is not enough to proceed."
        return "$WLUA_EX_SYMBOLS"
    fi

    local missing=()
    local sym found rc
    for sym in "${WLUA_REQUIRED_SYMBOLS[@]}"; do
        found=0
        for f in "${files[@]}"; do
            [[ -r "$f" ]] || continue
            rc=0
            wlua_file_has_symbol "$f" "$sym" || rc=$?
            if [[ $rc -eq 0 ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            missing+=("$sym")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        wlua_err "required Lua symbol(s) not found in the target image(s): ${missing[*]}"
        wlua_hint "Searched: $(printf '%s ' "${files[@]}")"
        wlua_hint "Injection needs these internal symbols: ${WLUA_REQUIRED_SYMBOLS[*]}"
        wlua_hint "The binary may be stripped, use hidden visibility without a symbol table, or embed a different Lua."
        wlua_hint "Rebuild the target with symbols (or install debug symbols you can inspect), then retry. wLua will not inject without this proof."
        wlua_hint "A Lua version string is not a substitute for these symbols, and finding them is still not proof of ABI compatibility."
        return "$WLUA_EX_SYMBOLS"
    fi
    return 0
}

wlua_check_lua_compat() {
    local pid="$1"
    wlua_inspect_lua "$pid"

    case "$WLUA_DETECTED_LUA" in
        luajit)
            wlua_err "target process $pid looks like LuaJIT, which is not compatible with wLua."
            wlua_hint "wLua is compiled against PUC-Rio Lua ${WLUA_BUNDLED_LUA_VERSION} internals (hooks and structure layouts)."
            wlua_hint "Evidence: ${WLUA_LUA_EVIDENCE:-luajit detected}"
            wlua_hint "wLua will not inject into LuaJIT."
            return "$WLUA_EX_LUA_COMPAT"
            ;;
        lua5.1|lua5.2|lua5.4|lua5.5|lua5.6|lua5.7)
            wlua_err "target process $pid appears to use ${WLUA_DETECTED_LUA}, which is not compatible with wLua."
            wlua_hint "wLua is compiled against PUC-Rio Lua ${WLUA_BUNDLED_LUA_VERSION} internals. Other major/minor versions have different structures and symbols."
            wlua_hint "Evidence: ${WLUA_LUA_EVIDENCE:-versioned library/path}"
            wlua_hint "A version string or library soname is enough to reject an unsupported version, but is never used to claim ABI safety."
            return "$WLUA_EX_LUA_COMPAT"
            ;;
        none)
            wlua_err "could not determine a supported Lua VM in process $pid."
            wlua_hint "No liblua 5.3 mapping and no Lua-version evidence were found in the process images."
            wlua_hint "wLua will not inject into an unknown target."
            wlua_hint "If this is a statically linked Lua 5.3 program, preflight still needs version evidence (a Lua 5.3 string or a versioned liblua mapping) plus the required symbols."
            wlua_hint "Required symbols alone are not used to infer the version, because some names also exist in later Lua releases."
            return "$WLUA_EX_LUA_COMPAT"
            ;;
        lua-unknown|lua5)
            wlua_err "a Lua image was found in process $pid, but the exact version could not be determined."
            wlua_hint "Evidence: ${WLUA_LUA_EVIDENCE:-unversioned liblua}"
            wlua_hint "wLua will not inject when the Lua version is unknown. A version string alone would still not prove ABI compatibility with Lua ${WLUA_BUNDLED_LUA_VERSION}."
            return "$WLUA_EX_LUA_COMPAT"
            ;;
        lua5.3)
            # Continue to symbol checks. Do not claim ABI safety.
            ;;
        *)
            wlua_err "unsupported or unrecognized Lua variant '${WLUA_DETECTED_LUA}' in process $pid."
            wlua_hint "Evidence: ${WLUA_LUA_EVIDENCE:-n/a}"
            wlua_hint "wLua will not inject into an unknown target."
            return "$WLUA_EX_LUA_COMPAT"
            ;;
    esac

    wlua_check_required_symbols "$pid" || return "$?"

    wlua_note "Preflight: found evidence of PUC-Rio Lua 5.3 and the required internal symbols."
    wlua_note "Warning: this is not proof of ABI compatibility with vendored Lua ${WLUA_BUNDLED_LUA_VERSION} structure layouts."
    wlua_hint "Custom patches, LUA_32BITS, different LUA_NUMBER/LUA_INTEGER types, or other 5.3.x builds can still crash the target after injection."
    return 0
}

wlua_print_abi_warning() {
    wlua_note "Warning: a Lua 5.3 version string or soname is not proof of ABI compatibility with vendored Lua ${WLUA_BUNDLED_LUA_VERSION}."
}

# Full preflight. Prints resolved paths on success:
#   sets WLUA_RESOLVED_SO, WLUA_RESOLVED_HOOKSO
wlua_preflight() {
    local pid="$1"
    local script_dir="$2"

    wlua_validate_pid "$pid" || return "$?"
    wlua_check_platform || return "$?"
    wlua_check_process "$pid" || return "$?"

    local so hookso
    so="$(wlua_find_libwlua "$script_dir")" || return "$?"
    hookso="$(wlua_find_hookso "$script_dir")" || return "$?"
    wlua_check_gdb || return "$?"
    wlua_check_arch_compat "$pid" "$so" "$hookso" || return "$?"
    wlua_check_ptrace "$pid" || return "$?"
    wlua_check_lua_compat "$pid" || return "$?"

    # The process may have exited during inspection.
    wlua_check_process "$pid" || return "$?"

    WLUA_RESOLVED_SO="$so"
    WLUA_RESOLVED_HOOKSO="$hookso"
    return 0
}

wlua_classify_ptrace_like() {
    local text="$1"
    printf '%s' "$text" | grep -qiE 'operation not permitted|ptrace.*(denied|failed|prevent)|cannot attach|permission denied|yama'
}

wlua_classify_gone() {
    local text="$1"
    printf '%s' "$text" | grep -qiE 'no such process|process .* (exited|does not exist)|no process'
}

wlua_classify_arch() {
    local text="$1"
    printf '%s' "$text" | grep -qiE 'ELF class|wrong ELF|incompatible|machine type|architecture|exec format'
}

# gdb on a live process (used only during the injection path, not by tests).
wlua_get_symbol_addr() {
    local pid="$1"
    local sym="$2"
    local gdb_cmd="${WLUA_GDB:-gdb}"
    local raw addr
    raw="$("$gdb_cmd" -p "$pid" -ex "p (long)${sym}" --batch 2>&1)" || true
    if wlua_classify_gone "$raw"; then
        WLUA_LAST_GDB_ERR="gone"
        WLUA_LAST_GDB_OUT="$raw"
        return 2
    fi
    if wlua_classify_ptrace_like "$raw"; then
        WLUA_LAST_GDB_ERR="ptrace"
        WLUA_LAST_GDB_OUT="$raw"
        return 10
    fi
    addr="$(printf '%s\n' "$raw" | grep -E '\$[0-9]+ = ' | sed -E 's/.*\$[0-9]+ = (-?[0-9]+|0x[0-9a-fA-F]+).*/\1/' | tail -n 1 || true)"
    if [[ -z "$addr" ]]; then
        WLUA_LAST_GDB_ERR="symbol"
        WLUA_LAST_GDB_OUT="$raw"
        return 1
    fi
    printf '%s\n' "$addr"
    return 0
}

wlua_report_inject_failure() {
    local pid="$1"
    local step="$2"
    local out="$3"
    if [[ ! -d "$(wlua_process_dir "$pid")" ]]; then
        wlua_err "process $pid exited during $step."
        wlua_hint "The target is no longer running. Restart it and retry."
        return "$WLUA_EX_NO_PROCESS"
    fi
    if wlua_classify_gone "$out"; then
        wlua_err "process $pid disappeared during $step."
        wlua_hint "Restart the target and retry."
        return "$WLUA_EX_NO_PROCESS"
    fi
    if wlua_classify_ptrace_like "$out"; then
        wlua_err "$step failed because ptrace attach was denied for PID $pid."
        [[ -n "$out" ]] && wlua_hint "Tool output: $out"
        wlua_hint "This is commonly caused by kernel.yama.ptrace_scope, LSM/seccomp, or missing privilege."
        wlua_hint "wLua will not change sysctl or elevate privileges. Re-run as the target parent/root, or adjust ptrace policy yourself."
        return "$WLUA_EX_PTRACE"
    fi
    if wlua_classify_arch "$out"; then
        wlua_err "$step failed due to an architecture or ELF-class mismatch for PID $pid."
        [[ -n "$out" ]] && wlua_hint "Tool output: $out"
        wlua_hint "Rebuild libwlua.so and hookso for the target architecture."
        return "$WLUA_EX_INJECT"
    fi
    wlua_err "$step failed for PID $pid."
    [[ -n "$out" ]] && wlua_hint "Tool output: $out"
    wlua_hint "Check hookso, libwlua.so, and that the process is still running. wLua will not retry automatically or relax permissions."
    return "$WLUA_EX_INJECT"
}

wlua_run_hookso() {
    local hookso="$1"
    shift
    local out rc=0
    out="$("$hookso" "$@" 2>&1)" || rc=$?
    WLUA_LAST_HOOKSO_OUT="$out"
    if [[ $rc -ne 0 ]]; then
        return "$rc"
    fi
    if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
    fi
    return 0
}

# Injection path. Never called by --dry-run. Tests may invoke with mocked tools.
wlua_inject() {
    local pid="$1"
    local so_path="$2"
    local hookso="$3"

    wlua_check_process "$pid" || return "$?"

    rm -f wlua_result.log wlua_check.log

    wlua_note "==> Injecting ${so_path} into PID ${pid}..."
    local rc=0
    wlua_run_hookso "$hookso" dlopen "$pid" "$so_path" || rc=$?
    if [[ $rc -ne 0 ]]; then
        wlua_report_inject_failure "$pid" "hookso dlopen (library injection)" "${WLUA_LAST_HOOKSO_OUT-}"
        return "$?"
    fi
    wlua_note "==> Injected libwlua.so successfully."

    local nil_addr
    rc=0
    nil_addr="$(wlua_get_symbol_addr "$pid" "&luaO_nilobject_")" || rc=$?
    if [[ $rc -eq 2 ]]; then
        wlua_err "process $pid exited while resolving luaO_nilobject_."
        wlua_hint "Tool output: ${WLUA_LAST_GDB_OUT-}"
        return "$WLUA_EX_NO_PROCESS"
    fi
    if [[ $rc -eq 10 ]]; then
        wlua_err "gdb could not attach to PID $pid to resolve luaO_nilobject_ (ptrace denied)."
        wlua_hint "Tool output: ${WLUA_LAST_GDB_OUT-}"
        wlua_hint "wLua will not change sysctl or elevate privileges."
        return "$WLUA_EX_PTRACE"
    fi
    if [[ $rc -ne 0 || -z "$nil_addr" ]]; then
        wlua_err "failed to resolve luaO_nilobject_ in PID $pid (symbol address lookup failed)."
        wlua_hint "Tool output: ${WLUA_LAST_GDB_OUT-}"
        wlua_hint "The symbol may be stripped or unavailable at runtime despite passing the file-level preflight."
        wlua_hint "This is a symbol resolution failure, not a generic inject failure."
        return "$WLUA_EX_SYMBOL_RESOLVE"
    fi

    wlua_note "set_lua_nilobject ADDR=${nil_addr}"
    rc=0
    wlua_run_hookso "$hookso" call "$pid" libwlua.so set_lua_nilobject "i=${nil_addr}" || rc=$?
    if [[ $rc -ne 0 ]]; then
        wlua_report_inject_failure "$pid" "hookso call set_lua_nilobject" "${WLUA_LAST_HOOKSO_OUT-}"
        return "$?"
    fi

    local f addr
    for f in "${WLUA_HOOK_FUNCS[@]}"; do
        wlua_check_process "$pid" || return "$?"
        rc=0
        addr="$(wlua_get_symbol_addr "$pid" "$f")" || rc=$?
        if [[ $rc -eq 2 ]]; then
            wlua_err "process $pid exited while resolving $f."
            return "$WLUA_EX_NO_PROCESS"
        fi
        if [[ $rc -eq 10 ]]; then
            wlua_err "gdb could not attach to PID $pid to resolve $f (ptrace denied)."
            wlua_hint "Tool output: ${WLUA_LAST_GDB_OUT-}"
            wlua_hint "wLua will not change sysctl or elevate privileges."
            return "$WLUA_EX_PTRACE"
        fi
        if [[ $rc -ne 0 || -z "$addr" ]]; then
            wlua_err "failed to resolve $f in PID $pid (symbol address lookup failed)."
            wlua_hint "Tool output: ${WLUA_LAST_GDB_OUT-}"
            wlua_hint "This is a symbol resolution failure, not a generic inject failure."
            return "$WLUA_EX_SYMBOL_RESOLVE"
        fi
        wlua_note "Hooking $f ADDR=${addr} -> new_$f"
        rc=0
        wlua_run_hookso "$hookso" replacep "$pid" "$addr" "$so_path" "new_$f" || rc=$?
        if [[ $rc -ne 0 ]]; then
            wlua_report_inject_failure "$pid" "hookso replacep $f" "${WLUA_LAST_HOOKSO_OUT-}"
            return "$?"
        fi
    done

    wlua_note "==> All hooks installed successfully for PID ${pid}."
    wlua_note "==> Results will be written to wlua_result.log"
    return 0
}

wlua_main() {
    local script_dir="$1"
    shift

    local rc=0
    wlua_parse_args "$@" || rc=$?
    if [[ $rc -eq 99 ]]; then
        return 0
    fi
    if [[ $rc -ne 0 ]]; then
        return "$rc"
    fi

    local pid="$WLUA_ARG_PID"
    wlua_preflight "$pid" "$script_dir" || return "$?"

    if [[ "${WLUA_DRY_RUN}" == "1" ]]; then
        wlua_note "==> Dry-run: preflight passed for PID ${pid}."
        wlua_note "    libwlua.so: ${WLUA_RESOLVED_SO}"
        wlua_note "    hookso:     ${WLUA_RESOLVED_HOOKSO}"
        wlua_note "    No injection was attempted."
        wlua_print_abi_warning
        return 0
    fi

    wlua_inject "$pid" "$WLUA_RESOLVED_SO" "$WLUA_RESOLVED_HOOKSO" || return "$?"
    return 0
}
