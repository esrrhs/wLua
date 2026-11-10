# wLua compatibility and startup diagnostics

[English](COMPATIBILITY.md) | [Chinese](COMPATIBILITY_CN.md)

This document describes what `start.sh` checks **before** injecting `libwlua.so`, how failures are classified, and which limits are **not** proven even when preflight succeeds.

`start.sh` will not change `kernel.yama.ptrace_scope`, elevate privileges, install packages, or build missing artifacts.

## Supported boundary (from this tree)

wLua is compiled against the **vendored PUC-Rio Lua 5.3.4** headers and sources under `lua/` (`LUA_VERSION_NUM` 503). The hook wrappers in `main.cpp` use those internal structure layouts, and `start.sh` resolves these target symbols before hooking:

- `luaO_nilobject_` (address passed to `set_lua_nilobject`)
- `luaH_resize`, `luaH_get`, `luaH_set`
- `luaC_fullgc`, `luaC_step`, `luaC_newobj`
- `luaS_new`, `luaS_newlstr`

Intended, and the only combination preflight will allow:

- **OS / arch:** Linux x86_64 (host, `libwlua.so`, `hookso`, and the target ELF must all be 64-bit x86_64)
- **VM:** PUC-Rio Lua 5.3, identified from the process image (library soname/path such as `liblua5.3.so`, or an equivalent interpreter name)
- **Symbols:** the list above must be visible in the target executable or Lua-related mapped objects via `readelf` / `nm` / `objdump` (no process attach)
- **Tools:** `gdb` in `PATH`, an executable `hookso`, and a built `libwlua.so`
- **Attach policy:** ptrace must not be already blocked by Yama, a different uid, a non-dumpable target, or an existing tracer (see below)

Rejected when detected:

- Non-Linux hosts
- Non-x86_64 (including aarch64, i386, arm) — the CMake build does not prove those platforms
- LuaJIT
- Lua 5.1, 5.2, 5.4, 5.5 and other non-5.3 versions
- Unknown or unversioned Lua images (a renamed static binary must still show a Lua 5.3 string or a versioned liblua mapping; required symbols alone are not used to infer the version, because some names also exist in later Lua releases)
- Missing or unreadable required symbols (stripped images, hidden visibility without a symbol table)
- Architecture mismatch between the target, `libwlua.so`, and `hookso`
- Proven ptrace / permission blocks

## Version strings are not ABI proof

Finding `Lua 5.3` in a path, soname, or binary string is enough to **reject** a different major/minor version, but it is **never** used to claim that injection is ABI-safe.

Even when Lua 5.3 and the required symbols are present, the following are unproven and can still crash the target after injection:

- Other 5.3.x releases versus the vendored 5.3.4 layouts
- Compile-time options such as `LUA_32BITS`, a different `LUA_NUMBER` / `LUA_INTEGER`, or a custom `luaconf.h`
- Distro or vendor patches, embedding forks, and in-house Lua modifications
- Hidden-visibility or stripped-at-runtime symbols that were visible in the on-disk image

Preflight prints this warning on the success path. There is no `--force` flag that bypasses a failed check.

## What is checked, and in what order

1. Arguments (`--help`, `--dry-run` / `--check`, a single positive integer PID)
2. Host platform (Linux x86_64)
3. Process existence, zombie/dead state, and `/proc` readability
4. `libwlua.so` (project root, `build/`, or `WLUA_LIB_SO`)
5. `hookso` (project root, then `PATH`; a non-executable local file is reported, not skipped)
6. `gdb` on `PATH`
7. ELF class/machine of the target, `libwlua.so`, and `hookso`
8. ptrace policy (Yama, uid, dumpable, TracerPid, `CAP_SYS_PTRACE`)
9. Lua variant / version evidence from `/proc/<pid>/maps` and the executable
10. Required symbols in those images
11. A final process-liveness check
12. Injection (`hookso dlopen` / `call` / `replacep` and gdb address lookup) unless `--dry-run`

`./start.sh --dry-run <PID>` (or `--check`) stops after step 11 and does not inject, attach with `gdb -p`, or start `hookso`.

## Exit codes

| Code | Meaning | Typical fix |
| --- | --- | --- |
| 0 | Success (dry-run: preflight passed; otherwise hooks installed) | — |
| 1 | Usage or argument error | Pass a single positive integer PID. See `--help`. |
| 2 | Process does not exist, is a zombie, or exited mid-run | Confirm `ps -p <PID>` and restart the target. |
| 3 | `/proc` records or the target executable are not accessible | Re-run as the same user as the target, or as root. wLua will not change credentials. |
| 4 | `libwlua.so` missing or not a usable file | Run `./build.sh` yourself. The starter will not build it. |
| 5 | `hookso` missing or not executable | Build [hookso](https://github.com/esrrhs/hookso) and place it in the project directory or `PATH`. If the file exists, `chmod +x hookso` yourself. |
| 6 | `gdb` missing | Install `gdb`. The starter will not install packages. |
| 7 | Unsupported platform or architecture | Use Linux x86_64; rebuild `libwlua.so` / `hookso` to match the target. |
| 8 | Lua unknown or unsupported | Use a PUC-Rio Lua 5.3 process; LuaJIT and other versions are rejected. |
| 9 | Required symbols not found | Rebuild the target with symbols, or install inspectable debug symbols. A version string is not enough. |
| 10 | ptrace or attach permission is restricted | Re-run as the target's parent or as root, or have an administrator adjust ptrace policy. wLua will not change sysctl. |
| 11 | Runtime symbol address resolution failed | gdb attached but could not resolve a required symbol; treat this separately from a generic inject failure. |
| 12 | `hookso` injection or hook installation failed | Read the tool output: the process may have blocked `dlopen`, or the library may still be incompatible. |

## ptrace policy

wLua **reads** `kernel.yama.ptrace_scope` when it is available and **never writes** it.

- `0`: no Yama restriction is reported (LSM/seccomp/container policy can still fail later)
- `1`: only the parent (or a privileged process) may attach; otherwise preflight fails
- `2`: only a privileged process may attach
- `3`: ptrace is disabled; preflight fails
- Missing file: no Yama value is assumed; a note is printed that other restrictions may still apply
- Unknown value: preflight fails rather than guessing

Privilege here means euid 0 or `CAP_SYS_PTRACE`. wLua will not add that capability or run `sudo` / `sysctl` for you.

If Yama is absent, a later attach failure is still classified as a ptrace denial (exit 10) rather than a generic inject failure when the tool output matches.

## Tests

From the project root (no compiler, no `build.sh`, no real `gdb -p`, no real injection):

```bash
bash tests/preflight_test.sh
```

The tests use a fake `/proc` tree, fake ELF files, and mock `gdb` / `hookso` binaries. `bash -n` is also run on the shell scripts.

## Environment overrides (for tests and diagnostics)

These are optional. Normal use does not need them.

- `WLUA_DRY_RUN=1` — same as `--dry-run`
- `WLUA_LIB_SO`, `WLUA_HOOKSO`, `WLUA_GDB` — override tool paths
- `WLUA_PROC_ROOT` — fake `/proc` root
- `WLUA_PTRACE_SCOPE_FILE` — fake Yama sysctl file
- `WLUA_SELF_PID`, `WLUA_SELF_EUID`, `WLUA_SELF_STATUS` — pretend identity
- `WLUA_UNAME` — command used instead of `uname`
- `WLUA_HIDE_CMDS` — comma-separated command names treated as missing
