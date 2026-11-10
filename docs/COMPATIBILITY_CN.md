# wLua 兼容性检查与启动诊断

[English](COMPATIBILITY.md) | [中文说明](COMPATIBILITY_CN.md)

本文说明 `start.sh` 在注入 `libwlua.so` **之前**检查什么、失败如何分类，以及预检通过后**仍不能证明**的限制。

`start.sh` 不会修改 `kernel.yama.ptrace_scope`、不会提升权限、不会代为安装软件包，也不会自动编译缺失的产物。

## 支持边界（以本仓库实现为准）

wLua 针对仓库内 `lua/` 目录中的 **PUC-Rio Lua 5.3.4** 头文件与源码编译（`LUA_VERSION_NUM` 为 503）。`main.cpp` 中的 Hook 封装使用该版本的内部结构布局，`start.sh` 在挂钩前需要解析以下目标符号：

- `luaO_nilobject_`（地址传入 `set_lua_nilobject`）
- `luaH_resize`、`luaH_get`、`luaH_set`
- `luaC_fullgc`、`luaC_step`、`luaC_newobj`
- `luaS_new`、`luaS_newlstr`

预检仅允许同时满足以下条件的目标：

- **操作系统 / 架构：** Linux x86_64（主机、`libwlua.so`、`hookso` 与目标 ELF 都必须是 64 位 x86_64）
- **虚拟机：** PUC-Rio Lua 5.3，依据进程映像识别（如 `liblua5.3.so` 的 soname/路径，或等价解释器名称）
- **符号：** 上述符号必须能在目标可执行文件或 Lua 相关映射对象中，通过 `readelf` / `nm` / `objdump` 看到（不附加进程）
- **工具：** `PATH` 中有 `gdb`、可执行的 `hookso`，以及已编译的 `libwlua.so`
- **附加策略：** 不能已被 Yama、不同 uid、不可 dump 的目标或已有 tracer 明确阻止（见下文）

一旦检测到以下情况将直接拒绝：

- 非 Linux 主机
- 非 x86_64（包括 aarch64、i386、arm）—— CMake 构建并未证明这些平台可用
- LuaJIT
- Lua 5.1、5.2、5.4、5.5 以及其他非 5.3 版本
- 未知或无法判断版本的 Lua 映像（重命名的静态链接程序仍需出现 Lua 5.3 字符串或带版本的 liblua 映射；不会仅凭所需符号推断版本，因为部分符号名在后续 Lua 中仍然存在）
- 缺少或无法读取所需符号（已 strip 的映像、没有符号表的 hidden visibility）
- 目标、`libwlua.so` 与 `hookso` 之间架构不一致
- 已能证明的 ptrace / 权限限制

## 版本字符串不能证明 ABI 安全

在路径、soname 或二进制字符串中发现 `Lua 5.3`，足以**拒绝**其他主/次版本，但**绝不会**被用来宣称注入在 ABI 上是安全的。

即便已经发现 Lua 5.3 以及所需符号，下列情况仍未得到证明，注入后仍可能让目标进程崩溃：

- 其他 5.3.x 发行版与仓库内 5.3.4 布局的差异
- 编译选项，如 `LUA_32BITS`、不同的 `LUA_NUMBER` / `LUA_INTEGER`，或定制的 `luaconf.h`
- 发行版/厂商补丁、嵌入式分支以及内部修改过的 Lua
- 磁盘映像中可见、但运行时已被剥离或隐藏的符号

预检在成功路径上会打印上述警告。不提供用于绕过失败检查的 `--force` 选项。

## 检查顺序

1. 参数（`--help`、`--dry-run` / `--check`、单个正整数 PID）
2. 主机平台（Linux x86_64）
3. 进程是否存在、是否为僵尸/已退出、`/proc` 是否可读
4. `libwlua.so`（项目根目录、`build/` 或 `WLUA_LIB_SO`）
5. `hookso`（先项目根目录，再 `PATH`；本地文件存在但不可执行会明确报错，不会静默改用 PATH 中的另一个）
6. `PATH` 中的 `gdb`
7. 目标、`libwlua.so`、`hookso` 的 ELF 类别与机器类型
8. ptrace 策略（Yama、uid、dumpable、TracerPid、`CAP_SYS_PTRACE`）
9. 从 `/proc/<pid>/maps` 与可执行文件收集 Lua 变体/版本证据
10. 在这些映像中查找所需符号
11. 最后再次确认进程仍存活
12. 注入（`hookso dlopen` / `call` / `replacep` 以及 gdb 地址解析）；`--dry-run` 时跳过

`./start.sh --dry-run <PID>`（或 `--check`）在第 11 步之后结束，不会注入、不会执行 `gdb -p` 附加，也不会启动 `hookso`。

## 退出码

| 退出码 | 含义 | 典型处理 |
| --- | --- | --- |
| 0 | 成功（dry-run：预检通过；否则已安装 hook） | — |
| 1 | 用法或参数错误 | 传入单个正整数 PID。参见 `--help`。 |
| 2 | 进程不存在、是僵尸，或运行中途退出 | 用 `ps -p <PID>` 确认，并重新启动目标。 |
| 3 | `/proc` 记录或目标可执行文件不可访问 | 以目标进程同一用户或 root 重新运行。wLua 不会改凭据。 |
| 4 | 缺少 `libwlua.so` 或文件不可用 | 自行运行 `./build.sh`。启动脚本不会代为编译。 |
| 5 | 缺少 `hookso` 或不可执行 | 自行编译 [hookso](https://github.com/esrrhs/hookso) 并放到项目目录或 `PATH`。若文件已存在，请自行 `chmod +x hookso`。 |
| 6 | 缺少 `gdb` | 自行安装 `gdb`。启动脚本不会代为安装软件包。 |
| 7 | 不支持的平台或架构 | 使用 Linux x86_64；按目标架构重新编译 `libwlua.so` / `hookso`。 |
| 8 | Lua 未知或不支持 | 使用 PUC-Rio Lua 5.3 进程；LuaJIT 及其他版本会被拒绝。 |
| 9 | 未找到所需符号 | 带符号重新编译目标，或安装可检查的调试符号。仅有版本字符串不够。 |
| 10 | ptrace 或附加权限受限 | 以目标父进程或 root 重新运行，或由管理员调整 ptrace 策略。wLua 不会修改 sysctl。 |
| 11 | 运行时符号地址解析失败 | gdb 已附加但无法解析所需符号；这与一般的注入失败不同。 |
| 12 | `hookso` 注入或 hook 安装失败 | 查看工具输出：进程可能阻止了 `dlopen`，或库仍然不兼容。 |

## ptrace 策略

wLua 在可读取时**只读** `kernel.yama.ptrace_scope`，**从不写入**。

- `0`：不报告 Yama 限制（稍后仍可能被 LSM/seccomp/容器策略拒绝）
- `1`：仅父进程或特权进程可附加；否则预检失败
- `2`：仅特权进程可附加
- `3`：ptrace 已禁用，预检失败
- 文件不存在：不强行假设 Yama 取值，并提示仍可能存在其他限制
- 未知取值：预检失败，而不是猜测可以附加

此处的特权指 euid 0 或 `CAP_SYS_PTRACE`。wLua 不会代为添加该能力，也不会替你执行 `sudo` / `sysctl`。

若系统没有 Yama sysctl，稍后附加失败且输出符合 ptrace 拒绝特征时，仍会归类为 ptrace 拒绝（退出码 10），而不是笼统的注入失败。

## 测试

在项目根目录运行（不编译、不执行 `build.sh`、不真正 `gdb -p`、不真正注入）：

```bash
bash tests/preflight_test.sh
```

测试使用伪造的 `/proc` 树、伪造的 ELF 文件，以及 mock 的 `gdb` / `hookso`。同时会对脚本执行 `bash -n`。

## 环境变量覆盖（测试与诊断）

普通使用不需要这些变量。

- `WLUA_DRY_RUN=1` — 等同于 `--dry-run`
- `WLUA_LIB_SO`、`WLUA_HOOKSO`、`WLUA_GDB` — 覆盖工具路径
- `WLUA_PROC_ROOT` — 伪造的 `/proc` 根目录
- `WLUA_PTRACE_SCOPE_FILE` — 伪造的 Yama sysctl 文件
- `WLUA_SELF_PID`、`WLUA_SELF_EUID`、`WLUA_SELF_STATUS` — 假装当前身份
- `WLUA_UNAME` — 替代 `uname` 的命令
- `WLUA_HIDE_CMDS` — 逗号分隔、视为缺失的命令名
