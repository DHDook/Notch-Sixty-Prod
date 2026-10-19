# libn60core: portable engine core (E6 S2, E21). No Apple framework, no third-party code.
cmake_minimum_required(VERSION 3.20)
project(n60core LANGUAGES C CXX)

add_library(n60core STATIC src/graph.cpp src/snapshot.cpp src/fft.cpp src/stages_dsp.cpp src/stages_system.cpp)
target_compile_features(n60core PUBLIC cxx_std_20)
target_include_directories(n60core PUBLIC include)
target_compile_options(n60core PRIVATE -Wall -Wextra -Werror -fno-exceptions -fno-rtti)

enable_testing()
add_executable(n60core_graph_test tests/test_graph.c)
set_target_properties(n60core_graph_test PROPERTIES C_STANDARD 11)
target_link_libraries(n60core_graph_test PRIVATE n60core m)
set_target_properties(n60core_graph_test PROPERTIES LINKER_LANGUAGE CXX)
add_test(NAME n60core_graph COMMAND n60core_graph_test)

find_package(Threads REQUIRED)
add_executable(n60core_stages_test tests/test_stages.c)
set_target_properties(n60core_stages_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_stages_test PRIVATE n60core m Threads::Threads)
add_test(NAME n60core_stages COMMAND n60core_stages_test)

add_executable(n60core_alloc_test tests/test_alloc.cpp)
target_link_libraries(n60core_alloc_test PRIVATE n60core)
add_test(NAME n60core_alloc COMMAND n60core_alloc_test)

add_executable(n60core_dsp_test tests/test_dsp.c)
set_target_properties(n60core_dsp_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_dsp_test PRIVATE n60core m)
add_test(NAME n60core_dsp COMMAND n60core_dsp_test)

add_executable(n60core_system_test tests/test_system.c)
set_target_properties(n60core_system_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_system_test PRIVATE n60core m)
add_test(NAME n60core_system COMMAND n60core_system_test)

add_executable(n60core_rebuild_test tests/test_rebuild.c)
set_target_properties(n60core_rebuild_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_rebuild_test PRIVATE n60core m)
add_test(NAME n60core_rebuild COMMAND n60core_rebuild_test)
