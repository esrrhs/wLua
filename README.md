# wLua

[<img src="https://img.shields.io/github/license/esrrhs/wLua">](https://github.com/esrrhs/wLua)
[<img src="https://img.shields.io/github/languages/top/esrrhs/wLua">](https://github.com/esrrhs/wLua)
[<img src="https://img.shields.io/github/actions/workflow/status/esrrhs/wLua/cmake.yml?branch=master">](https://github.com/esrrhs/wLua/actions)

> **A runtime state monitoring and diagnostic tool for running Lua virtual machines.**

[English](README.md) | [中文说明](README_CN.md)

---

## Overview
**wLua** (`w` stands for watch) is a lightweight, non-intrusive runtime diagnostic tool designed to monitor and inspect the internal state of a running Lua virtual machine on Linux. By attaching dynamically to an existing Lua process, wLua provides real-time statistics and alerts without modifying the target application's code.

## Features
* **Non-Intrusive Attachment**: Inspects running Lua processes dynamically via shared library injection and symbol hooking (`hookso`).
* **Table Rehash Collision Detection**: Alerts when hash table collision chains exceed thresholds during table resize.
* **Table Access Statistics**: Tracks the frequency of table `get` and `set` operations over configurable intervals.
* **Garbage Collection (GC) Monitoring**: Detailed metrics on GC phases, including full GC counts, step invocations, swept memory size, and live/freed objects.
* **String Allocation & Cache Profiling**: Analyzes short string cache hits, short string reuse, long string allocations, and memory sizes.
* **High Performance**: Minimal overhead, suitable for diagnosing production and debugging performance bottlenecks.

## Prerequisites
* **Operating System**: Linux (x86_64)
* **Compiler & Build Tools**: CMake (>= 3.12), C/C++ compiler (GCC or Clang)
* **Debugger**: `gdb` (used by `start.sh` to resolve symbol addresses in the target process)
* **Process Injector**: [hookso](https://github.com/esrrhs/hookso) (shared library injector)
* **Permissions**: Ensure ptrace permission is enabled for attaching to target processes (`sudo sysctl kernel.yama.ptrace_scope=0` if needed).

## Build
Run the build script:
```bash
./build.sh
```
Or use modern CMake commands:
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cp build/libwlua.so ./
```
The compiled shared library `libwlua.so` will be created in the project root directory.

## Usage
1. Download and build [hookso](https://github.com/esrrhs/hookso), then place the `hookso` binary into the `wLua` directory or in your system `PATH`.
2. Start or locate your target Lua process.
3. Attach `wLua` using `start.sh` with the target process PID:
```bash
./start.sh <PID>
```
4. Check the real-time statistics and collision alerts in `wlua_result.log`.

## Examples
Run the demo script `test.lua`. In this script, poorly chosen keys lead to 100% hash collisions in Lua 5.3, making rehash and table operations significantly slower:
```bash
lua test.lua
```
Then in another terminal, run the monitoring script (assuming the target PID is 1234):
```bash
./start.sh 1234
```
Monitor the output log:
```bash
tail -f wlua_result.log
```

### 1. Table Rehash Collision Detection
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
> * `max`: The length of the longest collision chain in the hash table.
> * `total`: Total number of elements in the hash table.
> * An alert is logged when `max >= 20% * total` (configurable).

### 2. Table Get / Set Operation Counts
```text
[2021.3.24,7:58:8]table get=1023102 set=360613
[2021.3.24,7:59:8]table get=1023766 set=360613
[2021.3.24,8:0:8]table get=1022092 set=360613
[2021.3.24,8:1:8]table get=1022588 set=360613
[2021.3.24,8:2:8]table get=1019782 set=360613
```

### 3. GC Statistics
```text
[2021.3.24,7:58:8]gc fullgc=0 step=250 singlestep=4700 singlestep-freesize=9942KB marked-obj=83065 new-obj=331237 free-obj=300028
[2021.3.24,7:59:8]gc fullgc=0 step=300 singlestep=5640 singlestep-freesize=11931KB marked-obj=99678 new-obj=331569 free-obj=360034
[2021.3.24,8:0:8]gc fullgc=0 step=250 singlestep=4700 singlestep-freesize=9942KB marked-obj=83065 new-obj=330732 free-obj=300028
[2021.3.24,8:1:8]gc fullgc=0 step=300 singlestep=5640 singlestep-freesize=11931KB marked-obj=99678 new-obj=330982 free-obj=360036
```
> * `fullgc`: Number of full garbage collection runs.
> * `step`: Number of GC step invocations.
> * `singlestep`: Number of individual single steps performed.
> * `singlestep-freesize`: Total memory reclaimed during GC single steps.
> * `marked-obj`: Count of marked live (black) objects.
> * `new-obj`: Number of newly allocated objects.
> * `free-obj`: Number of freed objects.

### 4. String Statistics
```text
[2021.3.24,8:38:22]string alloc=951539 cache=22 short=951517 short-reuse=634333 long=0 short-size=1806KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:39:22]string alloc=1002332 cache=22 short=1002310 short-reuse=668194 long=0 short-size=1957KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:40:22]string alloc=999446 cache=22 short=999424 short-reuse=666268 long=0 short-size=1982KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:41:22]string alloc=993905 cache=22 short=993883 short-reuse=662576 long=0 short-size=2264KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:42:22]string alloc=982166 cache=22 short=982144 short-reuse=654748 long=0 short-size=2237KB short-reuse-size=0KB long-size=0KB
```
> * `alloc`: Total string allocation attempts.
> * `cache`: Hits in the global string cache (`strcache`).
> * `short`: Number of short strings allocated.
> * `short-reuse`: Number of reused existing short strings.
> * `long`: Number of long strings allocated.
> * `short-size` / `short-reuse-size` / `long-size`: Memory sizes for corresponding categories.

---

## Related Projects / 其他
* [lua全家桶 / Lua Family Bucket](https://github.com/esrrhs/lua-family-bucket)
