export PATH="/opt/homebrew/Cellar/micromamba/2.3.2/envs/ros2_jazzy/bin:$PATH"
cd /Users/vinayak/Documents/vterm/ros2-ios/deps

TOOLCHAIN="-DCMAKE_TOOLCHAIN_FILE=/Users/vinayak/Documents/vterm/ros2-ios/toolchain/ros2_ios.toolchain.cmake"
COMMON_FLAGS="-DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release \
  -DHAVE_LIBATOMICS=FALSE -DTRACETOOLS_DISABLED=ON"

# libyaml manually
git clone https://github.com/yaml/libyaml.git /tmp/libyaml-src --depth 1 --branch 0.2.5
cmake /tmp/libyaml-src -B /tmp/libyaml-build-ios \
  $TOOLCHAIN -DPLATFORM=OS64 -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$PWD/install-ios -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build /tmp/libyaml-build-ios -- -j4 && cmake --install /tmp/libyaml-build-ios

git clone https://github.com/ros2/rcpputils.git src/rcpputils --branch jazzy --depth 1
git clone https://github.com/ament/ament_index.git src/ament_index --branch jazzy --depth 1
git clone https://github.com/ros2/rmw_implementation.git src/rmw_implementation --branch jazzy --depth 1
git clone https://github.com/ros2/rosidl_dynamic_typesupport.git src/rosidl_dynamic_typesupport --branch jazzy --depth 1
git clone https://github.com/ros-tooling/libstatistics_collector.git src/libstatistics_collector --branch jazzy --depth 1

for pkg in rcl_logging_spdlog test_msgs std_msgs \
           iceoryx_hoofs iceoryx_posh iceoryx_binding_c cyclonedds ament_index_python; do
  mkdir -p install-ios/share/${pkg}/
  echo "# stub" > install-ios/share/${pkg}/package.sh
done

# rosidl cmake/python+generators
colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install \
  --packages-select rosidl_cmake rosidl_parser rosidl_cli rosidl_pycommon \
    rosidl_adapter rosidl_generator_type_description rosidl_generator_c rosidl_generator_cpp \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS

# rosidl typesupport
colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install \
  --packages-select rosidl_typesupport_c rosidl_typesupport_cpp \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS

# message interfaces
colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install \
  --packages-select builtin_interfaces service_msgs \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS

colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install \
  --packages-select rcl_interfaces type_description_interfaces rosgraph_msgs statistics_msgs \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS

# c++ utils
colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install \
  --packages-select rcpputils ament_index_cpp ament_index_python \
    rmw_implementation_cmake rosidl_dynamic_typesupport \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS

# rcl_yaml_param_parser with our custom libyaml
rm -rf build-ios/rcl_yaml_param_parser
colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install --packages-select rcl_yaml_param_parser \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS

# rcl
colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install --packages-select rcl \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS -DRCL_LOGGING_IMPLEMENTATION=rcl_logging_noop

# PATCH: add rcl_logging_noop + service_msgs to rcl's exported deps:
# edit install-ios/share/rcl/cmake/ament_cmake_export_dependencies-extras.cmake

# rmw stack
colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install --packages-select rmw_dds_common \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS

colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install --packages-select rmw_cyclonedds_cpp \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS \
  "-DCMAKE_PREFIX_PATH=/Users/vinayak/Documents/vterm/ros2-ios/deps/install;/Users/vinayak/Documents/vterm/ros2-ios/deps/install-ios"

colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install --packages-select rmw_implementation \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS \
  "-DCMAKE_PREFIX_PATH=/Users/vinayak/Documents/vterm/ros2-ios/deps/install;/Users/vinayak/Documents/vterm/ros2-ios/deps/install-ios"

# top level packages
colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install --packages-select libstatistics_collector \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS

colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install --packages-select rclcpp \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS -DRCL_LOGGING_IMPLEMENTATION=rcl_logging_noop

colcon build --base-paths src --build-base build-ios --install-base install-ios \
  --merge-install --packages-select std_msgs \
  --cmake-args $TOOLCHAIN $COMMON_FLAGS

# verify
for f in install-ios/lib/*.a; do
  printf "%-65s %s\n" "$(basename $f)" \
    "$(lipo -info $f 2>/dev/null | grep -oE 'arm64|x86_64')"
done