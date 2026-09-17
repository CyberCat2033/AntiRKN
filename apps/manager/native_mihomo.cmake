find_package(Python3 COMPONENTS Interpreter REQUIRED)
get_filename_component(ANTIRKN_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(MIHOMO_NAME "antirkn-mihomo")
if(ANTIRKN_MIHOMO_TARGET STREQUAL "windows")
  string(APPEND MIHOMO_NAME ".exe")
endif()
set(MIHOMO_BINARY "${CMAKE_BINARY_DIR}/mihomo/${MIHOMO_NAME}")
add_custom_target(mihomo_core ALL
  COMMAND "${Python3_EXECUTABLE}" "${ANTIRKN_ROOT}/tool/build_mihomo.py"
    --target ${ANTIRKN_MIHOMO_TARGET} --output "${MIHOMO_BINARY}"
  BYPRODUCTS "${MIHOMO_BINARY}"
  VERBATIM)
add_dependencies(${BINARY_NAME} mihomo_core)
install(PROGRAMS "${MIHOMO_BINARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
install(DIRECTORY "${CMAKE_BINARY_DIR}/mihomo/notices" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/mihomo" COMPONENT Runtime)
