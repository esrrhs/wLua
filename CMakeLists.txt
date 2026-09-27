cmake_minimum_required(VERSION 3.12)
project(wlua LANGUAGES C CXX)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Collect Lua core and library source files, excluding standalone CLI tools (lua.c, luac.c)
file(GLOB LUA_SRCS "lua/*.c")
list(REMOVE_ITEM LUA_SRCS
    "${CMAKE_CURRENT_SOURCE_DIR}/lua/lua.c"
    "${CMAKE_CURRENT_SOURCE_DIR}/lua/luac.c"
)

# Shared library for process injection
add_library(wlua SHARED
    main.cpp
    ${LUA_SRCS}
)

target_include_directories(wlua
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/lua
)

target_compile_definitions(wlua
    PRIVATE
        LUA_USE_LINUX
        NDEBUG
)

target_compile_options(wlua
    PRIVATE
        -Wall
        -Wextra
        -O3
        -fPIC
)

target_link_libraries(wlua
    PRIVATE
        ${CMAKE_DL_LIBS}
        m
)

set_target_properties(wlua PROPERTIES
    OUTPUT_NAME "wlua"
    PREFIX "lib"
)
