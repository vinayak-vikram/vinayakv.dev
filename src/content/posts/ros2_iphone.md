---
title: "Cross-compiling ROS2 for iPhone"
date: "March 31, 2026"
description: "Cross-compiling ROS2 for iPhone. Goal is to bundle basic node and messaging functionality, and maybe a localized python for quick testing purposes."
---

<github>vinayak-vikram/vterm</github>

## Preliminary concerns

I genuinely have no clue as to why I decided to attempt this, given all there is that could be annoying. Some of my preliminary concerns and thoughts are below:

- Lack of dylib support on iOS; will have to bundle everything which is... unfortunate
- ROS2 DDS uses multicast UDP, which is blocked on iOS; will have to figure out how to either configure unicast DDS or swap to Zenoh or something (but the latter loses quite a bit of functionality)
- `rcl_interfaces` and `std_msgs` are `.msg` files that need to be generated with rosidl on my native installation before the output is compiled for iOS

## Porting CycloneDDS

After a bit of googling, I found out that I need to compile this twice; the first time to get the IDL compiler running and then the iOS build using those host tools. For iOS compilation, I had to check out the [iOS CMake tools](https://github.com/leetal/ios-cmake).

### Building

I began by checking out CycloneDDS 0.10.5, for ROS2 Jazzy compatibility.

To build natively, all I had to do was set the flags `BUILD_SHARED_LIBS=OFF`, `ENABLE_SSL=OFF`, `ENABLE_SECURITY=OFF`, `ENABLE_SHM=OFF` (I also set the build type to release). This generated the file `build/ImportExecutables.cmake` which is what the later iOS build imports to find `idlc`.

iOS make was similar; all I had to do was link the iOS CMake toolchain downloaded earlier. Building was relatively simple as well; I only had to patch `net/if_media.h` which is for wired/wireless connection detection (MacOS only header), which isn't really relevant in our use case. I simply used `__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__` to guard against it. Installation was fine; `lipo -info` gave architecture arm64 (non-fat file).

## Building ROS2

Who would have guessed, the shitshow that people call ROS would naturally be quite a bit more challenging to compile than CycloneDDS. The main issue is that when we use our native ROS2 workspace to compile, `AMENT_PREFIX_PATH` is set to a list of native install prefixes, which when read by CMake links native libraries instead of building in static libs. Just a small example, `find_package(rosidl_typesupport_c)` points to the native FastRTPS-enabled version which is dynamically linked.

To fix this, we need two things:

- set `CMAKE_FIND_ROOT_PATH_MODE_*=BOTH` so that CMake checks the iOS prefix before the host prefix (both is needed so that ament_cmake generator scripts are still found)
- make sure that `install-ios` is at the beginning of both `CMAKE_FIND_ROOT_PATH` and `CMAKE_PREFIX_PATH` so that the iOS libraries are prioritized

I eventually ended up writing a custom wrapper around the aforementioned ios-cmake toolchain that bundled the fixes above. Oh, also, there's no libatomic on iOS. wtf.

<file>/assets/ros2_ios.toolchain.cmake</file>

### The ROS2 Dependency Tree

The dependency tree for ROS2 is extremely confusing, much more so than it appears in the `package.xml` files. I eventually had to go with the build order below:

1. `rosidl_cmake`, `rosidl_cli`, `rosidl_pycommon`, `rosidl_parser`, `rosidl_adapter`, `rosidl_generator_type_description` (cmake/python-only rosidl support)
2. `rosidl_generator_c`, `rosidl_generator_cpp` (rosidl generators, cmake-only, no compiled code)
3. `rosidl_typesupport_c`, `rosidl_typesupport_cpp` (compiled C/C++ libs)
4. `libyaml 0.2.5` (had to manually build this, it was a pain in the ass)
5. `rcl_yaml_param_parser` (originally linked libyaml.dylib, had to rebuild)
6. `rcpputils`, `ament_index_cpp`, `ament_index_python` (C++ utilities)
7. `builtin_interfaces`, `service_msgs`, `rcl_interfaces`, `type_description_interfaces`, `rosgraph_msgs`, `statistics_msgs` (message interfaces, rosidl code generation)
8. `rosidl_dynamic_typesupport`
9. `rmw_implementation_cmake`, `rmw_dds_common`, `rmw_cyclonedds_cpp`, `rmw_implementation`
10. `rcl`, with `-DRCL_LOGGING_IMPLEMENTATION=rcl_logging_noop`
11. `libstatistics_collector`
12. `rclcpp`, `std_msgs`

#### rosidl generator & support packages

I had to do two things; a) set the platform in the ios-cmake wrapper and b) make sure the micromamba path was prepended before running colcon. Then, I simply ran:

```bash
colcon build \
  --base-paths src \
  --build-base build-ios --install-base install-ios --merge-install \
  --packages-select \
    rosidl_cmake rosidl_parser rosidl_cli rosidl_pycommon \
    rosidl_adapter rosidl_generator_type_description \
    rosidl_generator_c rosidl_generator_cpp \
  --cmake-args \
    -DCMAKE_TOOLCHAIN_FILE=.../toolchain/ros2_ios.toolchain.cmake \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DCMAKE_BUILD_TYPE=Release -DHAVE_LIBATOMICS=FALSE \
    -DTRACETOOLS_DISABLED=ON
```

8 packages finished. All cmake/python-only, no compiled code.

#### rosidl typesupport compiled libs

This was fine; the same flags used for the previous command worked here. No issues arose.

#### message interfaces

When building `rcl_interfaces` directly, cmake loaded the native `service_msgs` package (from the native ROS2 install) which was built with FastRTPS typesupport. The generated cmake targets reference `builtin_interfaces::builtin_interfaces__rosidl_typesupport_fastrtps_c` which doesn't exist in our iOS build.

To fix, I just built `builtin_interfaces` and `service_msgs` for iOS first. Once they are in `install-ios/`, the toolchain's priority order ensures they are found instead of the native ones.

#### libyaml for iOS

`rcl` needs `libyaml` via the `libyaml_vendor` cmake package. The Jazzy version of `libyaml_vendor` requires `ament_cmake_vendor_package`, a newer ament cmake extension that is not installed in the micromamba env.

Rather than trying to upgrade ament_cmake, I bypassed the vendor wrapper entirely and compiled `libyaml 0.2.5` directly with our iOS toolchain:

```bash
git clone https://github.com/yaml/libyaml.git /tmp/libyaml-src \
  --depth 1 --branch 0.2.5

cmake /tmp/libyaml-src -B /tmp/libyaml-build-ios \
  -DCMAKE_TOOLCHAIN_FILE=.../toolchain/ros2_ios.toolchain.cmake \
  -DPLATFORM=OS64 \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$PWD/install-ios \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5

cmake --build /tmp/libyaml-build-ios -- -j4
cmake --install /tmp/libyaml-build-ios
```

This installs `install-ios/lib/libyaml.a`, `install-ios/include/yaml.h`, and `install-ios/cmake/yamlConfig.cmake`.

Downstream packages call `find_package(libyaml_vendor)`, so I created a stub config so this succeeds and finds our iOS libyaml.

The originally-built `rcl_yaml_param_parser` had linked against the native `libyaml.dylib` (visible in its cmake cache as `pkgcfg_lib_YAML_PKG_CONFIG_yaml = .../libyaml.dylib`). After creating the stub, I cleared its build cache and rebuilt.

#### rcl & dependencies

I needed to clone a few missing repos:

```bash
git clone https://github.com/ros2/rcpputils.git \
    src/rcpputils --branch jazzy --depth 1
git clone https://github.com/ament/ament_index.git \
    src/ament_index --branch jazzy --depth 1
git clone https://github.com/ros2/rmw_implementation.git \
    src/rmw_implementation --branch jazzy --depth 1
git clone https://github.com/ros2/rosidl_dynamic_typesupport.git \
    src/rosidl_dynamic_typesupport --branch jazzy --depth 1
git clone https://github.com/ros-tooling/libstatistics_collector.git \
    src/libstatistics_collector --branch jazzy --depth 1
```

Colcon's pre-build dependency check looks for a `package.sh` file in the install prefix for every package listed in `package.xml` as a dependency, even those we intentionally skip (spdlog, test packages, iceoryx, etc.). I fixed it by creating empty stub files:

```bash
for pkg in rcl_logging_spdlog test_msgs std_msgs \
           iceoryx_hoofs iceoryx_posh iceoryx_binding_c \
           cyclonedds ament_index_python; do
  mkdir -p install-ios/share/${pkg}/
  echo "# blah" > install-ios/share/${pkg}/package.sh
done
```

I also hit a missing header error:

```
fatal error: 'rosidl_dynamic_typesupport/api/serialization_support.h' file not found
```

`rcl`'s `event.c` indirectly includes a header from `rosidl_dynamic_typesupport` via the `rmw` headers. The package wasn't in our source tree, so I cloned and built it:

```bash
git clone https://github.com/ros2/rosidl_dynamic_typesupport.git \
    src/rosidl_dynamic_typesupport --branch jazzy
colcon build ... --packages-select rosidl_dynamic_typesupport
```

`rcl` defaults to `rcl_logging_spdlog`, which I overrode since spdlog requires a vendor build that isn't essential for an embedded iOS application:

```bash
colcon build ... --packages-select rcl \
  --cmake-args ... -DRCL_LOGGING_IMPLEMENTATION=rcl_logging_noop
```

`librcl.a` built in ~13s. Architecture: arm64.

One more catch: when `libstatistics_collector` ran `find_package(rcl)`, cmake processed `rclExport.cmake` which records `rcl_logging_noop::rcl_logging_noop` as a LINK_ONLY dependency target. Since `rcl_logging_noop` hadn't been found via `find_package` in that cmake session, the target didn't exist:

```
CMake Error at install-ios/share/rcl/cmake/rclExport.cmake:61:
  The link interface of target "rcl::rcl" contains:
    rcl_logging_noop::rcl_logging_noop
  but the target was not found.
```

Fix: patched `install-ios/share/rcl/cmake/ament_cmake_export_dependencies-extras.cmake` to add `rcl_logging_noop` and `service_msgs` to the `_exported_dependencies` list:

```cmake
set(_exported_dependencies
  "ament_cmake;rcl_interfaces;rcl_logging_interface;rcl_logging_noop;
   rcl_yaml_param_parser;rcutils;rmw;rmw_implementation;rosidl_runtime_c;
   service_msgs;type_description_interfaces")
```

#### RMW / CycloneDDS

`rmw_cyclonedds_cpp` conditionally requires `iceoryx_binding_c` only when CycloneDDS was compiled with SHM support. Our iOS CycloneDDS was built with `SHM_SUPPORT_IS_AVAILABLE "OFF"`, so iceoryx is not required at cmake level. However colcon's pre-build check still sees the `<depend>iceoryx_binding_c</depend>` in the `package.xml` and wants stub files (handled above).

```bash
# rmw_dds_common: rosidl-generated msg lib for DDS common messages
colcon build ... --packages-select rmw_dds_common

# rmw_cyclonedds_cpp: needs both install/ (CycloneDDS) and install-ios/
colcon build ... --packages-select rmw_cyclonedds_cpp \
  --cmake-args ... \
  "-DCMAKE_PREFIX_PATH=.../deps/install;.../deps/install-ios"

# rmw_implementation: the proxy that selects the active RMW at load time
colcon build ... --packages-select rmw_implementation \
  --cmake-args ... \
  "-DCMAKE_PREFIX_PATH=.../deps/install;.../deps/install-ios"
```

The two `CMAKE_PREFIX_PATH` entries for `rmw_cyclonedds_cpp`: CycloneDDS was installed to `install/` (not `install-ios/`) and its cmake config lives at `install/lib/cmake/CycloneDDS/`. The toolchain's `CMAKE_FIND_ROOT_PATH` already includes `install-ios`, but `install/` is a separate prefix that must be passed explicitly.

#### rclcpp & std_msgs

`rclcpp` depends on `libstatistics_collector` (from `ros-tooling/libstatistics_collector` on the `jazzy` branch). Its dependencies were all already available at this point.

```bash
colcon build ... --packages-select libstatistics_collector

colcon build ... --packages-select rclcpp \
  --cmake-args ... -DRCL_LOGGING_IMPLEMENTATION=rcl_logging_noop

colcon build ... --packages-select std_msgs
```

Compiling both of these took quite a while (around 2 min each). `lipo -info install-ios/lib/librclcpp.a` gives `arm64`. Same for `libstd_msgs__rosidl_typesupport_c.a`.

### Verification

All 59 static libraries in `install-ios/lib/` confirmed arm64 via `lipo -info`. If you decide to build this, I'd check:

- `librcl.a`
- `librclcpp.a`
- `librmw_cyclonedds_cpp.a`
- `librmw_dds_common.a`
- `librosidl_typesupport_c.a` / `librosidl_typesupport_cpp.a`
- `libstd_msgs__rosidl_typesupport_c.a` / `libstd_msgs__rosidl_typesupport_cpp.a`
- `libyaml.a`, `libament_index_cpp.a`, `librcpputils.a`, `librcutils.a`
- `liblibstatistics_collector.a`, `librosidl_dynamic_typesupport.a`, `librcl_yaml_param_parser.a`

CycloneDDS at `install/lib/libddsc.a` (also arm64) provides the DDS transport layer.

## Quick build

<file>/assets/ros2_ios_quickbuild.sh</file>
