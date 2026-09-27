# wLua

[<img src="https://img.shields.io/github/license/esrrhs/wLua">](https://github.com/esrrhs/wLua)
[<img src="https://img.shields.io/github/languages/top/esrrhs/wLua">](https://github.com/esrrhs/wLua)
[<img src="https://img.shields.io/github/actions/workflow/status/esrrhs/wLua/cmake.yml?branch=master">](https://github.com/esrrhs/wLua/actions)

> **用于监视运行中 Lua 虚拟机内部状态的高性能诊断与监控工具。**

[English](README.md) | [中文说明](README_CN.md)

---

## 简介
**wLua** 是一个专为 Linux 平台设计的轻量级、无侵入式 Lua 虚拟机运行时诊断工具（`w` 代表 watch）。通过将动态库注入至正在运行的目标 Lua 进程并对核心函数进行符号 Hook，wLua 可实时采集内部运行指标并对异常情况发出告警，全程无需修改业务代码。

## 特性
* **无侵入附加**：基于动态链接库注入与符号 Hook（借助 [hookso](https://github.com/esrrhs/hookso)），随时附加到现有运行中的进程进行观测。
* **Table Rehash 冲突检测**：在哈希表扩容重哈希时，对异常过长的冲突链表进行报警，精准定位恶化性能的热点代码位置。
* **Table 访问频次统计**：按周期统计 Table 的 `get` 与 `set` 调用频次。
* **GC 状态指标统计**：全量 GC 调用频次、单步 GC 步数、单步回收内存量、活跃对象（Black）数量及新建/释放对象计数等。
* **String 分配与缓存分析**：统计短字符串缓存命中率、短字符串复用频次、长字符串分配情况及相关内存占用。
* **高性能开销小**：诊断逻辑轻量，适用于线上性能瓶颈排查与深度调优。

## 前置依赖
* **操作系统**：Linux (x86_64)
* **编译器与构建工具**：CMake (>= 3.12)，C/C++ 编译器 (GCC >= 4.8 或 Clang)
* **调试器**：`gdb`（用于 `start.sh` 解析目标进程的符号地址）
* **注入工具**：[hookso](https://github.com/esrrhs/hookso)（共享库注入与符号替换工具）
* **系统权限**：请确保拥有附加进程的 ptrace 权限（非 root 用户必要时可执行 `sudo sysctl kernel.yama.ptrace_scope=0`）。

## 编译
直接运行编译脚本：
```bash
./build.sh
```
或者使用现代 CMake 构建命令：
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cp build/libwlua.so ./
```
编译完成后将在当前目录下生成 `libwlua.so`。

## 使用方法
1. 下载并编译 [hookso](https://github.com/esrrhs/hookso)，将编译得到的 `hookso` 二进制文件放置于 `wLua` 目录或系统 `PATH` 路径中。
2. 启动或找到需要监控的目标 Lua 进程。
3. 运行 `start.sh` 并传入目标进程 PID：
```bash
./start.sh <PID>
```
4. 在当前目录下查看输出的统计与告警日志 `wlua_result.log`。

## 示例
运行演示脚本 `test.lua`。在该脚本中，因键值构造特征导致哈希槽位发生 100% 冲突，致使哈希表操作与 rehash 耗时显著增加：
```bash
lua test.lua
```
然后在另一个终端运行监视程序，假定目标进程 PID 为 1234：
```bash
./start.sh 1234
```
实时查看日志输出：
```bash
tail -f wlua_result.log
```

### 1. Table Rehash 冲突检测
```text
[2021.3.13,8:30:8]table hash collision max=64 total=64 at @test.lua:17
[2021.3.13,8:30:8]table hash collision max=128 total=128 at @test.lua:17
[2021.3.13,8:30:8]table hash collision max=256 total=256 at @test.lua:17
[2021.3.13,8:30:8]table hash collision max=512 total=512 at @test.lua:17
[2021.3.13,8:30:8]table hash collision max=1024 total=1024 at @test.lua:17
[2021.3.13,8:30:8]table hash collision max=2048 total=2048 at @test.lua:17
[2021.3.13,8:30:8]table hash collision max=4096 total=4096 at @test.lua:17
[2021.3.13,8:30:9]table hash collision max=8192 total=8192 at @test.lua:17
[2021.3.13,8:30:11]table hash collision max=16384 total=16384 at @test.lua:17
```
> * `max`：哈希表中最长的冲突链表长度。
> * `total`：哈希表中总元素数量。
> * 默认当 `max >= 20% * total` 时触发报警输出（比例可配置）。

### 2. Table Get / Set 次数统计
```text
[2021.3.24,7:58:8]table get=1023102 set=360613
[2021.3.24,7:59:8]table get=1023766 set=360613
[2021.3.24,8:0:8]table get=1022092 set=360613
[2021.3.24,8:1:8]table get=1022588 set=360613
[2021.3.24,8:2:8]table get=1019782 set=360613
```

### 3. GC 数据统计
```text
[2021.3.24,7:58:8]gc fullgc=0 step=250 singlestep=4700 singlestep-freesize=9942KB marked-obj=83065 new-obj=331237 free-obj=300028
[2021.3.24,7:59:8]gc fullgc=0 step=300 singlestep=5640 singlestep-freesize=11931KB marked-obj=99678 new-obj=331569 free-obj=360034
[2021.3.24,8:0:8]gc fullgc=0 step=250 singlestep=4700 singlestep-freesize=9942KB marked-obj=83065 new-obj=330732 free-obj=300028
[2021.3.24,8:1:8]gc fullgc=0 step=300 singlestep=5640 singlestep-freesize=11931KB marked-obj=99678 new-obj=330982 free-obj=360036
```
> * `fullgc`：全量 GC 调用次数。
> * `step`：单步 GC 调用次数。
> * `singlestep`：单次单步 GC 执行次数。
> * `singlestep-freesize`：单步 GC 回收的内存总大小。
> * `marked-obj`：标记为活跃（黑色）的对象个数。
> * `new-obj`：新建对象个数。
> * `free-obj`：释放对象个数。

### 4. String 分配统计
```text
[2021.3.24,8:38:22]string alloc=951539 cache=22 short=951517 short-reuse=634333 long=0 short-size=1806KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:39:22]string alloc=1002332 cache=22 short=1002310 short-reuse=668194 long=0 short-size=1957KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:40:22]string alloc=999446 cache=22 short=999424 short-reuse=666268 long=0 short-size=1982KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:41:22]string alloc=993905 cache=22 short=993883 short-reuse=662576 long=0 short-size=2264KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:42:22]string alloc=982166 cache=22 short=982144 short-reuse=654748 long=0 short-size=2237KB short-reuse-size=0KB long-size=0KB
```
> * `alloc`：字符串分配总尝试次数。
> * `cache`：命中字符串缓存（`strcache`）的次数。
> * `short`：分配短字符串次数。
> * `short-reuse`：命中复用已有短字符串的次数。
> * `long`：分配长字符串次数。
> * `short-size` / `short-reuse-size` / `long-size`：对应类别的字符串占用内存大小。

---

## 相关项目
* [lua全家桶](https://github.com/esrrhs/lua-family-bucket)
