if(NOT MONOLIBTIC)
    set(CMAKE_PATCH_FILE ${CMAKE_BINARY_DIR}/k2pdfopt_exports.cmake)
    target_exports(k2pdfopt FILELIST_VAR CDECLS_FILES WRITE_TO_FILE ${CMAKE_PATCH_FILE} CDECLS koptcontext_cdecl)
    list(APPEND PATCH_CMD COMMAND ${ISED} "\$p" -e "\$s|.*|include(${CMAKE_PATCH_FILE})|" lib/CMakeLists.txt)
endif()

if(IOS)
    # iOS marks system() as unavailable; even taking its address fails to
    # compile. The willuslib helpers that call it are CLI/GUI utilities
    # not reached from KOReader's FFI bindings, so rewrite `system(arg)`
    # to `(0)` at patch time. Both call shapes survive: bare `system(x);`
    # becomes `(0);`, `status=system(x);` becomes `status=(0);`.
    foreach(_F filelist.c wfile.c wgs.c wgui.c win.c wsys.c wzfile.c)
        list(APPEND PATCH_CMD COMMAND ${ISED}
            "s|system(\\([^)]*\\))|(0)|g"
            willuslib/${_F})
    endforeach()
endif()

list(APPEND CMAKE_ARGS
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
    -DBUILD_SHARED_LIBS=$<NOT:$<BOOL:${MONOLIBTIC}>>
    # Project options.
    -DANDROID=${ANDROID}
    -DLEPTONICA_PATCH=FALSE
)

list(APPEND BUILD_CMD COMMAND ninja)

list(APPEND INSTALL_CMD COMMAND ${CMAKE_COMMAND} --install .)

if(NOT MONOLIBTIC)
    append_shared_lib_install_commands(INSTALL_CMD k2pdfopt VERSION 2)
endif()

external_project(
    DOWNLOAD GIT 64aa9ccfcd55921c596458cb8a7197339d5f32c3
    https://github.com/koreader/libk2pdfopt.git
    PATCH_COMMAND ${PATCH_CMD}
    CMAKE_ARGS ${CMAKE_ARGS}
    SOURCE_SUBDIR lib
    BUILD_COMMAND ${BUILD_CMD}
    BUILD_DEPENDS ${CDECLS_FILES}
    INSTALL_COMMAND ${INSTALL_CMD}
)
