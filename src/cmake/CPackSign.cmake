# Authenticode signing for Windows packages, run by CPack.
#
# Registered as both CPACK_PRE_BUILD_SCRIPTS and CPACK_POST_BUILD_SCRIPTS:
#  - pre-build:  signs the binaries in CPack's staging folder, so the ZIP or
#                installer is built from signed files;
#  - post-build: signs the generated installer .exe (NSIS), if any.
#
# Signing is enabled by setting the certificate's SHA-1 thumbprint, either at
# configure time (-DSPEEDCRUNCH_SIGN_CERT_SHA1=...) or in the environment when
# running cpack (SPEEDCRUNCH_SIGN_CERT_SHA1). Without it, nothing is signed.
#
# Files that already carry a valid signature (e.g. official Qt DLLs signed by
# The Qt Company, or the Microsoft runtime) are kept as they are; the
# application executable is always (re)signed.
#
# Optional environment overrides: SIGNTOOL, SPEEDCRUNCH_SIGN_TIMESTAMP_URL,
# SPEEDCRUNCH_SIGN_ALLOW_SELF_SIGNED=1 (for local tests with a test cert).

set(sc_thumb "${CPACK_SPEEDCRUNCH_SIGN_CERT_SHA1}")
if(NOT sc_thumb)
    set(sc_thumb "$ENV{SPEEDCRUNCH_SIGN_CERT_SHA1}")
endif()
string(REPLACE " " "" sc_thumb "${sc_thumb}")
if(NOT sc_thumb)
    if(NOT DEFINED CPACK_PACKAGE_FILES)
        message(STATUS "Signing: SPEEDCRUNCH_SIGN_CERT_SHA1 is not set, the package will be unsigned")
    endif()
    return()
endif()

set(sc_signtool "$ENV{SIGNTOOL}")
if(NOT sc_signtool)
    set(sc_signtool "${CPACK_SPEEDCRUNCH_SIGNTOOL}")
endif()
if(NOT sc_signtool OR NOT EXISTS "${sc_signtool}")
    message(FATAL_ERROR "Signing: signtool.exe not found; install the Windows SDK or set SIGNTOOL")
endif()

set(sc_timestamp_url "$ENV{SPEEDCRUNCH_SIGN_TIMESTAMP_URL}")
if(NOT sc_timestamp_url)
    set(sc_timestamp_url "${CPACK_SPEEDCRUNCH_SIGN_TIMESTAMP_URL}")
endif()

# Sets <out_signer> to the leaf certificate subject of a validly signed file
# (empty if not validly signed) and <out_depth> to its chain length.
function(sc_signer_of file out_signer out_depth)
    execute_process(COMMAND "${sc_signtool}" verify /pa /v "${file}"
        RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_QUIET)
    set(signer "")
    set(depth 0)
    if(rc EQUAL 0)
        string(REPLACE "\r" "" out "${out}")
        string(FIND "${out}" "Signing Certificate Chain:" start)
        if(start GREATER -1)
            string(SUBSTRING "${out}" ${start} -1 chain)
            # The timestamp chain follows the signing chain; cut it off.
            string(FIND "${chain}" "The signature is timestamped" end)
            if(end EQUAL -1)
                string(FIND "${chain}" "Successfully verified" end)
            endif()
            if(end GREATER -1)
                string(SUBSTRING "${chain}" 0 ${end} chain)
            endif()
            string(REGEX MATCHALL "Issued to: [^\n]*" issued "${chain}")
            list(LENGTH issued depth)
            if(depth GREATER 0)
                list(GET issued -1 signer)
                string(REGEX REPLACE "^Issued to: " "" signer "${signer}")
                string(STRIP "${signer}" signer)
            endif()
        endif()
    endif()
    set(${out_signer} "${signer}" PARENT_SCOPE)
    set(${out_depth} ${depth} PARENT_SCOPE)
endfunction()

# Signs all <files> in one signtool call (one SimplySign authorisation), then
# verifies each and checks they are signed by a CA-issued certificate.
function(sc_sign_files)
    message(STATUS "Signing ${ARGC} file(s) with certificate ${sc_thumb}...")
    execute_process(COMMAND "${sc_signtool}" sign
            /sha1 "${sc_thumb}" /fd sha256 /tr "${sc_timestamp_url}" /td sha256
            ${ARGN}
        RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
    if(NOT rc EQUAL 0)
        message(FATAL_ERROR "Signing: signtool sign failed (${rc}):\n${out}\n${err}")
    endif()
    foreach(file IN LISTS ARGN)
        sc_signer_of("${file}" signer depth)
        if(NOT signer)
            message(FATAL_ERROR "Signing: verification failed for ${file}")
        endif()
        if(depth LESS 2 AND NOT "$ENV{SPEEDCRUNCH_SIGN_ALLOW_SELF_SIGNED}")
            message(FATAL_ERROR "Signing: ${file} was signed with a self-signed certificate "
                "(\"${signer}\"); check SPEEDCRUNCH_SIGN_CERT_SHA1, or set "
                "SPEEDCRUNCH_SIGN_ALLOW_SELF_SIGNED=1 for local tests")
        endif()
    endforeach()
    set(sc_last_signer "${signer}" PARENT_SCOPE)
endfunction()

if(DEFINED CPACK_PACKAGE_FILES)
    # Post-build: sign generated installers (NSIS .exe). ZIPs need nothing.
    set(sc_installers "")
    foreach(pkg IN LISTS CPACK_PACKAGE_FILES)
        if(pkg MATCHES "\\.[eE][xX][eE]$")
            list(APPEND sc_installers "${pkg}")
        endif()
    endforeach()
    if(sc_installers)
        sc_sign_files(${sc_installers})
        message(STATUS "Signed installer(s) as \"${sc_last_signer}\":")
        foreach(pkg IN LISTS sc_installers)
            message(STATUS "  ${pkg}")
        endforeach()
    endif()
    return()
endif()

# Pre-build: sign the binaries in the staging folder.
set(sc_root "${CPACK_TEMPORARY_DIRECTORY}")
file(GLOB_RECURSE sc_binaries LIST_DIRECTORIES false "${sc_root}/*.exe" "${sc_root}/*.dll")
list(SORT sc_binaries)

set(sc_to_sign "")
set(sc_skipped "")
foreach(file IN LISTS sc_binaries)
    get_filename_component(name "${file}" NAME)
    string(TOLOWER "${name}" name_lower)
    if(NOT name_lower STREQUAL "${CPACK_SPEEDCRUNCH_APP_EXE}")
        sc_signer_of("${file}" signer depth)
        if(signer)
            list(APPEND sc_skipped "${file}|${signer}")
            continue()
        endif()
    endif()
    list(APPEND sc_to_sign "${file}")
endforeach()

if(NOT sc_to_sign)
    message(FATAL_ERROR "Signing: no binaries to sign in ${sc_root}")
endif()
sc_sign_files(${sc_to_sign})

list(LENGTH sc_to_sign sc_signed_count)
list(LENGTH sc_skipped sc_skipped_count)
message(STATUS "================ Signing report ================")
message(STATUS "Signed as \"${sc_last_signer}\" (${sc_signed_count}):")
foreach(file IN LISTS sc_to_sign)
    file(RELATIVE_PATH rel "${sc_root}" "${file}")
    message(STATUS "  ${rel}")
endforeach()
message(STATUS "Skipped (${sc_skipped_count}):")
foreach(entry IN LISTS sc_skipped)
    string(REPLACE "|" ";" parts "${entry}")
    list(GET parts 0 file)
    list(GET parts 1 signer)
    file(RELATIVE_PATH rel "${sc_root}" "${file}")
    message(STATUS "  ${rel}  (already validly signed by \"${signer}\")")
endforeach()
message(STATUS "================================================")
