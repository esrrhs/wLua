# wLua
[<img src="https://img.shields.io/github/license/esrrhs/wLua">](https://github.com/esrrhs/wLua)
[<img src="https://img.shields.io/github/languages/top/esrrhs/wLua">](https://github.com/esrrhs/wLua)
[<img src="https://img.shields.io/github/actions/workflow/status/esrrhs/wLua/cmake.yml?branch=master">](https://github.com/esrrhs/wLua/actions)

wLua 是用于监视运行中 Lua 虚拟机内部状态的高性能诊断与监控工具。

# 特性
* C++ 编写，基于 Linux 动态库注入与符号 Hook 技术
* 无侵入式附加到现有 Lua 进程进行运行时监控
* 支持对 table rehash 冲突链表过长进行检查与告警
* 支持对 table get / set 访问频率统计
* 支持对 Lua GC 各阶段数据统计（fullgc、step、对象增删等）
* 支持对 string 内存分配与复用状态统计

# 前置依赖
* Linux 操作系统
* CMake (>= 3.12) 与 C/C++ 编译器 (GCC >= 4.8 或 Clang)
* GDB (用于获取目标进程符号地址)
* [hookso](https://github.com/esrrhs/hookso) (进程注入工具)

# 编译
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

# 使用方法
1. 下载并编译 [hookso](https://github.com/esrrhs/hookso)，将编译得到的 `hookso` 二进制放置于当前目录或系统 `PATH` 路径中。
2. 确保目标 Lua 进程具备 ptrace 权限（非 root 用户可能需要配置 `sudo sysctl kernel.yama.ptrace_scope=0`）。

# 示例
运行测试脚本 `test.lua`（示例中由于键值构造导致哈希槽位严重冲突，触发 rehash 耗时激增）：
```bash
lua test.lua
```
在另一个终端运行监视程序，假定目标进程 PID 为 1234：
```bash
./start.sh 1234
```
监视程序注入成功后，分析统计结果会定期输出到当前目录下的 `wlua_result.log` 中。

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
> `max`: 哈希表中最长的冲突链表长度；`total`: 哈希表中总元素数量。默认当 `max >= 20% * total` 时触发报警。

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
> * `fullgc`: 全量 GC 次数
> * `step`: 单步 GC 调用次数
> * `singlestep`: 单次单步 GC 执行次数
> * `singlestep-freesize`: 单步 GC 回收的内存总大小
> * `marked-obj`: 标记为活跃状态（黑色）的对象个数
> * `new-obj`: 新建对象个数
> * `free-obj`: 释放对象个数

### 4. String 分配统计
```text
[2021.3.24,8:38:22]string alloc=951539 cache=22 short=951517 short-reuse=634333 long=0 short-size=1806KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:39:22]string alloc=1002332 cache=22 short=1002310 short-reuse=668194 long=0 short-size=1957KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:40:22]string alloc=999446 cache=22 short=999424 short-reuse=666268 long=0 short-size=1982KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:41:22]string alloc=993905 cache=22 short=993883 short-reuse=662576 long=0 short-size=2264KB short-reuse-size=0KB long-size=0KB
[2021.3.24,8:42:22]string alloc=982166 cache=22 short=982144 short-reuse=654748 long=0 short-size=2237KB short-reuse-size=0KB long-size=0KB
```
> * `alloc`: 字符串分配总次数
> * `cache`: 命中短字符串缓存次数
> * `short`: 分配短字符串次数
> * `short-reuse`: 命中复用短字符串次数
> * `long`: 分配长字符串次数
> * `short-size` / `short-reuse-size` / `long-size`: 对应分类的字符串字节大小

## 其他
* [lua全家桶](https://github.com/esrrhs/lua-family-bucket)
