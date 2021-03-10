cmake_minimum_required(VERSION 2.8)
project(wlua)
aux_source_directory(. wlua_src)
aux_source_directory(./lua wlua_src)
INCLUDE_DIRECTORIES(./lua)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -g3 -std=c++11 -DNDEBUG -O3 ")

add_library(wlua SHARED ${wlua_src})
TARGET_LINK_LIBRARIES(wlua)
