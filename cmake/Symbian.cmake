# Add a Symbian project for building in release mode
function(add_symbian_project FOLDER)
    add_custom_target(${FOLDER})

	if (EKA2L1_BUILD_PATCH)
		if (EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${FOLDER}/CMakeLists.txt")
			if (NOT EKA2L1_SYMBIAN_SDK_PREFIX)
				message(FATAL_ERROR "${FOLDER} requires EKA2L1_SYMBIAN_SDK_PREFIX (symbian-platform SDK)")
			endif()
			add_custom_command(TARGET ${FOLDER}
				COMMAND "${EKA2L1_SYMBIAN_SDK_PREFIX}/bin/cmake" -S "${CMAKE_CURRENT_SOURCE_DIR}/${FOLDER}"
					-B "${CMAKE_CURRENT_BINARY_DIR}/${FOLDER}-native" -G Ninja
					"-DCMAKE_TOOLCHAIN_FILE=${EKA2L1_SYMBIAN_SDK_PREFIX}/cmake/symbian-arm.cmake"
					"-DSYMBIAN_SDK_PREFIX=${EKA2L1_SYMBIAN_SDK_PREFIX}"
					"-DCMAKE_MAKE_PROGRAM=${EKA2L1_SYMBIAN_SDK_PREFIX}/bin/ninja" -DCMAKE_BUILD_TYPE=Release
				COMMAND "${EKA2L1_SYMBIAN_SDK_PREFIX}/bin/cmake" --build "${CMAKE_CURRENT_BINARY_DIR}/${FOLDER}-native"
				COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_BINARY_DIR}/${FOLDER}-native/${FOLDER}_general.dll"
					"${CMAKE_CURRENT_SOURCE_DIR}/${FOLDER}/group/${FOLDER}_general.dll" VERBATIM)
		else()
		add_custom_command(
			TARGET ${FOLDER}
			COMMAND python ${CMAKE_CURRENT_SOURCE_DIR}/patch_build.py ${CMAKE_CURRENT_SOURCE_DIR}/${FOLDER}/group)
		endif()
	endif()

	get_property(LAST_TARGET GLOBAL PROPERTY LAST_SYMBIAN_PROJECT_TARGET)

	if (LAST_TARGET)
		add_dependencies(${FOLDER} ${LAST_TARGET})
	endif()

	set_property(GLOBAL PROPERTY LAST_SYMBIAN_PROJECT_TARGET "${FOLDER}")
endfunction()

function(add_symbian_patch NAME)
    add_symbian_project(${NAME})

    set_target_properties(${NAME} PROPERTIES OUTPUT_NAME ${NAME}
	    ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin/patch"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin/patch")

    add_custom_command(
	    TARGET ${NAME}
        POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/${NAME}/group" "${CMAKE_BINARY_DIR}/bin/patch/")
endfunction()
