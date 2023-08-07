// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "sw/ip/csrng/driver/csrng.h"
#include "sw/ip/edn/driver/edn.h"
#include "sw/ip/entropy_src/driver/entropy_src.h"
#include "sw/ip/flash_ctrl/driver/flash_ctrl.h"
#include "sw/ip/keymgr/driver/keymgr.h"
#include "sw/ip/kmac/driver/kmac.h"
#include "sw/ip/otp_ctrl/driver/otp_ctrl.h"
#include "sw/ip/rstmgr/driver/rstmgr.h"
#include "sw/ip/usbdev/driver/usbdev.h"

#include "hw/top_earlgrey/sw/autogen/top_earlgrey.h"

/**
 * @file
 * @brief Device-specific driver definitions
 */

const uint32_t kCsrngBaseAddr[] = {
    TOP_EARLGREY_CSRNG_BASE_ADDR
};

const uint32_t kEdnBaseAddr[] = {
    TOP_EARLGREY_EDN0_BASE_ADDR,
    TOP_EARLGREY_EDN1_BASE_ADDR
};

const uint32_t kEntropySrcBaseAddr[] = {
    TOP_EARLGREY_ENTROPY_SRC_BASE_ADDR
};

const uint32_t kFlashCtrlCoreBaseAddr[] = {
    TOP_EARLGREY_FLASH_CTRL_CORE_BASE_ADDR
};

const uint32_t kFlashCtrlMemBaseAddr[] = {
    TOP_EARLGREY_FLASH_CTRL_MEM_BASE_ADDR
};

const uint32_t kKeymgrBaseAddr[] = {
    TOP_EARLGREY_KEYMGR_BASE_ADDR
};

const uint32_t kKmacBaseAddr[] = {
    TOP_EARLGREY_KMAC_BASE_ADDR
};

const uint32_t kOtpCtrlCoreBaseAddr[] = {
    TOP_EARLGREY_OTP_CTRL_CORE_BASE_ADDR
};

const uint32_t kRstmgrAonBaseAddr[] = {
    TOP_EARLGREY_RSTMGR_AON_BASE_ADDR
};

const uint32_t kUsbdevBaseAddr[] = {
    TOP_EARLGREY_USBDEV_BASE_ADDR
};
