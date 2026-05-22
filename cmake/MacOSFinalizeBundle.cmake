# Finalize the macOS .app bundle so it launches on Apple Silicon:
#   1. Restore the standard symlink layout for SDL2.framework (BundleUtilities
#      copies it as plain directories, which breaks `codesign --deep`).
#   2. Run macdeployqt so the Qt platform plugin (libqcocoa.dylib) and Qt
#      frameworks are present in the bundle.
#   3. Re-apply an ad-hoc code signature; install_name_tool invocations during
#      bundle fixup invalidate the existing signatures, and macOS arm64
#      refuses to launch unsigned binaries.
#
# Invoke via `cmake -P MacOSFinalizeBundle.cmake -DAPP_BUNDLE=<path> -DMACDEPLOYQT=<path>`.

if(NOT APP_BUNDLE)
    message(FATAL_ERROR "MacOSFinalizeBundle: APP_BUNDLE not set")
endif()

# SDL2.framework is placed under Contents/MacOS/Frameworks by the build
# (set_source_files_properties uses MACOSX_PACKAGE_LOCATION = MacOS/...).
# Look in both locations to stay forward-compatible if that ever changes.
set(_sdl_candidates
    "${APP_BUNDLE}/Contents/MacOS/Frameworks/SDL2.framework"
    "${APP_BUNDLE}/Contents/Frameworks/SDL2.framework")
set(_sdl_fw "")
foreach(_candidate IN LISTS _sdl_candidates)
    if(EXISTS "${_candidate}")
        set(_sdl_fw "${_candidate}")
        break()
    endif()
endforeach()
if(_sdl_fw)
    set(_versions "${_sdl_fw}/Versions")
    if(EXISTS "${_versions}/Current" AND NOT IS_SYMLINK "${_versions}/Current")
        file(REMOVE_RECURSE "${_versions}/Current")
    endif()
    foreach(_entry Headers Resources SDL2)
        if(EXISTS "${_sdl_fw}/${_entry}" AND NOT IS_SYMLINK "${_sdl_fw}/${_entry}")
            file(REMOVE_RECURSE "${_sdl_fw}/${_entry}")
        endif()
    endforeach()
    if(NOT EXISTS "${_versions}/Current")
        execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink "A" "${_versions}/Current")
    endif()
    if(NOT EXISTS "${_sdl_fw}/Headers")
        execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink "Versions/Current/Headers" "${_sdl_fw}/Headers")
    endif()
    if(NOT EXISTS "${_sdl_fw}/Resources")
        execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink "Versions/Current/Resources" "${_sdl_fw}/Resources")
    endif()
    if(NOT EXISTS "${_sdl_fw}/SDL2")
        execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink "Versions/Current/SDL2" "${_sdl_fw}/SDL2")
    endif()
endif()

if(MACDEPLOYQT AND EXISTS "${MACDEPLOYQT}")
    # macdeployqt prints "ERROR: Could not parse otool output" for non-binary
    # files in Contents/MacOS (e.g. panic.json); those messages are harmless.
    execute_process(COMMAND "${MACDEPLOYQT}" "${APP_BUNDLE}" -verbose=0
                    RESULT_VARIABLE _deploy_rc)
    if(NOT _deploy_rc EQUAL 0)
        message(WARNING "macdeployqt returned ${_deploy_rc} (non-fatal); continuing")
    endif()
endif()

# Ad-hoc re-sign everything. --deep is required so the embedded Qt frameworks
# and helper dylibs that install_name_tool rewrote also get a fresh signature.
execute_process(COMMAND codesign --force --deep --sign - "${APP_BUNDLE}"
                RESULT_VARIABLE _sign_rc)
if(NOT _sign_rc EQUAL 0)
    message(FATAL_ERROR "codesign --sign - ${APP_BUNDLE} failed (rc=${_sign_rc})")
endif()
