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

#include "lprefix.h"
#include "lua.hpp"

extern "C" {
#include "ldebug.h"
#include "ldo.h"
#include "lgc.h"
#include "lmem.h"
#include "lobject.h"
#include "lstate.h"
#include "lstring.h"
#include "ltable.h"
#include "lvm.h"
}

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
    fprintf(pLog, "\n\n");
    va_end(ap);

    va_start(ap, fmt);
    vprintf(fmt, ap);
    printf("\n\n");
    va_end(ap);

    fclose(pLog);
}

extern "C" Node *mainposition(const Table *t, const TValue *key);
extern "C" int currentline(CallInfo *ci);

std::set<std::string> g_msg;
std::string g_config_msg_file_name = "wlua_check.log";
int g_config_map_check = 1;
int g_config_map_check_min_size = 128;
int g_config_map_check_scale = 50; // 50%

extern "C" void config_msg_file_name(const char *s) {
    g_config_msg_file_name = s;
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

void add_result(const std::string &str) {
    if (g_msg.find(str) != g_msg.end()) {
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

void check_hash_table(lua_State *L, Table *t, unsigned int nhsize) {
    int total_size = allocsizenode(t);
    if (total_size < g_config_map_check_min_size || total_size >= (int) nhsize) {
        WLOG("check_hash_table no need %p %d %d %d", t, total_size, nhsize, g_config_map_check_min_size);
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
    snprintf(buff, sizeof(buff) - 1, "table hash collision max=%d total=%d at %s:%d\n", maxline, total, source, line);
    add_result(buff);
}

extern "C" void new_luaH_resize(lua_State *L, Table *t, unsigned int nasize, unsigned int nhsize) {
    luaH_resize(L, t, nasize, nhsize);
    if (g_config_map_check != 0) {
        check_hash_table(L, t, nhsize);
    }
}
