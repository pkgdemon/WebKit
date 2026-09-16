# Copyright (C) 2026 Gershwin contributors
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ``AS IS''
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

#[=======================================================================[.rst:
FindGNUstep
-----------

Finds the GNUstep Objective-C frameworks (Foundation and AppKit) by asking
``gnustep-config``, which is the canonical way to query a GNUstep installation.

Imported Targets
^^^^^^^^^^^^^^^^

``GNUstep::Base``
  The GNUstep Foundation implementation (``libgnustep-base``).
``GNUstep::GUI``
  The GNUstep AppKit implementation (``libgnustep-gui``). Links Base.

Result Variables
^^^^^^^^^^^^^^^^

``GNUstep_FOUND``
``GNUstep_OBJC_FLAGS``
  Compile flags required for Objective-C/Objective-C++, including the
  ``-fobjc-runtime=`` selector and ``-fblocks``.
``GNUstep_MAKEFILES``
  Path to the gnustep-make makefiles directory.
#]=======================================================================]

find_program(GNUSTEP_CONFIG_EXECUTABLE NAMES gnustep-config)

if (GNUSTEP_CONFIG_EXECUTABLE)
    execute_process(
        COMMAND ${GNUSTEP_CONFIG_EXECUTABLE} --objc-flags
        OUTPUT_VARIABLE GNUstep_OBJC_FLAGS
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    execute_process(
        COMMAND ${GNUSTEP_CONFIG_EXECUTABLE} --gui-libs
        OUTPUT_VARIABLE GNUstep_GUI_LIBS
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    execute_process(
        COMMAND ${GNUSTEP_CONFIG_EXECUTABLE} --base-libs
        OUTPUT_VARIABLE GNUstep_BASE_LIBS
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    execute_process(
        COMMAND ${GNUSTEP_CONFIG_EXECUTABLE} --variable=GNUSTEP_MAKEFILES
        OUTPUT_VARIABLE GNUstep_MAKEFILES
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    execute_process(
        COMMAND ${GNUSTEP_CONFIG_EXECUTABLE} --variable=GNUSTEP_SYSTEM_HEADERS
        OUTPUT_VARIABLE GNUstep_INCLUDE_DIR
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )

    separate_arguments(GNUstep_OBJC_FLAGS NATIVE_COMMAND "${GNUstep_OBJC_FLAGS}")
    separate_arguments(GNUstep_GUI_LIBS NATIVE_COMMAND "${GNUstep_GUI_LIBS}")
    separate_arguments(GNUstep_BASE_LIBS NATIVE_COMMAND "${GNUstep_BASE_LIBS}")

    # gnustep-config emits build tuning (-g -O2 -MMD -MP) that must not leak into
    # WebKit's own flags; keep only what is semantically required to compile
    # Objective-C against this runtime.
    set(_gnustep_kept_flags)
    foreach (_flag IN LISTS GNUstep_OBJC_FLAGS)
        if (_flag MATCHES "^(-D|-I|-fobjc-runtime=|-fblocks|-fconstant-string-class=|-fno-strict-aliasing|-pthread)")
            list(APPEND _gnustep_kept_flags "${_flag}")
        endif ()
    endforeach ()
    set(GNUstep_OBJC_FLAGS ${_gnustep_kept_flags})
endif ()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(GNUstep
    REQUIRED_VARS GNUSTEP_CONFIG_EXECUTABLE GNUstep_OBJC_FLAGS GNUstep_GUI_LIBS
    REASON_FAILURE_MESSAGE "gnustep-config was not found - install gnustep-make and source GNUstep.sh"
)

if (GNUstep_FOUND AND NOT TARGET GNUstep::Base)
    add_library(GNUstep::Base INTERFACE IMPORTED GLOBAL)
    set_target_properties(GNUstep::Base PROPERTIES
        INTERFACE_COMPILE_OPTIONS "${GNUstep_OBJC_FLAGS}"
        INTERFACE_LINK_LIBRARIES "${GNUstep_BASE_LIBS}"
    )
endif ()

if (GNUstep_FOUND AND NOT TARGET GNUstep::GUI)
    add_library(GNUstep::GUI INTERFACE IMPORTED GLOBAL)
    set_target_properties(GNUstep::GUI PROPERTIES
        INTERFACE_COMPILE_OPTIONS "${GNUstep_OBJC_FLAGS}"
        INTERFACE_LINK_LIBRARIES "${GNUstep_GUI_LIBS}"
    )
endif ()

mark_as_advanced(GNUSTEP_CONFIG_EXECUTABLE)
