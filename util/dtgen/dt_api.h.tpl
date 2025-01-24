// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Device table API auto-generated by `dtgen`
<%
from topgen.lib import Name, is_top_reggen, is_ipgen

top = helper.top

top_name = Name(["top", top["name"]])

include_guard = "OPENTITAN_TOP_{}_DT_API_H_".format(top["name"].upper())
%>\

#ifndef ${include_guard}
#define ${include_guard}

#include <stddef.h>
#include <stdint.h>
#include "${top_lib_header}"

/**
 * List of device types.
 *
 * Device types are guaranteed to be numbered consecutively from 0.
 */
${helper.device_type_enum.render()}

/**
 * List of instance IDs.
 *
 * Instance IDs are guaranteed to be numbered consecutively from 0.
 */
${helper.instance_id_enum.render()}

/**
 * Get the instance type of a device instance.
 *
 * For example the instance type of `kDtUart0` is `kDtInstanceTypeUart`.
 *
 * @param id An instance ID.
 * @return The instance type, or `kDtInstanceIdUnknown` if the ID is not valid.
 */
dt_device_type_t dt_device_type(dt_instance_id_t id);

/**
 * Get the instance number of a device instance.
 *
 * If a top has several instances of the same type, this will return the
 * instance number. This function guarantees that the instance
 * number can be used to index into the corresponding devicetable.
 *
 * For example, if the instance index of `kDtUart3` is 3 then it is guaranteed
 * then that `kDtUart[3] == kDtUart3`.
 *
 * @param dev An instance ID.
 * @return The instance number, or 0 if the ID is not valid.
 */
size_t dt_instance_index(dt_instance_id_t dev);

/** PLIC IRQ ID type.
 *
 * This type represents a raw IRQ ID from the PLIC.
 *
 * This is an alias to the top's `plic_irq_id_t` type for backward compatibility
 * with existing code.
 */
typedef ${top_name.as_snake_case()}_plic_irq_id_t dt_plic_irq_id_t;

/** PLIC IRQ ID for no interrupt. */
static const dt_plic_irq_id_t kDtPlicIrqIdNone=${top_name.as_c_enum()}PlicIrqIdNone;

/**
 * Get the instance ID for a given PLIC IRQ ID.
 *
 * For example, on earlgrey, the instance ID of `kTopEarlgreyPlicIrqIdUart0TxWatermark`
 * is `kDtInstanceIdUart0`. One can then use the type specific function to retrieve the
 * IRQ name, for example `dt_uart_irq_from_plic_id` for the UART.
 *
 * @param dev A PLIC ID.
 * @return The instance ID, or `kDtInstanceIdUnknown` if the PLIC ID is not valid.
 */
dt_instance_id_t dt_plic_id_to_instance_id(dt_plic_irq_id_t irq);

/**
 * List of clocks.
 *
 * Clocks are guaranteed to be numbered consecutively from 0.
 */
${helper.clock_enum.render()}

/**
 * Get the frequency of a clock.
 *
 * @param dev A clock ID.
 * @return Clock frequency in Hz.
 */
uint32_t dt_clock_frequency(dt_clock_t clk);

/**
 * Pinmux types.
 *
 * These types are aliases to top-level types for backward compatibility
 * with existing code.
 */
typedef ${top_name.as_snake_case()}_pinmux_peripheral_in_t dt_pinmux_peripheral_in_t;
typedef ${top_name.as_snake_case()}_pinmux_insel_t dt_pinmux_insel_t;
typedef ${top_name.as_snake_case()}_pinmux_outsel_t dt_pinmux_outsel_t;
typedef ${top_name.as_snake_case()}_pinmux_mio_out_t dt_pinmux_mio_out_t;
typedef ${top_name.as_snake_case()}_direct_pads_t dt_pinmux_direct_pad_t;
typedef ${top_name.as_snake_case()}_muxed_pads_t  dt_pinmux_muxed_pad_t;

/** Type of peripheral I/O. */
typedef enum dt_periph_io_type {
  /* This peripheral I/O is connected to a muxed IO (MIO). */
  kDtPeriphIoTypeMio,
  /* This peripheral I/O is connected to a direct IO (DIO). */
  kDtPeriphIoTypeDio,
  /* This peripheral I/O is not connected to either a MIO or a DIO. */
  kDtPeriphIoTypeUnspecified,
} dt_periph_io_type_t;


/** Direction of a peripheral I/O. */
typedef enum dt_periph_io_dir {
  /* This peripheral I/O is an input. */
  kDtPeriphIoDirIn,
  /* This peripheral I/O is an output */
  kDtPeriphIoDirOut,
  /* This peripheral I/O is an input-output */
  kDtPeriphIoDirInout,
} dt_periph_io_dir_t;

/** Peripheral I/O description.
 *
 * A `dt_periph_io_t` represents a HW IP block peripheral I/O, which can be an input, output or both.
 * Importantly, this only represents how the block peripheral I/O is wired, i.e.
 * whether it is connected a MIO or a direct IO on the pinmux, and the relevant information necessary to
 * configure it.
 *
 * NOTE The fields of this structure are internal, use the dt_periph_io_* functions to access them.
 */
typedef struct dt_periph_io {
  struct {
    /** Peripheral I/O type */
    dt_periph_io_type_t type;
    /** Peripheral I/O direction. */
    dt_periph_io_dir_t dir;
    /** For `kDtPeriphIoTypeMio`: peripheral input number. This is the index of the MIO_PERIPH_INSEL register
     * that controls this peripheral I/O.
     *
     * For `kDtPeriphIoTypeDio`: DIO pad number. This is the index of the various DIO_PAD_* registers
     * that control this peripheral I/O.
     */
    uint16_t periph_input_or_direct_pad;
    /** For `kDtPeriphIoTypeMio`: peripheral output number. This is the value to put in the MIO_OUTSEL registers
     * to connect an output to this peripheral I/O.
     */
    uint16_t outsel;
  } __internal;
} dt_periph_io_t;

/** Tie constantly to zero. */
static const dt_pinmux_outsel_t kDtPinmuxOutselConstantZero = k${top_name.as_camel_case()}PinmuxOutselConstantZero;

/** Tie constantly to one. */
static const dt_pinmux_outsel_t kDtPinmuxOutselConstantOne = k${top_name.as_camel_case()}PinmuxOutselConstantOne;

/** Tie constantly to high-Z. */
static const dt_pinmux_outsel_t kDtPinmuxOutselConstantHighZ = k${top_name.as_camel_case()}PinmuxOutselConstantHighZ;

/* Peripheral I/O that is constantly tied to high-Z (output only) */
extern const dt_periph_io_t kDtPeriphIoConstantHighZ;

/* Peripheral I/O that is constantly tied to one (output only) */
extern const dt_periph_io_t kDtPeriphIoConstantZero;

/* Peripheral I/O that is constantly tied to zero (output only) */
extern const dt_periph_io_t kDtPeriphIoConstantOne;

/**
 * Return the type of a `dt_periph_io_t`.
 *
 * @param dev A peripheral I/O description.
 * @return The peripheral I/O type (MIO, DIO, etc).
 */
static inline dt_periph_io_type_t dt_periph_io_type(dt_periph_io_t periph_io) {
  return periph_io.__internal.type;
}

/**
 * Return the direction of a `dt_periph_io_t`.
 *
 * @param dev A peripheral I/O description.
 * @return The peripheral I/O direction.
 */
static inline dt_periph_io_dir_t dt_periph_io_dir(dt_periph_io_t periph_io) {
  return periph_io.__internal.dir;
}

/**
 * Return the peripheral input for an MIO peripheral I/O.
 *
 * This is the index of the MIO_PERIPH_INSEL register that controls this peripheral I/O.
 *
 * @param dev A peripheral I/O of type `kDtPeriphIoTypeMio`.
 * @return The peripheral input number of the MIO that this peripheral I/O is connected to.
 *
 * NOTE This function only makes sense for peripheral I/Os of type `kDtPeriphIoTypeMio` which are
 * inputs (`kDtPeriphIoDirIn`). For any other peripheral I/O, the return value is unspecified.
 */
static inline dt_pinmux_peripheral_in_t dt_periph_io_mio_periph_input(dt_periph_io_t periph_io) {
  return (dt_pinmux_peripheral_in_t)periph_io.__internal.periph_input_or_direct_pad;
}

/**
 * Return the outsel for an MIO peripheral I/O.
 *
 * This is the value to put in the `MIO_OUTSEL` registers to connect a pad to this peripheral I/O.
 *
 * @param dev A peripheral I/O of type `kDtPeriphIoTypeMio`.
 * @return The outsel of the MIO that this peripheral I/O is connected to.
 *
 * NOTE This function only makes sense for peripheral I/Os of type `kDtPeriphIoTypeMio` which are
 * outputs (`kDtPeriphIoDirOut`). For any other peripheral I/O, the return value is unspecified.
 */
static inline dt_pinmux_outsel_t dt_periph_io_mio_outsel(dt_periph_io_t periph_io) {
  return (dt_pinmux_outsel_t)periph_io.__internal.outsel;
}

/**
 * Return the direct pad number of a DIO peripheral I/O.
 *
 * This is the index of the various `DIO_PAD_*` registers that control this peripheral I/O.
 *
 * @param dev A peripheral I/O of type `kDtPeriphIoTypeDio`.
 * @return The direct pad number of the DIO that this peripheral I/O is connected to.
 *
 * NOTE This function only makes sense for peripheral I/Os of type `kDtPeriphIoTypeDio` which are
 * either outputs or inouts. For any other peripheral I/O type, the return value is unspecified.
 */
static inline dt_pinmux_direct_pad_t dt_periph_io_dio_pad(dt_periph_io_t periph_io) {
  return (dt_pinmux_direct_pad_t)periph_io.__internal.periph_input_or_direct_pad;
}

/**
 * List of pads names.
 */
${helper.pad_enum.render()}

/** Type of a pad. */
typedef enum dt_pad_type {
  /* This pad is a muxed IO (MIO). */
  kDtPadTypeMio,
  /* This pad is a direct IO (DIO). */
  kDtPadTypeDio,
  /* This pad is not an MIO or a DIO. */
  kDtPadTypeUnspecified,
} dt_pad_type_t;

/**
 * Return the type of a `dt_pad_t`.
 *
 * @param dev A pad description.
 * @return The pad type (MIO, DIO, etc).
 */
dt_pad_type_t dt_pad_type(dt_pad_t pad);

/**
 * Return the pad out number for an MIO pad.
 *
 * This is the index of the `MIO_OUT` registers that control this pad
 * (or the output part of this pad).
 *
 * @param dev A pad of type `kDtPadTypeMio`.
 * @return The pad out number of the MIO.
 *
 * NOTE This function only makes sense for pads of type `kDtPadTypeMio` which are
 * either inputs or inouts. For any other pad, the return value is unspecified.
 */
dt_pinmux_mio_out_t dt_pad_mio_out(dt_pad_t pad);

/**
 * Return the pad out number for an MIO pad.
 *
 * This is the index of the `MIO_PAD` registers that control this pad
 * (or the output part of this pad).
 *
 * @param dev A pad of type `kDtPadTypeMio`.
 * @return The pad out number of the MIO.
 *
 * NOTE This function only makes sense for pads of type `kDtPadTypeMio`.
 * For any other pad, the return value is unspecified.
 */
dt_pinmux_muxed_pad_t dt_pad_mio_pad(dt_pad_t pad);

/**
 * Return the insel for an MIO pad.
 *
 * This is the value to put in the `MIO_PERIPH_INSEL` registers to connect a peripheral I/O to this pad.
 *
 * @param dev A pad of type `kDtPadTypeMio`.
 * @return The insel of the MIO that this pad is connected to.
 *
 * NOTE This function only makes sense for pads of type `kDtPadTypeMio`.
 * For any other pad, the return value is unspecified.
 */
dt_pinmux_insel_t dt_pad_mio_insel(dt_pad_t pad);

/**
 * Return the direct pad number of a DIO pad.
 *
 * This is the index of the various `DIO_PAD_*` registers that control this pad.
 *
 * @param dev A pad of type `kDtPadTypeDio`.
 * @return The direct pad number of the DID that this pad is connected to.
 *
 * NOTE This function only makes sense for pads of type `kDtPeriphIoTypeDio` which are
 * either outputs or inouts. For any other pad type, the return value is unspecified.
 */
dt_pinmux_direct_pad_t dt_pad_dio_pad(dt_pad_t pad);

#endif  // ${include_guard}
