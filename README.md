# wLua
wLua是监视Lua虚拟内部状态的工具。

# 特性
* C++编写，支持Linux平台
* 通过附加到其他进程上，进行监视
* 支持对table rehash冲突检查
* 支持对table get set次数统计
* 支持对gc数据统计

# 编译
* 运行```./build.sh```编译，生成libwlua.so
* 下载编译[hookso](https://github.com/esrrhs/hookso)，生成```hookso```，```hookso```是注入工具
* 将```./build.sh```、```hookso```放在同级目录即可使用

# 示例
运行test.lua，因为alloc_id函数不合理，导致全部hash冲突，会导致rehash的时间很长
```
# lua test.lua
```
然后运行监视程序，假定PID=1234
```
# ./start.sh 1234
```
然后查看当前目录下的wlua_check.log 
### table rehash 冲突
```
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
max=hashtable里最大的冲突链表长度，total=hashtable总共的元素个数。当max >= 20%*total会告警
### table get set次数
```
[2021.3.24,7:58:8]table get=1023102 set=360613
[2021.3.24,7:59:8]table get=1023766 set=360613
[2021.3.24,8:0:8]table get=1022092 set=360613
[2021.3.24,8:1:8]table get=1022588 set=360613
[2021.3.24,8:2:8]table get=1019782 set=360613
```
### gc数据
```
[2021.3.24,7:58:8]gc fullgc=0 step=250 singlestep=4700 singlestep-freesize=9942KB marked-obj=83065 new-obj=331237 free-obj=300028
[2021.3.24,7:59:8]gc fullgc=0 step=300 singlestep=5640 singlestep-freesize=11931KB marked-obj=99678 new-obj=331569 free-obj=360034
[2021.3.24,8:0:8]gc fullgc=0 step=250 singlestep=4700 singlestep-freesize=9942KB marked-obj=83065 new-obj=330732 free-obj=300028
[2021.3.24,8:1:8]gc fullgc=0 step=300 singlestep=5640 singlestep-freesize=11931KB marked-obj=99678 new-obj=330982 free-obj=360036
```
fullgc是全量gc次数，step是单步gc调用次数，singlestep是单次单步gc调用次数，singlestep-freesize是单步gc总共回收的内存大小，marked-obj是标记为黑色（使用中）的对象个数
new-obj是新建的对象个数，free-obj是释放的对象个数
