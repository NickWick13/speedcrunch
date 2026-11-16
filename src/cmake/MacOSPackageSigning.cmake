if(CMAKE_VERSION VERSION_LESS 3.19)
    if(NOT "$ENV{SPEEDCRUNCH_MACOS_SIGN_IDENTITY}" STREQUAL "")
        message(FATAL_ERROR "macOS package signing requires CMake 3.19 or later")
    endif()
    return()
endif()

# Read the identity when CPack runs, so changing the environment does not
# require clearing cached signing settings or reconfiguring the build.
foreach(helper IN ITEMS MacOSSigning.cmake CPackMacOSSign.cmake)
    configure_file("${CMAKE_CURRENT_LIST_DIR}/${helper}"
        "${CMAKE_CURRENT_BINARY_DIR}/${helper}" COPYONLY)
endforeach()
set(CPACK_SPEEDCRUNCH_MACOS_APP_BUNDLE "${APPLICATION_NAME}.app")
list(APPEND CPACK_PRE_BUILD_SCRIPTS "${CMAKE_CURRENT_BINARY_DIR}/CPackMacOSSign.cmake")
list(APPEND CPACK_POST_BUILD_SCRIPTS "${CMAKE_CURRENT_BINARY_DIR}/CPackMacOSSign.cmake")

if(BUILD_TESTING)
    add_test(NAME macos-signing-helpers
        COMMAND "${CMAKE_COMMAND}"
            -S "${CMAKE_CURRENT_LIST_DIR}/../tests/cmake/macossigning"
            -B "${CMAKE_CURRENT_BINARY_DIR}/tests/macossigning")
    foreach(variant IN ITEMS DEFAULT OFFICIAL_RELEASE OFFICIAL_PORTABLE_RELEASE)
        add_test(NAME macos-packaging-defaults-${variant}
            COMMAND "${CMAKE_COMMAND}"
                -S "${CMAKE_CURRENT_LIST_DIR}/../tests/cmake/macospackagingdefaults"
                -B "${CMAKE_CURRENT_BINARY_DIR}/tests/macospackagingdefaults/${variant}"
                "-DTEST_VARIANT=${variant}")
    endforeach()
    foreach(phase IN ITEMS UNSET_PRE UNSET_POST EMPTY SOURCE ZIP_POST MISSING_APP)
        add_test(NAME macos-signing-hook-${phase}
            COMMAND "${CMAKE_COMMAND}"
                -S "${CMAKE_CURRENT_LIST_DIR}/../tests/cmake/macossigninghook"
                -B "${CMAKE_CURRENT_BINARY_DIR}/tests/macossigninghook/${phase}"
                "-DTEST_PHASE=${phase}")
    endforeach()
    set_tests_properties(macos-signing-hook-MISSING_APP PROPERTIES WILL_FAIL TRUE)
endif()
