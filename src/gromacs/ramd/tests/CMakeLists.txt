#
# This file is part of the GROMACS molecular simulation package.
#
# Copyright 2016- The GROMACS Authors
# and the project initiators Erik Lindahl, Berk Hess and David van der Spoel.
# Consult the AUTHORS/COPYING files and https://www.gromacs.org for details.
#
# GROMACS is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public License
# as published by the Free Software Foundation; either version 2.1
# of the License, or (at your option) any later version.
#
# GROMACS is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with GROMACS; if not, see
# https://www.gnu.org/licenses, or write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA.
#
# If you want to redistribute modifications to GROMACS, please
# consider that scientific software is very special. Version
# control is crucial - bugs must be traceable. We will be happy to
# consider code for inclusion in the official distribution, but
# derived work must not be called official GROMACS. Details are found
# in the README & COPYING files - if they are missing, get the
# official version at https://www.gromacs.org.
#
# To help us fund GROMACS development, we humbly ask that you cite
# the research papers on the package. Check out https://www.gromacs.org.

gmx_add_unit_test(RAMDTest ramd-test
    CPP_SOURCE_FILES
    ramd.cpp
    randomsphericaldirectiongenerator.cpp
)

# Source files have the following dependencies on library infrastructure.
target_link_libraries(ramd-test PRIVATE
    math
    ramd
)

# ----------------------------------------------------------------------------
# Shell-based functional test suites driving the built gmx binary.
#
# The CPU suite is registered by default so it runs as part of "make test" /
# ctest. The GPU suite is opt-in because it needs a usable GPU.
# ----------------------------------------------------------------------------
option(GMX_BUILD_RAMD_SHELL_TESTS
       "Register the RAMD CPU shell functional test suite with CTest" ON)
option(GMX_BUILD_RAMD_SHELL_GPU_TESTS
       "Register the RAMD GPU shell functional test suite with CTest" OFF)

if (GMX_BUILD_RAMD_SHELL_TESTS OR GMX_BUILD_RAMD_SHELL_GPU_TESTS)
    find_program(BASH_EXECUTABLE bash)
    if (NOT BASH_EXECUTABLE)
        message(WARNING "bash not found: RAMD shell test suites will not be registered")
    else()
        # The build tree has no runnable GMXRC pointing at the build, so point
        # the data lookup at the source tree instead.
        set(_ramd_shell_env
            "GMXDATA=${CMAKE_SOURCE_DIR}/share"
            "GMXLIB=${CMAKE_SOURCE_DIR}/share/top")

        if (GMX_BUILD_RAMD_SHELL_TESTS)
            add_test(NAME RamdShellTestsCpu
                     COMMAND ${CMAKE_COMMAND} -E env ${_ramd_shell_env}
                             "${BASH_EXECUTABLE}"
                             "${CMAKE_SOURCE_DIR}/ramd-tests/run_ramd_tests.sh"
                             --gmx "$<TARGET_FILE:gmx>"
                             --src "${CMAKE_SOURCE_DIR}"
                             --quick)
            set_tests_properties(RamdShellTestsCpu PROPERTIES
                                 LABELS "ramd;shell"
                                 TIMEOUT 3600)
        endif()

        if (GMX_BUILD_RAMD_SHELL_GPU_TESTS)
            add_test(NAME RamdShellTestsGpu
                     COMMAND ${CMAKE_COMMAND} -E env ${_ramd_shell_env}
                             "${BASH_EXECUTABLE}"
                             "${CMAKE_SOURCE_DIR}/ramd-tests/run_ramd_gpu_tests.sh"
                             --gmx "$<TARGET_FILE:gmx>"
                             --src "${CMAKE_SOURCE_DIR}")
            set_tests_properties(RamdShellTestsGpu PROPERTIES
                                 LABELS "ramd;shell;gpu"
                                 TIMEOUT 3600)
        endif()
    endif()
endif()
