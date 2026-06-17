if(NOT DEFINED PLATFORM)
  set(PLATFORM "OS64")
endif()

include("${CMAKE_CURRENT_LIST_DIR}/ios-cmake/ios.toolchain.cmake")

list(INSERT CMAKE_FIND_ROOT_PATH 0
     "/Users/vinayak/Documents/vterm/ros2-ios/deps/install-ios")
list(APPEND CMAKE_FIND_ROOT_PATH
     "/opt/homebrew/Cellar/micromamba/2.3.2/envs/ros2_jazzy")

list(PREPEND CMAKE_PREFIX_PATH
     "/Users/vinayak/Documents/vterm/ros2-ios/deps/install-ios")
list(APPEND CMAKE_PREFIX_PATH
     "/opt/homebrew/Cellar/micromamba/2.3.2/envs/ros2_jazzy")

set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)

set(HAVE_LIBATOMICS FALSE CACHE BOOL "No separate libatomic on iOS" FORCE)

set(Python3_EXECUTABLE
    "/opt/homebrew/Cellar/micromamba/2.3.2/envs/ros2_jazzy/bin/python3"
    CACHE FILEPATH "Python3 with ament_package installed" FORCE)
set(PYTHON_EXECUTABLE
    "/opt/homebrew/Cellar/micromamba/2.3.2/envs/ros2_jazzy/bin/python3"
    CACHE FILEPATH "Python interpreter" FORCE)
