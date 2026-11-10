#!/usr/bin/env bash
# Regression tests for wLua compatibility checks and startup diagnostics.
# No compiler, no ./build.sh, no real gdb attach, no real process injection.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="${ROOT}/scripts/wlua_preflight.sh"
START="${ROOT}/start.sh"

PASS=0
FAIL=0
# shellcheck disable=SC2034
TEST_DIR=""

die() { echo "FATAL: $*" >&2; exit 1; }

assert_ok() {
    local name="$1"
    shift
    if "$@"; then
        echo "PASS  $name"
        PASS=$((PASS + 1))
        return 0
    fi
    echo "FAIL  $name"
    FAIL=$((FAIL + 1))
    return 0
}

# Run a command, capture stdout+stderr and exit code.
run_cap() {
    local outrc
    # shellcheck disable=SC2034
    RUN_OUT=""
    RUN_RC=0
    set +e
    RUN_OUT="$("$@" 2>&1)"
    RUN_RC=$?
    set -e
}

expect_rc() {
    local name="$1"
    local expect="$2"
    shift 2
    run_cap "$@"
    if [[ "$RUN_RC" -eq "$expect" ]]; then
        echo "PASS  $name (exit $RUN_RC)"
        PASS=$((PASS + 1))
        return 0
    fi
    echo "FAIL  $name (expected exit $expect, got $RUN_RC)"
    echo "      output: $RUN_OUT"
    FAIL=$((FAIL + 1))
    return 0
}

expect_rc_contains() {
    local name="$1"
    local expect="$2"
    local needle="$3"
    shift 3
    run_cap "$@"
    local ok=1
    if [[ "$RUN_RC" -ne "$expect" ]]; then
        ok=0
        echo "FAIL  $name (expected exit $expect, got $RUN_RC)"
    fi
    if ! printf '%s' "$RUN_OUT" | grep -q -- "$needle"; then
        ok=0
        echo "FAIL  $name (output missing '$needle')"
    fi
    if [[ $ok -eq 1 ]]; then
        echo "PASS  $name (exit $RUN_RC, found '$needle')"
        PASS=$((PASS + 1))
    else
        echo "      output: $RUN_OUT"
        FAIL=$((FAIL + 1))
    fi
    return 0
}

expect_contains() {
    local name="$1"
    local needle="$2"
    if printf '%s' "$RUN_OUT" | grep -q -- "$needle"; then
        echo "PASS  $name (found '$needle')"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $name (output missing '$needle')"
        echo "      output: $RUN_OUT"
        FAIL=$((FAIL + 1))
    fi
}

expect_not_contains() {
    local name="$1"
    local needle="$2"
    if printf '%s' "$RUN_OUT" | grep -qi -- "$needle"; then
        echo "FAIL  $name (output unexpectedly matches '$needle')"
        echo "      output: $RUN_OUT"
        FAIL=$((FAIL + 1))
    else
        echo "PASS  $name (no '$needle')"
        PASS=$((PASS + 1))
    fi
}

# Minimal ELF64/32 with optional symbol table. Used only as fixtures.
write_elf() {
    python3 - "$@" << 'PY'
import struct, sys, pathlib

def strtab(names):
    data = b"\0"
    offs = {}
    for n in names:
        offs[n] = len(data)
        data += n.encode("ascii") + b"\0"
    return data, offs

def elf64(path, machine=62, symbols=None):
    symbols = list(symbols or [])
    shstr, shoff = strtab([".text", ".symtab", ".strtab", ".shstrtab"])
    strt, soffs = strtab(symbols)
    # Elf64_Sym is 24 bytes; first is STN_UNDEF
    symtab = b"\0" * 24
    STB_GLOBAL, STT_FUNC, STT_OBJECT = 1, 2, 1
    for s in symbols:
        info = (STB_GLOBAL << 4) | (STT_OBJECT if s.endswith("_") else STT_FUNC)
        symtab += struct.pack("<IBBHQQ", soffs[s], info, 0, 1, 0x1000, 8)
    text = b"\x90" * 16
    ehdr_size, shentsize, shnum = 64, 64, 5
    text_off = ehdr_size
    sym_off = text_off + len(text)
    str_off = sym_off + len(symtab)
    shstr_off = str_off + len(strt)
    shoff_off = (shstr_off + len(shstr) + 7) & ~7
    e_ident = bytes([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    ehdr = e_ident + struct.pack("<HHIQQQIHHHHHH",
        3, machine, 1, 0, 0, shoff_off, 0, ehdr_size, 0, 0, shentsize, shnum, 4)
    def shdr(name, typ, flags, addr, offset, size, link, info, addralign, entsize):
        return struct.pack("<IIQQQQIIQQ", 0 if not name else shoff[name], typ, flags,
                           addr, offset, size, link, info, addralign, entsize)
    sections = b"\0" * 64
    sections += shdr(".text", 1, 2, 0x1000, text_off, len(text), 0, 0, 16, 0)
    sections += shdr(".symtab", 2, 0, 0, sym_off, len(symtab), 3, 1, 8, 24)
    sections += shdr(".strtab", 3, 0, 0, str_off, len(strt), 0, 0, 1, 0)
    sections += shdr(".shstrtab", 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0)
    body = ehdr + text + symtab + strt + shstr
    body += b"\0" * (shoff_off - len(body))
    body += sections
    pathlib.Path(path).write_bytes(body)

def elf_header_only(path, elfclass=2, machine=62, data=1):
    # Only the first 20 bytes are used by wlua_elf_info.
    buf = bytearray(64)
    buf[0:4] = b"\x7fELF"
    buf[4] = elfclass
    buf[5] = data
    buf[6] = 1
    # e_type = 2 (ET_EXEC) at 16, e_machine at 18
    if data == 1:
        buf[16:18] = (2).to_bytes(2, "little")
        buf[18:20] = int(machine).to_bytes(2, "little")
    else:
        buf[16:18] = (2).to_bytes(2, "big")
        buf[18:20] = int(machine).to_bytes(2, "big")
    pathlib.Path(path).write_bytes(bytes(buf))

args = sys.argv[1:]
kind = args[0]
path = args[1]
if kind == "x86_64":
    syms = args[2:]
    elf64(path, 62, syms)
elif kind == "x86_64-header":
    elf_header_only(path, 2, 62)
elif kind == "i386":
    elf_header_only(path, 1, 3)
elif kind == "aarch64":
    elf_header_only(path, 2, 183)
elif kind == "header":
    # header <path> <class> <machine>
    elf_header_only(path, int(args[2]), int(args[3]))
else:
    raise SystemExit("unknown kind %s" % kind)
PY
}

REQUIRED_SYMS=(
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

write_status() {
    local path="$1"
    local pid="$2"
    local ppid="${3:-1}"
    local uid="${4:-1000}"
    local state="${5:-S (sleeping)}"
    local tracer="${6:-0}"
    local dumpable="${7:-1}"
    cat > "$path" << EOF
Name:	lua
State:	$state
Tgid:	$pid
Pid:	$pid
PPid:	$ppid
TracerPid:	$tracer
Uid:	$uid	$uid	$uid	$uid
Gid:	$uid	$uid	$uid	$uid
Dumpable:	$dumpable
CapEff:	0000000000000000
EOF
}

write_maps() {
    local path="$1"
    local exe="$2"
    local lib="${3-}"
    {
        printf '00400000-0040b000 r-xp 00000000 08:01 1  %s\n' "$exe"
        printf '0040b000-0040c000 r--p 0000b000 08:01 1  %s\n' "$exe"
        if [[ -n "$lib" ]]; then
            printf '7f1110000000-7f1110010000 r-xp 00000000 08:01 2  %s\n' "$lib"
        fi
        printf '7fff00000000-7fff00021000 rw-p 00000000 00:00 0  [stack]\n'
    } > "$path"
}

write_self_status() {
    local path="$1"
    local cap="${2:-0000000000000000}"
    cat > "$path" << EOF
Name:	start
State:	R (running)
Pid:	$$
Uid:	1000	1000	1000	1000
CapEff:	$cap
EOF
}

# A mock gdb that never attaches to a real process. It only understands
# "gdb -p <pid> -ex p (long)<sym> --batch" when WLUA_MOCK_GDB_MODE is set.
write_mock_gdb() {
    local path="$1"
    cat > "$path" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${WLUA_MOCK_GDB_MODE:-ok}"
pid=""
sym=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) pid="$2"; shift 2 ;;
        -ex) sym="$2"; shift 2 ;;
        --batch) shift ;;
        *) shift ;;
    esac
done
case "$mode" in
    ok)
        # Print a gdb-like value. Address is fake and unused by dry-run.
        echo '$1 = 140737488355328'
        ;;
    missing)
        echo "No symbol \"${sym}\" in current context." >&2
        exit 0
        ;;
    ptrace)
        echo "ptrace: Operation not permitted." >&2
        echo "Could not attach to process ${pid}." >&2
        exit 1
        ;;
    gone)
        echo "No such process" >&2
        exit 1
        ;;
    *)
        echo "unknown mock gdb mode" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$path"
}

write_mock_hookso() {
    local path="$1"
    cat > "$path" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${WLUA_MOCK_HOOKSO_MODE:-ok}"
cmd="${1-}"
case "$mode" in
    ok)
        echo "hookso mock: $*"
        exit 0
        ;;
    ptrace)
        echo "ptrace: Operation not permitted" >&2
        exit 1
        ;;
    gone)
        echo "No such process" >&2
        exit 1
        ;;
    arch)
        echo "wrong ELF class: ELFCLASS32" >&2
        exit 1
        ;;
    fail)
        echo "dlopen failed: unexpected error" >&2
        exit 1
        ;;
    *)
        echo "unknown mock hookso mode" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$path"
}

# Isolated fixture tree for a preflight/dry-run scenario.
# Sets FX_DIR and exports override variables. Caller may tweak files after.
setup_fixture() {
    local name="$1"
    FX_DIR="${TEST_BASE}/${name}"
    rm -rf "$FX_DIR"
    mkdir -p "$FX_DIR"/{bin,proc/1234,images,sys}

    write_elf x86_64 "$FX_DIR/images/libwlua.so"
    write_elf x86_64 "$FX_DIR/images/hookso"
    chmod +x "$FX_DIR/images/hookso"
    write_elf x86_64 "$FX_DIR/images/lua53" "${REQUIRED_SYMS[@]}"
    # Add a recognizable Lua 5.3 string for the strings fallback, and a versioned lib.
    printf 'padding Lua 5.3.4 copyright padding' >> "$FX_DIR/images/lua53"
    write_elf x86_64 "$FX_DIR/images/liblua5.3.so.0.0.0" "${REQUIRED_SYMS[@]}"
    printf 'Lua 5.3.4  Copyright (C) 1994-2017 Lua.org, PUC-Rio' >> "$FX_DIR/images/liblua5.3.so.0.0.0"

    ln -s "$FX_DIR/images/lua53" "$FX_DIR/proc/1234/exe"
    write_status "$FX_DIR/proc/1234/status" 1234 1 1000
    write_maps "$FX_DIR/proc/1234/maps" "$FX_DIR/images/lua53" "$FX_DIR/images/liblua5.3.so.0.0.0"
    echo 0 > "$FX_DIR/sys/ptrace_scope"
    write_self_status "$FX_DIR/self_status"
    write_mock_gdb "$FX_DIR/bin/gdb"

    export WLUA_PROC_ROOT="$FX_DIR/proc"
    export WLUA_PTRACE_SCOPE_FILE="$FX_DIR/sys/ptrace_scope"
    export WLUA_LIB_SO="$FX_DIR/images/libwlua.so"
    export WLUA_HOOKSO="$FX_DIR/images/hookso"
    export WLUA_GDB="gdb"
    export WLUA_SELF_PID="9999"
    export WLUA_SELF_EUID="1000"
    export WLUA_SELF_STATUS="$FX_DIR/self_status"
    export PATH="$FX_DIR/bin:$PATH"
    unset WLUA_HIDE_CMDS || true
    unset WLUA_UNAME || true
    unset WLUA_DRY_RUN || true
    unset WLUA_MOCK_GDB_MODE || true
    unset WLUA_MOCK_HOOKSO_MODE || true
}

source_preflight() {
    # shellcheck source=../scripts/wlua_preflight.sh
    source "$PREFLIGHT"
    WLUA_APP_NAME="start.sh"
}

# ---------- syntax ----------
echo "==> bash -n"
assert_ok "bash -n start.sh" bash -n "$START"
assert_ok "bash -n scripts/wlua_preflight.sh" bash -n "$PREFLIGHT"
assert_ok "bash -n tests/preflight_test.sh" bash -n "$ROOT/tests/preflight_test.sh"

TEST_BASE="$(mktemp -d /tmp/wlua-preflight.XXXXXX)"
trap 'rm -rf "$TEST_BASE"' EXIT

# Snapshot the real yama sysctl (must stay untouched).
REAL_YAMA="/proc/sys/kernel/yama/ptrace_scope"
YAMA_BEFORE=""
YAMA_BEFORE_STAT=""
if [[ -e "$REAL_YAMA" ]]; then
    YAMA_BEFORE="$(cat "$REAL_YAMA" 2>/dev/null || true)"
    YAMA_BEFORE_STAT="$(stat -c '%Y %s' "$REAL_YAMA" 2>/dev/null || true)"
fi

source_preflight

# ELF parser against a real system binary (no attach).
if [[ -r /bin/bash ]]; then
    info="$(wlua_elf_info /bin/bash || true)"
    assert_ok "elf parser reads /bin/bash as ELF 64 x86_64" \
        bash -c '[[ "$0" == "ELF 64 x86_64" ]]' "$info"
fi

# ---------- usage / CLI ----------
expect_rc_contains "no args" 1 "missing PID" "$START"
expect_rc_contains "help" 0 "Usage:" "$START" --help
expect_rc_contains "help -h" 0 "Exit codes:" "$START" -h
expect_rc_contains "invalid pid abc" 1 "invalid PID" bash -c "source '$PREFLIGHT'; wlua_validate_pid abc"
expect_rc_contains "invalid pid 0" 1 "invalid PID" bash -c "source '$PREFLIGHT'; wlua_validate_pid 0"
expect_rc_contains "invalid pid path" 1 "invalid PID" bash -c "source '$PREFLIGHT'; wlua_validate_pid '../../etc/passwd'"
expect_rc_contains "invalid pid negative" 1 "invalid PID" bash -c "source '$PREFLIGHT'; wlua_validate_pid -- -1"
# -1 would be parsed as option if passed via start.sh
expect_rc_contains "unknown option" 1 "unknown option" "$START" --force 1234
expect_rc_contains "extra args" 1 "unexpected argument" "$START" 1234 extra
expect_rc_contains "dry-run without pid" 1 "requires a PID" "$START" --dry-run

# ---------- process existence / permission ----------
setup_fixture proc-missing
rm -rf "$FX_DIR/proc/1234"
expect_rc_contains "missing process" 2 "does not exist" bash -c "
    source '$PREFLIGHT'
    wlua_check_process 1234
"

setup_fixture proc-zombie
write_status "$FX_DIR/proc/1234/status" 1234 1 1000 "Z (zombie)"
expect_rc_contains "zombie process" 2 "zombie" bash -c "
    source '$PREFLIGHT'
    wlua_check_process 1234
"

setup_fixture proc-perm
chmod 000 "$FX_DIR/proc/1234/status"
expect_rc_contains "unreadable proc status" 3 "not accessible" bash -c "
    source '$PREFLIGHT'
    wlua_check_process 1234
"
chmod 644 "$FX_DIR/proc/1234/status"

# ---------- missing tools ----------
setup_fixture no-lib
rm -f "$FX_DIR/images/libwlua.so"
unset WLUA_LIB_SO
# Also make sure script_dir has no lib
expect_rc_contains "missing libwlua.so" 4 "libwlua.so not found" bash -c "
    source '$PREFLIGHT'
    wlua_find_libwlua '$FX_DIR/images'
"

setup_fixture no-hookso
rm -f "$FX_DIR/images/hookso"
unset WLUA_HOOKSO
expect_rc_contains "missing hookso" 5 "hookso binary not found" bash -c "
    source '$PREFLIGHT'
    wlua_find_hookso '$FX_DIR/images'
"

setup_fixture hookso-nx
rm -f "$FX_DIR/images/hookso"
# non-elf is fine here; find_hookso runs before arch check
echo '#!/bin/sh' > "$FX_DIR/images/hookso"
chmod a-x "$FX_DIR/images/hookso"
unset WLUA_HOOKSO
expect_rc_contains "hookso not executable" 5 "not executable" bash -c "
    source '$PREFLIGHT'
    wlua_find_hookso '$FX_DIR/images'
"

setup_fixture no-gdb
export WLUA_HIDE_CMDS="gdb"
expect_rc_contains "missing gdb" 6 "gdb is required" bash -c "
    source '$PREFLIGHT'
    wlua_check_gdb
"
unset WLUA_HIDE_CMDS

# ---------- platform / arch ----------
setup_fixture plat-darwin
# write a proper uname mock
cat > "$FX_DIR/bin/fake_uname" << 'EOF'
#!/bin/sh
case "$1" in
    -s) echo Darwin ;;
    -m) echo x86_64 ;;
    *) echo Darwin ;;
esac
EOF
chmod +x "$FX_DIR/bin/fake_uname"
expect_rc_contains "non-linux host" 7 "unsupported platform" bash -c "
    source '$PREFLIGHT'
    WLUA_UNAME='$FX_DIR/bin/fake_uname'
    wlua_check_platform
"

cat > "$FX_DIR/bin/fake_uname" << 'EOF'
#!/bin/sh
case "$1" in
    -s) echo Linux ;;
    -m) echo aarch64 ;;
    *) echo Linux ;;
esac
EOF
expect_rc_contains "aarch64 host" 7 "unsupported architecture" bash -c "
    source '$PREFLIGHT'
    WLUA_UNAME='$FX_DIR/bin/fake_uname'
    wlua_check_platform
"
unset WLUA_UNAME

setup_fixture arch-i386
write_elf i386 "$FX_DIR/images/target32"
ln -sf "$FX_DIR/images/target32" "$FX_DIR/proc/1234/exe"
expect_rc_contains "i386 target rejected" 7 "not a supported/proven platform" bash -c "
    source '$PREFLIGHT'
    wlua_check_arch_compat 1234 '$WLUA_LIB_SO' '$WLUA_HOOKSO'
"

setup_fixture arch-arm
write_elf aarch64 "$FX_DIR/images/targetarm"
ln -sf "$FX_DIR/images/targetarm" "$FX_DIR/proc/1234/exe"
expect_rc_contains "aarch64 target rejected" 7 "aarch64" bash -c "
    source '$PREFLIGHT'
    wlua_check_arch_compat 1234 '$WLUA_LIB_SO' '$WLUA_HOOKSO'
"

setup_fixture arch-so-mismatch
write_elf aarch64 "$FX_DIR/images/libwlua.so"
expect_rc_contains "libwlua.so aarch64 rejected" 7 "libwlua.so" bash -c "
    source '$PREFLIGHT'
    wlua_check_arch_compat 1234 '$FX_DIR/images/libwlua.so' '$WLUA_HOOKSO'
"

# ---------- ptrace ----------
setup_fixture ptrace-3
echo 3 > "$FX_DIR/sys/ptrace_scope"
expect_rc_contains "ptrace_scope=3" 10 "ptrace is disabled" bash -c "
    source '$PREFLIGHT'
    wlua_check_ptrace 1234
"
expect_contains "ptrace_scope=3 no sysctl change hint" "will not change"

setup_fixture ptrace-2
echo 2 > "$FX_DIR/sys/ptrace_scope"
export WLUA_SELF_EUID=1000
expect_rc_contains "ptrace_scope=2 unprivileged" 10 "only a privileged process" bash -c "
    source '$PREFLIGHT'
    wlua_check_ptrace 1234
"

setup_fixture ptrace-2-root
echo 2 > "$FX_DIR/sys/ptrace_scope"
export WLUA_SELF_EUID=0
expect_rc "ptrace_scope=2 as root allowed" 0 bash -c "
    source '$PREFLIGHT'
    wlua_check_ptrace 1234
"

setup_fixture ptrace-1
echo 1 > "$FX_DIR/sys/ptrace_scope"
export WLUA_SELF_EUID=1000
export WLUA_SELF_PID=9999
# target PPid is 1, we are 9999
expect_rc_contains "ptrace_scope=1 non-parent" 10 "only allows a parent process" bash -c "
    source '$PREFLIGHT'
    wlua_check_ptrace 1234
"
expect_contains "ptrace_scope=1 does not offer auto sysctl" "will not change sysctl"

setup_fixture ptrace-1-parent
echo 1 > "$FX_DIR/sys/ptrace_scope"
export WLUA_SELF_PID=1
export WLUA_SELF_EUID=1000
expect_rc "ptrace_scope=1 as parent allowed" 0 bash -c "
    source '$PREFLIGHT'
    wlua_check_ptrace 1234
"

setup_fixture ptrace-traced
echo 0 > "$FX_DIR/sys/ptrace_scope"
write_status "$FX_DIR/proc/1234/status" 1234 1 1000 "S (sleeping)" 42 1
expect_rc_contains "already traced" 10 "already being traced" bash -c "
    source '$PREFLIGHT'
    wlua_check_ptrace 1234
"

setup_fixture ptrace-uid
echo 0 > "$FX_DIR/sys/ptrace_scope"
write_status "$FX_DIR/proc/1234/status" 1234 1 2000
export WLUA_SELF_EUID=1000
expect_rc_contains "different uid" 10 "runs as uid 2000" bash -c "
    source '$PREFLIGHT'
    wlua_check_ptrace 1234
"

setup_fixture ptrace-dumpable
echo 0 > "$FX_DIR/sys/ptrace_scope"
write_status "$FX_DIR/proc/1234/status" 1234 1 1000 "S (sleeping)" 0 0
export WLUA_SELF_EUID=1000
expect_rc_contains "not dumpable" 10 "not dumpable" bash -c "
    source '$PREFLIGHT'
    wlua_check_ptrace 1234
"

setup_fixture ptrace-unknown
echo 9 > "$FX_DIR/sys/ptrace_scope"
expect_rc_contains "unknown yama value" 10 "unknown kernel.yama.ptrace_scope" bash -c "
    source '$PREFLIGHT'
    wlua_check_ptrace 1234
"

setup_fixture ptrace-missing-yama
rm -f "$FX_DIR/sys/ptrace_scope"
export WLUA_PTRACE_SCOPE_FILE="$FX_DIR/sys/ptrace_scope"
expect_rc_contains "missing yama is a note, not a hard assume-safe claim" 0 "not readable" bash -c "
    source '$PREFLIGHT'
    wlua_check_ptrace 1234
"
expect_contains "missing yama limitation stated" "may still be blocked"

# ---------- Lua version / symbols ----------
setup_fixture lua-jit
write_elf x86_64 "$FX_DIR/images/libluajit-5.1.so.2"
write_maps "$FX_DIR/proc/1234/maps" "$FX_DIR/images/lua53" "$FX_DIR/images/libluajit-5.1.so.2"
expect_rc_contains "luajit rejected" 8 "LuaJIT" bash -c "
    source '$PREFLIGHT'
    wlua_check_lua_compat 1234
"

setup_fixture lua-54
write_elf x86_64 "$FX_DIR/images/liblua5.4.so.0"
write_maps "$FX_DIR/proc/1234/maps" "$FX_DIR/images/lua53" "$FX_DIR/images/liblua5.4.so.0"
expect_rc_contains "lua 5.4 rejected" 8 "lua5.4" bash -c "
    source '$PREFLIGHT'
    wlua_check_lua_compat 1234
"

setup_fixture lua-52
write_elf x86_64 "$FX_DIR/images/liblua5.2.so.0"
write_maps "$FX_DIR/proc/1234/maps" "$FX_DIR/images/lua53" "$FX_DIR/images/liblua5.2.so.0"
expect_rc_contains "lua 5.2 rejected" 8 "lua5.2" bash -c "
    source '$PREFLIGHT'
    wlua_check_lua_compat 1234
"

setup_fixture lua-51
write_elf x86_64 "$FX_DIR/images/liblua5.1.so.0"
write_maps "$FX_DIR/proc/1234/maps" "$FX_DIR/images/lua53" "$FX_DIR/images/liblua5.1.so.0"
expect_rc_contains "lua 5.1 rejected" 8 "lua5.1" bash -c "
    source '$PREFLIGHT'
    wlua_check_lua_compat 1234
"

setup_fixture lua-none
# exe without lua name, maps without liblua, no strings, no symbols
write_elf x86_64 "$FX_DIR/images/plainapp"
ln -sf "$FX_DIR/images/plainapp" "$FX_DIR/proc/1234/exe"
write_maps "$FX_DIR/proc/1234/maps" "$FX_DIR/images/plainapp"
expect_rc_contains "unknown process rejected" 8 "could not determine a supported Lua VM" bash -c "
    source '$PREFLIGHT'
    wlua_check_lua_compat 1234
"

setup_fixture lua-unknown-lib
write_elf x86_64 "$FX_DIR/images/liblua.so"
write_maps "$FX_DIR/proc/1234/maps" "$FX_DIR/images/lua53" "$FX_DIR/images/liblua.so"
# Overwrite lua53 name kind? exe is lua53 which path-detects as 5.3. Use plain exe.
write_elf x86_64 "$FX_DIR/images/plainapp"
ln -sf "$FX_DIR/images/plainapp" "$FX_DIR/proc/1234/exe"
write_maps "$FX_DIR/proc/1234/maps" "$FX_DIR/images/plainapp" "$FX_DIR/images/liblua.so"
expect_rc_contains "unversioned liblua rejected" 8 "version could not be determined" bash -c "
    source '$PREFLIGHT'
    wlua_check_lua_compat 1234
"

setup_fixture lua-stripped
# 5.3 library/path but no required symbols
write_elf x86_64 "$FX_DIR/images/liblua5.3.so.0.0.0"
write_elf x86_64 "$FX_DIR/images/lua53"
ln -sf "$FX_DIR/images/lua53" "$FX_DIR/proc/1234/exe"
write_maps "$FX_DIR/proc/1234/maps" "$FX_DIR/images/lua53" "$FX_DIR/images/liblua5.3.so.0.0.0"
expect_rc_contains "5.3 without symbols rejected" 9 "required Lua symbol" bash -c "
    source '$PREFLIGHT'
    wlua_check_lua_compat 1234
"
expect_contains "stripped hint mentions version string is not enough" "not a substitute"

setup_fixture lua-missing-one
# all symbols except luaH_resize, in both the versioned lib and the exe
# (preflight searches every Lua-related image, including the executable).
syms=()
for s in "${REQUIRED_SYMS[@]}"; do
    [[ "$s" == luaH_resize ]] && continue
    syms+=("$s")
done
write_elf x86_64 "$FX_DIR/images/liblua5.3.so.0.0.0" "${syms[@]}"
write_elf x86_64 "$FX_DIR/images/lua53" "${syms[@]}"
ln -sf "$FX_DIR/images/lua53" "$FX_DIR/proc/1234/exe"
write_maps "$FX_DIR/proc/1234/maps" "$FX_DIR/images/lua53" "$FX_DIR/images/liblua5.3.so.0.0.0"
expect_rc_contains "missing luaH_resize" 9 "luaH_resize" bash -c "
    source '$PREFLIGHT'
    wlua_check_lua_compat 1234
"

setup_fixture lua-ok
run_cap bash -c "
    source '$PREFLIGHT'
    wlua_check_lua_compat 1234
"
if [[ "$RUN_RC" -eq 0 ]]; then
    echo "PASS  lua 5.3 with symbols accepted (exit 0)"
    PASS=$((PASS + 1))
else
    echo "FAIL  lua 5.3 with symbols accepted (exit $RUN_RC)"
    echo "      output: $RUN_OUT"
    FAIL=$((FAIL + 1))
fi
expect_contains "success path does not claim ABI safety" "not proof of ABI compatibility"
expect_not_contains "success path never says ABI-safe" "ABI safe"
expect_not_contains "success path never says ABI-compatible" "ABI compatible"

# ---------- full preflight + start.sh --dry-run ----------
setup_fixture dry-run-ok
expect_rc_contains "start.sh --dry-run success" 0 "Dry-run: preflight passed" \
    "$START" --dry-run 1234
expect_contains "dry-run mentions no injection" "No injection was attempted"
expect_contains "dry-run ABI warning" "not proof of ABI compatibility"
expect_not_contains "dry-run does not call hookso language of inject" "Injecting"

# Make sure --check is an alias
expect_rc_contains "start.sh --check success" 0 "Dry-run: preflight passed" \
    "$START" --check 1234

# Normal usage path still accepts ./start.sh <PID> but we only run it under
# dry-run env to avoid executing the ELF stub as hookso.
export WLUA_DRY_RUN=1
expect_rc_contains "start.sh PID with WLUA_DRY_RUN=1" 0 "preflight passed" \
    "$START" 1234
unset WLUA_DRY_RUN

# ---------- injection classification (mocked hookso/gdb, no real attach) ----------
setup_fixture inject-ok
write_mock_hookso "$FX_DIR/bin/hookso"
export WLUA_HOOKSO="$FX_DIR/bin/hookso"
export WLUA_MOCK_HOOKSO_MODE=ok
export WLUA_MOCK_GDB_MODE=ok
# work in a throwaway cwd so logs do not touch the repo
INJ_WD="$FX_DIR/injwd"
mkdir -p "$INJ_WD"
expect_rc_contains "mocked inject success" 0 "All hooks installed successfully" bash -c "
    cd '$INJ_WD'
    source '$PREFLIGHT'
    wlua_inject 1234 '$WLUA_LIB_SO' '$FX_DIR/bin/hookso'
"

setup_fixture inject-dlopen-ptrace
write_mock_hookso "$FX_DIR/bin/hookso"
export WLUA_MOCK_HOOKSO_MODE=ptrace
expect_rc_contains "dlopen ptrace denied is exit 10" 10 "ptrace attach was denied" bash -c "
    source '$PREFLIGHT'
    wlua_inject 1234 '$WLUA_LIB_SO' '$FX_DIR/bin/hookso'
"
expect_contains "dlopen ptrace does not change sysctl" "will not change sysctl"

setup_fixture inject-dlopen-gone
write_mock_hookso "$FX_DIR/bin/hookso"
export WLUA_MOCK_HOOKSO_MODE=gone
expect_rc_contains "dlopen process gone is exit 2" 2 "disappeared" bash -c "
    source '$PREFLIGHT'
    wlua_inject 1234 '$WLUA_LIB_SO' '$FX_DIR/bin/hookso'
"

setup_fixture inject-dlopen-fail
write_mock_hookso "$FX_DIR/bin/hookso"
export WLUA_MOCK_HOOKSO_MODE=fail
expect_rc_contains "dlopen generic failure is exit 12" 12 "hookso dlopen" bash -c "
    source '$PREFLIGHT'
    wlua_inject 1234 '$WLUA_LIB_SO' '$FX_DIR/bin/hookso'
"

setup_fixture inject-dlopen-arch
write_mock_hookso "$FX_DIR/bin/hookso"
export WLUA_MOCK_HOOKSO_MODE=arch
expect_rc_contains "dlopen ELF class mismatch is exit 12" 12 "architecture or ELF-class mismatch" bash -c "
    source '$PREFLIGHT'
    wlua_inject 1234 '$WLUA_LIB_SO' '$FX_DIR/bin/hookso'
"

setup_fixture inject-gdb-ptrace
write_mock_hookso "$FX_DIR/bin/hookso"
export WLUA_HOOKSO="$FX_DIR/bin/hookso"
export WLUA_MOCK_HOOKSO_MODE=ok
export WLUA_MOCK_GDB_MODE=ptrace
expect_rc_contains "gdb ptrace denied is exit 10" 10 "ptrace denied" bash -c "
    source '$PREFLIGHT'
    wlua_inject 1234 '$WLUA_LIB_SO' '$FX_DIR/bin/hookso'
"

setup_fixture inject-gdb-gone
write_mock_hookso "$FX_DIR/bin/hookso"
export WLUA_MOCK_HOOKSO_MODE=ok
export WLUA_MOCK_GDB_MODE=gone
expect_rc_contains "gdb process gone is exit 2" 2 "exited while resolving" bash -c "
    source '$PREFLIGHT'
    wlua_inject 1234 '$WLUA_LIB_SO' '$FX_DIR/bin/hookso'
"

setup_fixture inject-gdb-symbol
write_mock_hookso "$FX_DIR/bin/hookso"
export WLUA_MOCK_HOOKSO_MODE=ok
export WLUA_MOCK_GDB_MODE=missing
expect_rc_contains "gdb missing symbol is exit 11" 11 "symbol address lookup failed" bash -c "
    source '$PREFLIGHT'
    wlua_inject 1234 '$WLUA_LIB_SO' '$FX_DIR/bin/hookso'
"
expect_contains "symbol failure is not labeled generic inject only" "not a generic inject failure"

setup_fixture inject-target-exit
write_mock_hookso "$FX_DIR/bin/hookso"
rm -rf "$FX_DIR/proc/1234"
export WLUA_MOCK_HOOKSO_MODE=ok
expect_rc_contains "inject when process already gone is exit 2" 2 "does not exist" bash -c "
    source '$PREFLIGHT'
    wlua_inject 1234 '$WLUA_LIB_SO' '$FX_DIR/bin/hookso'
"

# ---------- yama sysctl untouched ----------
if [[ -e "$REAL_YAMA" ]]; then
    YAMA_AFTER="$(cat "$REAL_YAMA" 2>/dev/null || true)"
    YAMA_AFTER_STAT="$(stat -c '%Y %s' "$REAL_YAMA" 2>/dev/null || true)"
    if [[ "$YAMA_BEFORE" == "$YAMA_AFTER" && "$YAMA_BEFORE_STAT" == "$YAMA_AFTER_STAT" ]]; then
        echo "PASS  real ptrace_scope file was not modified"
        PASS=$((PASS + 1))
    else
        echo "FAIL  real ptrace_scope file changed (before='$YAMA_BEFORE' after='$YAMA_AFTER')"
        FAIL=$((FAIL + 1))
    fi
else
    echo "PASS  no real yama sysctl present to modify"
    PASS=$((PASS + 1))
fi

# No leftover inject logs in the repo root from tests (inject used INJ_WD).
if [[ -f "$ROOT/wlua_result.log" ]]; then
    echo "FAIL  tests wrote $ROOT/wlua_result.log"
    FAIL=$((FAIL + 1))
else
    echo "PASS  tests did not write repo wlua_result.log"
    PASS=$((PASS + 1))
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
exit 0
