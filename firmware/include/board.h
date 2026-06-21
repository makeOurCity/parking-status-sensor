#pragma once

#if defined(BOARD_XIAO)
#include "board_xiao.h"
#elif defined(BOARD_DEVKIT)
#include "board_devkit.h"
#else
#error "Define BOARD_XIAO or BOARD_DEVKIT in platformio.ini build_flags"
#endif
