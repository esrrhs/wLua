#include <string>
#include <list>
#include <vector>
#include <map>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <iostream>
#include <string>
#include <cstdlib>
#include <cstring>
#include <typeinfo>
#include <stdio.h>
#include <time.h>
#include <stdarg.h>
#include <assert.h>
#include <math.h>
#include <sys/time.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <unordered_map>
#include <fcntl.h>
#include <sstream>
#include <algorithm>
#include <vector>
#include <unordered_set>
#include <set>

extern "C" {
#include "lua/lprefix.h"
#include "lua/lua.hpp"
#include "lua/ldebug.h"
#include "lua/ldo.h"
#include "lua/lgc.h"
#include "lua/lmem.h"
#include "lua/lobject.h"
#include "lua/lstate.h"
#include "lua/lstring.h"
#include "lua/ltable.h"
#include "lua/lvm.h"
}

extern "C" const TValue *luaH_get(Table *t, const TValue *key);

const int open_debug = 0;

#define WLOG(...) if (open_debug) {wlog("[DEBUG] ", __FILE__, __FUNCTION__, __LINE__, __VA_ARGS__);}
#define WERR(...) if (open_debug) {wlog("[ERROR] ", __FILE__, __FUNCTION__, __LINE__, __VA_ARGS__);}

void wlog(const char *header, const char *file, const char *func, int pos, const char *fmt, ...) {
    FILE *pLog = NULL;
    time_t clock1;
    struct tm *tptr;
    va_list ap;

    pLog = fopen("wlua.log", "a+");
    if (pLog == NULL) {
        return;
    }

    clock1 = time(0);
    tptr = localtime(&clock1);

    struct timeval tv;
    gettimeofday(&tv, NULL);

    fprintf(pLog, "===========================[%d.%d.%d, %d.%d.%d %llu]%s:%d,%s:===========================\n%s",
            tptr->tm_year + 1990, tptr->tm_mon + 1,
            tptr->tm_mday, tptr->tm_hour, tptr->tm_min,
            tptr->tm_sec, (long long) ((tv.tv_sec) * 1000 + (tv.tv_usec) / 1000), file, pos, func, header);

    va_start(ap, fmt);
    vfprintf(pLog, fmt, ap);
    fprintf(pLog, "\n");
    va_end(ap);

    va_start(ap, fmt);
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);

    fclose(pLog);
}

// important
extern "C" void set_lua_nilobject(TValue *p) {
    luaO_nilobject_p = p;
}

extern "C" Node *mainposition(const Table *t, const TValue *key);
extern "C" int currentline(CallInfo *ci);

std::set <std::string> g_msg;
std::string g_config_msg_file_name = "wlua_result.log";

time_t g_config_inter_last_time = 0;
int g_config_inter_time = 60;

int g_config_map_check = 1;
int g_config_map_check_min_size = 128;
int g_config_map_check_scale = 20; // 20%

int g_config_map_getset = 1;
int g_config_map_getset_get_num = 0;
int g_config_map_getset_set_num = 0;

int g_config_gc = 1;
int g_config_gc_fullgc_num = 0;
int g_config_gc_step_num = 0;
int g_config_gc_singlestep_num = 0;
lu_mem g_config_gc_singlestep_size = 0;
int g_config_gc_markobj_num = 0;
int g_config_gc_newobj_num = 0;
int g_config_gc_freeobj_num = 0;

int g_config_string = 1;
int g_config_string_alloc = 0;
int g_config_string_alloc_cache = 0;
int g_config_string_alloc_short = 0;
size_t g_config_string_alloc_short_size = 0;
int g_config_string_alloc_short_reuse = 0;
size_t g_config_string_alloc_short_reuse_size = 0;
int g_config_string_alloc_long = 0;
size_t g_config_string_alloc_long_size = 0;

extern "C" void config_msg_file_name(const char *s) {
    g_config_msg_file_name = s;
}

extern "C" void config_inter_time(int n) {
    g_config_inter_time = n;
}

extern "C" void config_map_check(int n) {
    g_config_map_check = n;
}

extern "C" void config_map_check_min_size(int n) {
    g_config_map_check_min_size = n;
}

extern "C" void config_map_check_scale(int n) {
    g_config_map_check_scale = n;
}

extern "C" void config_map_getset(int n) {
    g_config_map_getset = n;
}

extern "C" void config_gc(int n) {
    g_config_gc = n;
}

extern "C" void config_string(int n) {
    g_config_string = n;
}

void add_result(const std::string &str, bool uniq) {
    if (uniq && g_msg.find(str) != g_msg.end()) {
        return;
    }
    g_msg.insert(str);

    FILE *fptr = fopen(g_config_msg_file_name.c_str(), "a");
    if (!fptr) {
        WERR("open file %s fail", g_config_msg_file_name.c_str());
        return;
    }

    time_t clock = time(0);
    struct tm *tptr = localtime(&clock);
    fprintf(fptr, "[%d.%d.%d,%d:%d:%d]%s\n",
            tptr->tm_year + 1900, tptr->tm_mon + 1,
            tptr->tm_mday, tptr->tm_hour, tptr->tm_min,
            tptr->tm_sec, str.c_str());
    fclose(fptr);
}

extern "C" void check_hash_table(lua_State *L, Table *t) {
    int total_size = allocsizenode(t);
    if (total_size < g_config_map_check_min_size) {
        WLOG("check_hash_table no need %p %d %d", t, total_size, g_config_map_check_min_size);
        return;
    }
    Node *n = t->node;
    int j;
    int total = 0;
    CallInfo *ci = L->ci;
    if (!ci) {
        WLOG("check_hash_table no CallInfo %p", t);
        return;
    }
    StkId func = ci->func;
    if (!func) {
        WLOG("check_hash_table no func %p", t);
        return;
    }
    Closure *cl = ttisclosure(func) ? clvalue(func) : NULL;
    if (!cl) {
        WLOG("check_hash_table no Closure %p", t);
        return;
    }
    Proto *p = cl->l.p;
    if (!p) {
        WLOG("check_hash_table no Proto %p", t);
        return;
    }
    int maxline = 0;
    for (j = total_size - 1; j >= 0; j--) {
        Node *old = n + j;
        if (!ttisnil(gval(old))) {
            if (gnext(old) == 0) {
                Node *othern = mainposition(t, gkey(old));
                int line = 0;
                for (;;) {
                    int nx = gnext(othern);
                    line++;
                    if (nx == 0)
                        break;
                    othern += nx;
                }
                WLOG("check_hash_table get line %p %d", t, line);
                if (line > maxline) {
                    maxline = line;
                }
            }
            total++;
        }
    }
    WLOG("check_hash_table get maxline %p %d %d", t, maxline, total);
    if (maxline < total * g_config_map_check_scale / 100) {
        return;
    }
    int line = (ci && isLua(ci)) ? currentline(ci) : -1;
    const char *source = p->source ? getstr(p->source) : "=?";

    char buff[512] = {0};
    snprintf(buff, sizeof(buff) - 1, "table hash collision max=%d total=%d at %s:%d", maxline, total, source, line);
    add_result(buff, true);
}

void check_inter(lua_State *L) {
    time_t clock = time(0);
    if (clock < g_config_inter_last_time + g_config_inter_time) {
        return;
    }
    g_config_inter_last_time = clock;

    char buff[512] = {0};

    if (g_config_map_getset != 0) {
        snprintf(buff, sizeof(buff) - 1, "table get=%d set=%d", g_config_map_getset_get_num,
                 g_config_map_getset_set_num);
        add_result(buff, false);
        g_config_map_getset_get_num = 0;
        g_config_map_getset_set_num = 0;
    }

    if (g_config_gc != 0) {
        snprintf(buff, sizeof(buff) - 1,
                 "gc fullgc=%d step=%d singlestep=%d singlestep-freesize=%dKB marked-obj=%d new-obj=%d free-obj=%d",
                 g_config_gc_fullgc_num, g_config_gc_step_num, g_config_gc_singlestep_num,
                 (int) (g_config_gc_singlestep_size / 1024), g_config_gc_markobj_num, g_config_gc_newobj_num,
                 g_config_gc_freeobj_num);
        add_result(buff, false);
        g_config_gc_fullgc_num = 0;
        g_config_gc_step_num = 0;
        g_config_gc_singlestep_num = 0;
        g_config_gc_singlestep_size = 0;
        g_config_gc_markobj_num = 0;
        g_config_gc_newobj_num = 0;
        g_config_gc_freeobj_num = 0;
    }

    if (g_config_string != 0) {
        snprintf(buff, sizeof(buff) - 1,
                 "string alloc=%d cache=%d short=%d short-reuse=%d long=%d short-size=%dKB short-reuse-size=%dKB long-size=%dKB",
                 g_config_string_alloc, g_config_string_alloc_cache, g_config_string_alloc_short,
                 g_config_string_alloc_short_reuse, g_config_string_alloc_long,
                 (int) (g_config_string_alloc_short_size / 1024),
                 (int) (g_config_string_alloc_short_reuse_size / 1024), (int) (g_config_string_alloc_long_size / 1024));
        add_result(buff, false);
        g_config_string_alloc = 0;
        g_config_string_alloc_cache = 0;
        g_config_string_alloc_short = 0;
        g_config_string_alloc_short_reuse = 0;
        g_config_string_alloc_long = 0;
        g_config_string_alloc_short_size = 0;
        g_config_string_alloc_short_reuse_size = 0;
        g_config_string_alloc_long_size = 0;
    }
}

extern "C" void new_luaH_resize(lua_State *L, Table *t, unsigned int nasize, unsigned int nhsize) {
    luaH_resize(L, t, nasize, nhsize);
}

extern "C" const TValue *new_luaH_get(Table *t, const TValue *key) {
    return luaH_get(t, key);
}

extern "C" TValue *new_luaH_set(lua_State *L, Table *t, const TValue *key) {
    check_inter(L);
    return luaH_set(L, t, key);
}

extern "C" void new_luaC_fullgc(lua_State *L, int isemergency) {
    check_inter(L);
    luaC_fullgc(L, isemergency);
}

extern "C" void new_luaC_step(lua_State *L) {
    check_inter(L);
    luaC_step(L);
}

extern "C" GCObject *new_luaC_newobj(lua_State *L, int tt, size_t sz) {
    check_inter(L);
    return luaC_newobj(L, tt, sz);
}

extern "C" TString *new_luaS_new(lua_State *L, const char *str) {
    check_inter(L);
    return luaS_new(L, str);
}

extern "C" TString *new_luaS_newlstr(lua_State *L, const char *str, size_t l) {
    check_inter(L);
    return luaS_newlstr(L, str, l);
}
