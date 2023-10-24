// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

module dma
  import tlul_pkg::*;
  import dma_pkg::*;
  import dma_reg_pkg::*;
#(
    parameter logic [NumAlerts-1:0] AlertAsyncOn         = {NumAlerts{1'b1}},
    parameter bit                   EnableDataIntgGen    = 1'b1,
    parameter logic [RsvdWidth-1:0] TlUserRsvd           = '0,
    parameter logic [SYS_RACL_WIDTH-1:0] SysRacl         = '0,
    parameter int unsigned          OtAgentId            = 0
) (
  input logic                                       clk_i,
  input logic                                       rst_ni,
  input prim_mubi_pkg::mubi4_t                      scanmode_i,
  // DMA interrupts and incoming LSIO triggers
  output  logic                                     intr_dma_done_o,
  output  logic                                     intr_dma_error_o,
  output  logic                                     intr_dma_memory_buffer_limit_o,
  input   lsio_trigger_t                            lsio_trigger_i,
  // Alerts
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx_i,
  output prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx_o,
  // Device port
  input   tlul_pkg::tl_h2d_t                        tl_d_i,
  output  tlul_pkg::tl_d2h_t                        tl_d_o,
  // Facing CTN
  input   tlul_pkg::tl_d2h_t                        ctn_tl_d2h_i,
  output  tlul_pkg::tl_h2d_t                        ctn_tl_h2d_o,
  // Host port
  input   tlul_pkg::tl_d2h_t                        host_tl_h_i,
  output  tlul_pkg::tl_h2d_t                        host_tl_h_o,
  // System port
  input  dma_pkg::sys_rsp_t                         sys_i,
  output dma_pkg::sys_req_t                         sys_o
);
  import prim_mubi_pkg::*;
  import hmac_multimode_pkg::*;

  dma_reg2hw_t reg2hw;
  dma_hw2reg_t hw2reg;

  localparam int unsigned TRANSFER_BYTES_WIDTH    = $bits(reg2hw.total_data_size.q);
  localparam int unsigned INT_CLEAR_SOURCES_WIDTH = $clog2(NumIntClearSources);
  localparam int unsigned NR_SHA_DIGEST_ELEMENTS  = 16;

  // Flopped bus for SYS interface
  dma_pkg::sys_req_t sys_req_d;
  dma_pkg::sys_rsp_t sys_resp_q;

  // Signals for both TL interfaces
  logic                       dma_host_tlul_req_valid,    dma_ctn_tlul_req_valid;
  logic [top_pkg::TL_AW-1:0]  dma_host_tlul_req_addr,     dma_ctn_tlul_req_addr;
  logic                       dma_host_tlul_req_we,       dma_ctn_tlul_req_we;
  logic [top_pkg::TL_DW-1:0]  dma_host_tlul_req_wdata,    dma_ctn_tlul_req_wdata;
  logic [top_pkg::TL_DBW-1:0] dma_host_tlul_req_be,       dma_ctn_tlul_req_be;
  logic                       dma_host_tlul_gnt,          dma_ctn_tlul_gnt;
  logic                       dma_host_tlul_rsp_valid,    dma_ctn_tlul_rsp_valid;
  logic [top_pkg::TL_DW-1:0]  dma_host_tlul_rsp_data,     dma_ctn_tlul_rsp_data;
  logic                       dma_host_tlul_rsp_err,      dma_ctn_tlul_rsp_err;
  logic                       dma_host_tlul_rsp_intg_err, dma_ctn_tlul_rsp_intg_err;

  logic                       dma_host_write, dma_host_read, dma_host_clear_int;
  logic                       dma_ctn_write,  dma_ctn_read,  dma_ctn_clear_int;
  logic                       dma_sys_write,  dma_sys_read;

  logic                       capture_return_data;
  logic [top_pkg::TL_DW-1:0]  read_return_data_q, read_return_data_d;
  logic [SYS_ADDR_WIDTH-1:0]  new_source_addr, new_destination_addr;

  logic dma_state_error;
  dma_ctrl_state_e ctrl_state_q, ctrl_state_d;
  logic clear_go;

  logic [INT_CLEAR_SOURCES_WIDTH-1:0] clear_index_d, clear_index_q;
  logic                               clear_index_en, int_clear_tlul_rsp_valid;
  logic                               int_clear_tlul_gnt;

  logic [DmaErrLast-1:0] next_error;
  logic bad_src_addr;
  logic bad_dst_addr;
  logic bad_opcode;
  logic bad_size;
  logic bad_base_limit;
  logic bad_go_config;
  logic bad_asid;
  logic config_error;

  // Read request grant
  logic read_gnt;
  // Read response
  logic read_rsp_valid;
  // Read error occurred
  //   (Note: in use `read_rsp_error` must be qualified with `read_rsp_valid`)
  logic read_rsp_error;

  // Write request grant
  logic write_gnt;
  // Write response
  logic write_rsp_valid;
  // Write error occurred
  //   (Note: in use `write_rsp_error` must be qualified with `write_rsp_valid`)
  logic write_rsp_error;

  logic cfg_handshake_en;
  logic cfg_fifo_auto_increment_en;
  logic cfg_memory_buffer_auto_increment_en;
  logic cfg_data_direction;
  logic cfg_abort_en;

  logic [SYS_METADATA_WIDTH-1:0] src_metadata;
  assign src_metadata = SYS_METADATA_WIDTH'(1'b1) << OtAgentId;

  // Decode scan mode enable MuBi signal.
  logic scanmode;
  assign scanmode = mubi4_test_true_strict(scanmode_i);

  logic sw_reg_wr, sw_reg_wr1, sw_reg_wr2;
  assign sw_reg_wr = reg2hw.control.go.qe;
  prim_flop #(
    .Width(1)
  ) aff_reg_wr1 (
    .clk_i ( clk_i      ),
    .rst_ni( rst_ni     ),
    .d_i   ( sw_reg_wr  ),
    .q_o   ( sw_reg_wr1 )
  );
  prim_flop #(
    .Width(1)
  ) aff_reg_wr2 (
    .clk_i ( clk_i      ),
    .rst_ni( rst_ni     ),
    .d_i   ( sw_reg_wr1 ),
    .q_o   ( sw_reg_wr2 )
  );

  // Stretch out CR writes to make sure new value can propagate through logic
  logic sw_reg_wr_extended;
  assign sw_reg_wr_extended = sw_reg_wr || sw_reg_wr1 || sw_reg_wr2;

  logic gated_clk_en, gated_clk;
  assign gated_clk_en = reg2hw.control.go.q       ||
                        (ctrl_state_q != DmaIdle) ||
                        sw_reg_wr_extended;

  prim_clock_gating #(
    .FpgaBufGlobal(1'b0) // Instantiate a local instead of a global clock buffer on FPGAs
  ) dma_clk_gate (
    .clk_i    ( clk_i        ),
    .en_i     ( gated_clk_en ),
    .test_en_i( scanmode     ),     ///< Test On to turn off the clock gating during test
    .clk_o    ( gated_clk    )
  );

  logic reg_intg_error;
  // SEC_CM: BUS.INTEGRITY
  // SEC_CM: RANGE.CONFIG.REGWEN_MUBI
  dma_reg_top u_dma_reg (
    .clk_i     ( clk_i          ),
    .rst_ni    ( rst_ni         ),
    .tl_i      ( tl_d_i         ),
    .tl_o      ( tl_d_o         ),
    .reg2hw    ( reg2hw         ),
    .hw2reg    ( hw2reg         ),
    .intg_err_o( reg_intg_error ),
    .devmode_i ( 1'b1           )
  );

  // Alerts
  logic [NumAlerts-1:0] alert_test, alerts;
  assign alert_test = {reg2hw.alert_test.q & reg2hw.alert_test.qe};
  assign alerts[0]  = reg_intg_error              ||
                      dma_host_tlul_rsp_intg_err  ||
                      dma_ctn_tlul_rsp_intg_err   ||
                      dma_state_error;

  for (genvar i = 0; i < NumAlerts; i++) begin : gen_alert_tx
    prim_alert_sender #(
      .AsyncOn(AlertAsyncOn[i]),
      .IsFatal(1'b1)
    ) u_prim_alert_sender (
      .clk_i,
      .rst_ni,
      .alert_test_i (alert_test[i]),
      .alert_req_i  (alerts[i]),
      .alert_ack_o  (),
      .alert_state_o(),
      .alert_rx_i   (alert_rx_i[i]),
      .alert_tx_o   (alert_tx_o[i])
    );
  end

  // Adapter from the DMA to Host
  tlul_adapter_host #(
    .EnableDataIntgGen(EnableDataIntgGen)
  ) u_dma_host_tlul_host (
    .clk_i          ( gated_clk                        ),
    .rst_ni         ( rst_ni                           ),
    // do not make a request unless there is room for the response
    .req_i          ( dma_host_tlul_req_valid          ),
    .gnt_o          ( dma_host_tlul_gnt                ),
    .addr_i         ( dma_host_tlul_req_addr           ),
    .we_i           ( dma_host_tlul_req_we             ),
    .wdata_i        ( dma_host_tlul_req_wdata          ),
    .wdata_intg_i   ( TL_A_USER_DEFAULT.data_intg      ),
    .be_i           ( dma_host_tlul_req_be             ),
    .instr_type_i   ( MuBi4False                       ),
    .user_rsvd_i    ( TlUserRsvd                       ),
    .valid_o        ( dma_host_tlul_rsp_valid          ),
    .rdata_o        ( dma_host_tlul_rsp_data           ),
    .rdata_intg_o   (                                  ),
    .err_o          ( dma_host_tlul_rsp_err            ),
    .intg_err_o     ( dma_host_tlul_rsp_intg_err       ),
    .tl_o           ( host_tl_h_o                      ),
    .tl_i           ( host_tl_h_i                      )
  );

  // Adapter from the DMA to the CTN
  tlul_adapter_host #(
    .EnableDataIntgGen(EnableDataIntgGen)
  ) u_dma_ctn_tlul_host (
    .clk_i          ( gated_clk                        ),
    .rst_ni         ( rst_ni                           ),
    // do not make a request unless there is room for the response
    .req_i          ( dma_ctn_tlul_req_valid           ),
    .gnt_o          ( dma_ctn_tlul_gnt                 ),
    .addr_i         ( dma_ctn_tlul_req_addr            ),
    .we_i           ( dma_ctn_tlul_req_we              ),
    .wdata_i        ( dma_ctn_tlul_req_wdata           ),
    .wdata_intg_i   ( TL_A_USER_DEFAULT.data_intg      ),
    .be_i           ( dma_ctn_tlul_req_be              ),
    .instr_type_i   ( MuBi4False                       ),
    .user_rsvd_i    ( TlUserRsvd                       ),
    .valid_o        ( dma_ctn_tlul_rsp_valid           ),
    .rdata_o        ( dma_ctn_tlul_rsp_data            ),
    .rdata_intg_o   (                                  ),
    .err_o          ( dma_ctn_tlul_rsp_err             ),
    .intg_err_o     ( dma_ctn_tlul_rsp_intg_err        ),
    .tl_o           ( ctn_tl_h2d_o                     ),
    .tl_i           ( ctn_tl_d2h_i                     )
  );

  // Masking incoming handshake triggers with their enable
  lsio_trigger_t lsio_trigger;
  logic          handshake_interrupt;
  always_comb begin
    lsio_trigger = '0;

    for (int i = 0; i < NumIntClearSources; i++) begin
      lsio_trigger[i] = lsio_trigger_i[i] && reg2hw.handshake_interrupt_enable.q[i];
    end
    handshake_interrupt = (|lsio_trigger);
  end

  // Following cast is only temporary until FSM becomes sparesly encoded
  // to avoid conversion errors between dma_ctrl_state_e <-> logic
  logic [$bits(dma_ctrl_state_e)-1:0] ctrl_state_logic;
  assign ctrl_state_q = dma_ctrl_state_e'(ctrl_state_logic);

  prim_flop #(
    .Width($bits(dma_ctrl_state_e)),
    .ResetValue({DmaIdle})
  ) aff_ctrl_state_q (
    .clk_i ( gated_clk        ),
    .rst_ni( rst_ni           ),
    .d_i   ( ctrl_state_d     ),
    .q_o   ( ctrl_state_logic )
  );

  logic [TRANSFER_BYTES_WIDTH-1:0] transfer_byte_q, transfer_byte_d;
  logic [TRANSFER_BYTES_WIDTH-1:0] remaining_bytes;
  logic                            capture_transfer_byte;
  prim_generic_flop_en #(
    .Width(TRANSFER_BYTES_WIDTH)
  ) aff_transfer_byte (
    .clk_i  ( gated_clk             ),
    .rst_ni ( rst_ni                ),
    .en_i   ( capture_transfer_byte ),
    .d_i    ( transfer_byte_d       ),
    .q_o    ( transfer_byte_q       )
  );

  logic [TRANSFER_BYTES_WIDTH-1:0] chunk_byte_q, chunk_byte_d;
  logic                            capture_chunk_byte;
  prim_generic_flop_en #(
    .Width(TRANSFER_BYTES_WIDTH)
  ) aff_chunk_byte (
    .clk_i  ( gated_clk          ),
    .rst_ni ( rst_ni             ),
    .en_i   ( capture_chunk_byte ),
    .d_i    ( chunk_byte_d       ),
    .q_o    ( chunk_byte_q       )
  );

  logic       capture_transfer_width;
  logic [2:0] transfer_width_q, transfer_width_d;
  prim_generic_flop_en #(
    .Width(3)
  ) aff_transfer_width (
    .clk_i ( gated_clk              ),
    .rst_ni( rst_ni                 ),
    .en_i  ( capture_transfer_width ),
    .d_i   ( transfer_width_d       ),
    .q_o   ( transfer_width_q       )
  );

  logic                      capture_addr;
  logic [SYS_ADDR_WIDTH-1:0] src_addr_q, src_addr_d;
  logic [SYS_ADDR_WIDTH-1:0] dst_addr_q, dst_addr_d;
  prim_generic_flop_en #(
    .Width(SYS_ADDR_WIDTH)
  ) aff_src_addr (
    .clk_i ( gated_clk    ),
    .rst_ni( rst_ni       ),
    .en_i  ( capture_addr ),
    .d_i   ( src_addr_d   ),
    .q_o   ( src_addr_q   )
  );

  prim_generic_flop_en #(
    .Width(SYS_ADDR_WIDTH)
  ) aff_dst_addr (
    .clk_i ( gated_clk    ),
    .rst_ni( rst_ni       ),
    .en_i  ( capture_addr ),
    .d_i   ( dst_addr_d   ),
    .q_o   ( dst_addr_q   )
  );

  logic                  capture_asid;
  logic [ASID_WIDTH-1:0] src_asid_q, src_asid_d;
  logic [ASID_WIDTH-1:0] dst_asid_q, dst_asid_d;
  prim_generic_flop_en #(
    .Width(ASID_WIDTH)
  ) aff_src_asid (
    .clk_i ( gated_clk    ),
    .rst_ni( rst_ni       ),
    .en_i  ( capture_asid ),
    .d_i   ( src_asid_d   ),
    .q_o   ( src_asid_q   )
  );

  prim_generic_flop_en #(
    .Width(ASID_WIDTH)
  ) aff_dst_asid (
    .clk_i ( gated_clk    ),
    .rst_ni( rst_ni       ),
    .en_i  ( capture_asid ),
    .d_i   ( dst_asid_d   ),
    .q_o   ( dst_asid_q   )
  );

  logic                       capture_be;
  logic [top_pkg::TL_DBW-1:0] req_src_be_q, req_src_be_d;
  logic [top_pkg::TL_DBW-1:0] req_dst_be_q, req_dst_be_d;
  prim_generic_flop_en #(
    .Width(top_pkg::TL_DBW)
  ) aff_req_src_be (
    .clk_i ( gated_clk    ),
    .rst_ni( rst_ni       ),
    .en_i  ( capture_be   ),
    .d_i   ( req_src_be_d ),
    .q_o   ( req_src_be_q )
  );

  prim_generic_flop_en #(
    .Width(top_pkg::TL_DBW)
  ) aff_req_dst_be (
    .clk_i ( gated_clk    ),
    .rst_ni( rst_ni       ),
    .en_i  ( capture_be   ),
    .d_i   ( req_dst_be_d ),
    .q_o   ( req_dst_be_q )
  );

  prim_generic_flop_en #(
    .Width(INT_CLEAR_SOURCES_WIDTH)
  ) u_clear_index (
    .clk_i ( gated_clk      ),
    .rst_ni( rst_ni         ),
    .en_i  ( clear_index_en ),
    .d_i   ( clear_index_d  ),
    .q_o   ( clear_index_q  )
  );

  logic use_inline_hashing;
  logic sha2_hash_start, sha2_hash_process;
  logic sha2_valid, sha2_ready, sha2_digest_set, sha2_digest_clear;
  sha_fifo32_t sha2_data;
  digest_mode_e sha2_mode;
  sha_word64_t [7:0] sha2_digest;

  assign use_inline_hashing = reg2hw.control.opcode.q inside {OpcSha256,  OpcSha384, OpcSha512};
  // When reaching DmaShaFinalize, we are consuming data and start computing the digest value
  assign sha2_hash_process = (ctrl_state_q == DmaShaFinalize);

  logic sha2_consumed_d, sha2_consumed_q;
  prim_flop #(
    .Width(1)
  ) u_sha2_consumed (
    .clk_i ( gated_clk       ),
    .rst_ni( rst_ni          ),
    .d_i   ( sha2_consumed_d ),
    .q_o   ( sha2_consumed_q )
  );

  logic sha2_hash_done;
  logic sha2_hash_done_d, sha2_hash_done_q;
  prim_flop #(
    .Width(1)
  ) u_sha2_hash_done (
    .clk_i ( gated_clk        ),
    .rst_ni( rst_ni           ),
    .d_i   ( sha2_hash_done_d ),
    .q_o   ( sha2_hash_done_q )
  );

  // The SHA engine requires the message length in bits
  logic [127:0] sha2_message_len_bits;
  assign sha2_message_len_bits = reg2hw.total_data_size.q << 3;

  // Translate the DMA opcode to the SHA2 digest mode
  always_comb begin
    unique case (reg2hw.control.opcode.q)
      OpcSha256: sha2_mode = SHA2_256;
      OpcSha384: sha2_mode = SHA2_384;
      OpcSha512: sha2_mode = SHA2_512;
      default:   sha2_mode = None;
    endcase
  end

  // SHA2 engine for inline hashing operations
  sha2_multimode32 u_sha2 (
    .clk_i            ( clk_i                 ),
    .rst_ni           ( rst_ni                ),
    .wipe_secret      ( 1'b0                  ),
    .wipe_v           ( 32'b0                 ),
    .fifo_rvalid      ( sha2_valid            ),
    .fifo_rdata       ( sha2_data             ),
    .word_buffer_ready( sha2_ready            ),
    .sha_en           ( 1'b1                  ),
    .hash_start       ( sha2_hash_start       ),
    .digest_mode      ( sha2_mode             ),
    .hash_process     ( sha2_hash_process     ),
    .hash_done        ( sha2_hash_done        ),
    .message_length   ( sha2_message_len_bits ),
    .digest           ( sha2_digest           ),
    .idle             (                       )
  );

  // Note: bus signals shall be asserted only when configured and active, to ensure
  // that address and - especially - data are not leaked to other buses.

  // Host interface to OT Internal address space
  always_comb begin
    dma_host_write = (ctrl_state_q == DmaSendWrite) & (dst_asid_q == OtInternalAddr);
    dma_host_read  = (ctrl_state_q == DmaSendRead)  & (src_asid_q == OtInternalAddr);

    dma_host_tlul_req_valid = dma_host_write | dma_host_read | dma_host_clear_int;
    // TLUL 4B aligned
    dma_host_tlul_req_addr  = dma_host_write ? {dst_addr_q[top_pkg::TL_AW-1:2], 2'b0} :
                             (dma_host_read  ? {src_addr_q[top_pkg::TL_AW-1:2], 2'b0} :
                         (dma_host_clear_int ? reg2hw.int_source_addr[clear_index_q].q : 'b0));
    dma_host_tlul_req_we    = dma_host_write | dma_host_clear_int;
    dma_host_tlul_req_wdata = dma_host_write ? read_return_data_q :
                         (dma_host_clear_int ? reg2hw.int_source_wr_val[clear_index_q].q : 'b0);
    dma_host_tlul_req_be    = dma_host_write ? req_dst_be_q :
                             (dma_host_read  ? req_src_be_q
                                             : {top_pkg::TL_DBW{dma_host_clear_int}});
  end

  // Host interface to SoC CTN address space
  always_comb begin
    dma_ctn_write = (ctrl_state_q == DmaSendWrite) &
                    (dst_asid_q == SocControlAddr || dst_asid_q == OtExtFlashAddr);
    dma_ctn_read  = (ctrl_state_q == DmaSendRead) &
                    (src_asid_q == SocControlAddr || src_asid_q == OtExtFlashAddr);

    dma_ctn_tlul_req_valid = dma_ctn_write | dma_ctn_read | dma_ctn_clear_int;
    // TLUL 4B aligned
    dma_ctn_tlul_req_addr  = dma_ctn_write ? {dst_addr_q[top_pkg::TL_AW-1:2], 2'b0} :
                            (dma_ctn_read  ? {src_addr_q[top_pkg::TL_AW-1:2], 2'b0} :
                        (dma_ctn_clear_int ? reg2hw.int_source_addr[clear_index_q].q : 'b0));
    dma_ctn_tlul_req_we    = dma_ctn_write | dma_ctn_clear_int;
    dma_ctn_tlul_req_wdata = dma_ctn_write ? read_return_data_q :
                        (dma_ctn_clear_int ? reg2hw.int_source_wr_val[clear_index_q].q : 'b0);
    dma_ctn_tlul_req_be    = dma_ctn_write ? req_dst_be_q :
                            (dma_ctn_read  ? req_src_be_q : {top_pkg::TL_DBW{dma_ctn_clear_int}});
  end

  // Host interface to SoC SYS address space
  always_comb begin
    dma_sys_write = (ctrl_state_q == DmaSendWrite) & (dst_asid_q == SocSystemAddr);
    dma_sys_read  = (ctrl_state_q == DmaSendRead)  & (src_asid_q == SocSystemAddr);

    sys_req_d.vld_vec     [SysCmdWrite] = dma_sys_write;
    sys_req_d.metadata_vec[SysCmdWrite] = src_metadata;
    sys_req_d.opcode_vec  [SysCmdWrite] = SysOpcWrite;
    sys_req_d.iova_vec    [SysCmdWrite] = dma_sys_write ?
                                         {dst_addr_q[(SYS_ADDR_WIDTH-1):2], 2'b0} : 'b0;
    sys_req_d.racl_vec    [SysCmdWrite] = SysRacl[SysOpcWrite-1:0];

    sys_req_d.write_data = {SYS_DATA_WIDTH{dma_sys_write}} & read_return_data_q;
    sys_req_d.write_be   = {SYS_DATA_BYTEWIDTH{dma_sys_write}} & req_dst_be_q;

    sys_req_d.vld_vec     [SysCmdRead] = dma_sys_read;
    sys_req_d.metadata_vec[SysCmdRead] = src_metadata;
    sys_req_d.opcode_vec  [SysCmdRead] = SysOpcRead;
    sys_req_d.iova_vec    [SysCmdRead] = dma_sys_read ?
                                         {src_addr_q[(SYS_ADDR_WIDTH-1):2], 2'b0} : 'b0;
    sys_req_d.racl_vec    [SysCmdRead] = SysRacl[SYS_RACL_WIDTH-1:0];
    sys_req_d.read_be                  = req_src_be_q;
  end

  // Write response muxing
  always_comb begin
    unique case (dst_asid_q)
      OtInternalAddr: begin
        // Write request grant
        write_gnt       = dma_host_tlul_gnt;
        // Write response
        write_rsp_valid = dma_host_tlul_rsp_valid;
        // Write error occurred
        write_rsp_error = dma_host_tlul_rsp_err;
      end
      SocSystemAddr: begin
        write_gnt       = 1'b1;  // No requirement to wait
        write_rsp_valid = sys_resp_q.grant_vec[SysCmdWrite];
        write_rsp_error = 1'b0;  // Write errors do not occur on SoC System bus
      end
      // SocControlAddr, OtExtFlashAddr handled here
      //   (other ASID values prevented in configuration validation).
      default: begin
        write_gnt       = dma_ctn_tlul_gnt;
        write_rsp_valid = dma_ctn_tlul_rsp_valid;
        write_rsp_error = dma_ctn_tlul_rsp_err;
      end
    endcase
  end

  // Read response muxing
  always_comb begin
    unique case (src_asid_q)
      OtInternalAddr: begin
        // Read request grant
        read_gnt       = dma_host_tlul_gnt;
        // Read response
        read_rsp_valid = dma_host_tlul_rsp_valid;
        // Read error occurred
        read_rsp_error = dma_host_tlul_rsp_err;
      end
      SocSystemAddr: begin
        read_gnt       = 1'b1;  // No requirement to wait
        read_rsp_valid = sys_resp_q.read_data_vld;
        read_rsp_error = sys_resp_q.error_vld;
      end
      // SocControlAddr, OtExtFlashAddr handled here
      //   (other ASID values prevented in configuration validation).
      default: begin
        read_gnt       = dma_ctn_tlul_gnt;
        read_rsp_valid = dma_ctn_tlul_rsp_valid;
        read_rsp_error = dma_ctn_tlul_rsp_err;
      end
    endcase
  end

  always_comb begin
    ctrl_state_d = ctrl_state_q;

    capture_transfer_byte  = 1'b0;
    transfer_byte_d        = transfer_byte_q;
    capture_chunk_byte     = 1'b0;
    chunk_byte_d           = chunk_byte_q;
    capture_transfer_width = 1'b0;
    transfer_width_d       = '0;
    capture_return_data    = 1'b0;

    next_error     = '0;
    bad_src_addr   = 1'b0;
    bad_dst_addr   = 1'b0;
    bad_opcode     = 1'b0;
    bad_size       = 1'b0;
    bad_base_limit = 1'b0;
    bad_go_config  = 1'b0;
    bad_asid       = 1'b0;
    config_error   = 1'b0;

    capture_addr = 1'b0;
    src_addr_d   = '0;
    dst_addr_d   = '0;
    capture_asid = 1'b0;
    src_asid_d   = '0;
    dst_asid_d   = '0;

    capture_be   = '0;
    req_src_be_d = '0;
    req_dst_be_d = '0;

    dma_host_clear_int = 1'b0;
    dma_ctn_clear_int = 1'b0;
    clear_index_d  = '0;
    clear_index_en = '0;

    clear_go       = 1'b0;

    // Mux the TLUL grant and response signals depending on the selected bus interface
    int_clear_tlul_gnt       = reg2hw.clear_int_bus.q[clear_index_q]? dma_host_tlul_gnt :
                                                                      dma_ctn_tlul_gnt;
    int_clear_tlul_rsp_valid = reg2hw.clear_int_bus.q[clear_index_q]? dma_host_tlul_rsp_valid :
                                                                      dma_ctn_tlul_rsp_valid;
    dma_state_error = 1'b0;

    sha2_hash_start      = 1'b0;
    sha2_valid           = 1'b0;
    sha2_digest_set      = 1'b0;
    sha2_digest_clear    = 1'b0;
    sha2_consumed_d      = sha2_consumed_q;

    // Make SHA2 Done sticky to not miss a single-cycle done event during any outstanding writes
    if (ctrl_state_q == DmaIdle) begin
      sha2_hash_done_d = 1'b0;
    end else begin
      sha2_hash_done_d = sha2_hash_done_q | sha2_hash_done;
    end

    unique case (ctrl_state_q)
      DmaIdle: begin
        chunk_byte_d       = '0;
        capture_chunk_byte = 1'b1;
        // Wait for go bit to be set to proceed with data movement
        if (reg2hw.control.go.q && !cfg_abort_en) begin
          // Clear the transferred bytes only on the very first iteration
          if (reg2hw.control.initial_transfer.q) begin
            transfer_byte_d       = '0;
            capture_transfer_byte = 1'b1;
            sha2_digest_clear     = 1'b1;
          end
          // if not handshake start transfer
          if (!cfg_handshake_en) begin
            ctrl_state_d = DmaAddrSetup;
          end else if (cfg_handshake_en && |lsio_trigger) begin // if handshake wait for interrupt
            if (|reg2hw.clear_int_src.q) begin
              clear_index_en = 1'b1;
              clear_index_d  = '0;
              ctrl_state_d   = DmaClearIntrSrc;
            end else begin
              ctrl_state_d = DmaAddrSetup;
            end
          end
        end
        // else `go` bit will be cleared automatically by the 'control' update if `cfg_abort_en`
        // is asserted.
      end

      DmaClearIntrSrc: begin
        // Clear the interrupt by writing
        if(reg2hw.clear_int_src.q[clear_index_q]) begin
          // Send 'clear interrupt' write to the appropriate bus
          dma_host_clear_int = reg2hw.clear_int_bus.q[clear_index_q];
          dma_ctn_clear_int = !reg2hw.clear_int_bus.q[clear_index_q];

          if (int_clear_tlul_gnt) begin
            ctrl_state_d = DmaWaitIntrSrcResponse;
          end

          // Writes also get a resp valid, but no data.
          // Need to wait for this to not overrun TLUL adapter
          // The response might come immediately
          if (int_clear_tlul_rsp_valid) begin
            if (cfg_abort_en) begin
              ctrl_state_d = DmaIdle;
            end else begin
              // Proceed if we handled all
              if (32'(clear_index_q) >= (NumIntClearSources - 1)) begin
                ctrl_state_d = DmaAddrSetup;
              end
            end
          end
        end else begin
          // Do nothing if no clearing requested
          clear_index_en = 1'b1;
          clear_index_d  = clear_index_q + INT_CLEAR_SOURCES_WIDTH'(1'b1);

          if (32'(clear_index_q) >= (NumIntClearSources - 1)) begin
            ctrl_state_d = DmaAddrSetup;
          end
        end
      end

      DmaWaitIntrSrcResponse: begin
        // Writes also get a resp valid, but no data.
        // Need to wait for this to not overrun TLUL adapter
        if (int_clear_tlul_rsp_valid) begin
          if (cfg_abort_en) begin
            ctrl_state_d = DmaIdle;
          end else begin
            if (32'(clear_index_q) < (NumIntClearSources - 1)) begin
              clear_index_en = 1'b1;
              clear_index_d  = clear_index_q + INT_CLEAR_SOURCES_WIDTH'(1'b1);
              ctrl_state_d   = DmaClearIntrSrc;
            end else begin
              ctrl_state_d = DmaAddrSetup;
            end
          end
        end
      end

      DmaAddrSetup: begin
        capture_transfer_width = 1'b1;
        capture_addr           = 1'b1;
        capture_be             = 1'b1;
        sha2_consumed_d        = 1'b0;

        // Convert the `transfer_width` encoding to bytes per transaction
        unique case (reg2hw.transfer_width.q)
          DmaXfer1BperTxn: transfer_width_d = 3'b001; // 1 byte
          DmaXfer2BperTxn: transfer_width_d = 3'b010; // 2 bytes
          DmaXfer4BperTxn: transfer_width_d = 3'b100; // 4 bytes
          // Value 3 is an invalid configuration value that leads to an error
          default: bad_size = 1'b1;  // Invalid transfer_width
        endcase

        if ((transfer_byte_q == '0) ||
            (cfg_handshake_en &&
             // Does the source address need resetting to the configured base address?
             (( cfg_data_direction && chunk_byte_q == '0 && !cfg_memory_buffer_auto_increment_en) ||
              (!cfg_data_direction && (chunk_byte_q == '0 || !cfg_fifo_auto_increment_en))))) begin
          src_addr_d = {reg2hw.source_address_hi.q, reg2hw.source_address_lo.q};
        end else begin
          // Advance from the previous transaction within this chunk
          src_addr_d = src_addr_q + SYS_ADDR_WIDTH'(transfer_width_d);
        end

        if ((transfer_byte_q == '0) ||
            (cfg_handshake_en    &&
             // Does the destination address need resetting to the configured base address?
             ((!cfg_data_direction && chunk_byte_q == '0 && !cfg_memory_buffer_auto_increment_en) ||
              ( cfg_data_direction && (chunk_byte_q == '0 || !cfg_fifo_auto_increment_en))))) begin
          dst_addr_d = {reg2hw.destination_address_hi.q, reg2hw.destination_address_lo.q};
        end else begin
          // Advance from the previous transaction within this chunk
          dst_addr_d = dst_addr_q + SYS_ADDR_WIDTH'(transfer_width_d);
        end

        // Capture ASID values for use throughout the transfer.
        if (transfer_byte_q == '0) begin
          capture_asid = 1'b1;
          src_asid_d = reg2hw.address_space_id.source_asid.q;
          dst_asid_d = reg2hw.address_space_id.destination_asid.q;
        end

        unique case (transfer_width_d)
          3'b001: begin
            req_dst_be_d = top_pkg::TL_DBW'('b0001) << dst_addr_d[1:0];
            req_src_be_d = top_pkg::TL_DBW'('b0001) << src_addr_d[1:0];
          end
          3'b010: begin
            if (remaining_bytes >= TRANSFER_BYTES_WIDTH'(transfer_width_d)) begin
              req_dst_be_d = top_pkg::TL_DBW'('b0011) << dst_addr_d[1:0];
              req_src_be_d = top_pkg::TL_DBW'('b0011) << src_addr_d[1:0];
            end else begin
              req_dst_be_d = top_pkg::TL_DBW'('b0001) << dst_addr_d[1:0];
              req_src_be_d = top_pkg::TL_DBW'('b0001) << src_addr_d[1:0];
            end
          end
          3'b100: begin
            if (remaining_bytes >= TRANSFER_BYTES_WIDTH'(transfer_width_d)) begin
              req_dst_be_d = {top_pkg::TL_DBW{1'b1}};
            end else begin
              unique case (remaining_bytes)
                TRANSFER_BYTES_WIDTH'('h1): req_dst_be_d = top_pkg::TL_DBW'('b0001);
                TRANSFER_BYTES_WIDTH'('h2): req_dst_be_d = top_pkg::TL_DBW'('b0011);
                TRANSFER_BYTES_WIDTH'('h3): req_dst_be_d = top_pkg::TL_DBW'('b0111);
                default:                    req_dst_be_d = top_pkg::TL_DBW'('b1111);
              endcase
            end

            req_src_be_d = req_dst_be_d;  // in the case of 4B src should always = dst
          end
          default: begin
            req_dst_be_d = top_pkg::TL_DBW'('b0000);
            req_src_be_d = top_pkg::TL_DBW'('b0000);
          end
        endcase

        // Error checking. An invalid configuration triggers one or more errors
        // and does not start the DMA transfer
        if ((reg2hw.chunk_data_size.q == '0) ||         // No empty transactions
            (reg2hw.total_data_size.q == '0)) begin     // No empty transactions
          bad_size = 1'b1;
        end

        if (!(reg2hw.control.opcode.q inside {OpcCopy, OpcSha256, OpcSha384, OpcSha512})) begin
          bad_opcode = 1'b1;
        end

        // Inline hashing is only allowed for 32-bit transfer width
        if (use_inline_hashing) begin
          if (reg2hw.transfer_width.q != DmaXfer4BperTxn) begin
            bad_size = 1'b1;
          end
        end

        // Ensure that ASIDs have valid values
        // SEC_CM: ASID.INTERSIG.MUBI
        if (!(reg2hw.address_space_id.source_asid.q inside {OtInternalAddr,
                                                            SocControlAddr,
                                                            SocSystemAddr,
                                                            OtExtFlashAddr})) begin
          bad_asid = 1'b1;
        end
        if (!(reg2hw.address_space_id.destination_asid.q inside {OtInternalAddr,
                                                                 SocControlAddr,
                                                                 SocSystemAddr,
                                                                 OtExtFlashAddr})) begin
          bad_asid = 1'b1;
        end

        // Check the validity of the restricted DMA-enabled memory range
        // Note: both the base and the limit addresses are inclusive
        if (reg2hw.enabled_memory_range_limit.q < reg2hw.enabled_memory_range_base.q) begin
          bad_base_limit = 1'b1;
        end

        // In 4-byte transfers, source and destination address must be 4-byte aligned
        if (reg2hw.transfer_width.q == DmaXfer4BperTxn &&
          (|reg2hw.source_address_lo.q[1:0])) begin
          bad_src_addr = 1'b1;
        end
        if (reg2hw.transfer_width.q == DmaXfer4BperTxn &&
          (|reg2hw.destination_address_lo.q[1:0])) begin
          bad_dst_addr = 1'b1;
        end

        // In 2-byte transfers, source and destination address must be 2-byte aligned
        if (reg2hw.transfer_width.q == DmaXfer2BperTxn && reg2hw.source_address_lo.q[0]) begin
          bad_src_addr = 1'b1;
        end
        if (reg2hw.transfer_width.q == DmaXfer2BperTxn && reg2hw.destination_address_lo.q[0]) begin
          bad_dst_addr = 1'b1;
        end

        // Source and destination must have the same alignment
        if (reg2hw.source_address_lo.q[1:0] != reg2hw.destination_address_lo.q[1:0]) begin
          bad_src_addr = 1'b1;
          bad_dst_addr = 1'b1;
        end
        // If data from the SOC system bus, the control bus, or the external flash is transferred to
        // the OT internal memory, we must check if the destination address range falls into the DMA
        // enabled memory region.
        if (((reg2hw.address_space_id.source_asid.q == SocControlAddr) ||
             (reg2hw.address_space_id.source_asid.q == SocSystemAddr)  ||
             (reg2hw.address_space_id.source_asid.q == OtExtFlashAddr)) &&
             (reg2hw.address_space_id.destination_asid.q == OtInternalAddr) &&
             // Out-of-bound check
             ((reg2hw.destination_address_lo.q > reg2hw.enabled_memory_range_limit.q) ||
              (reg2hw.destination_address_lo.q < reg2hw.enabled_memory_range_base.q)  ||
              ((SYS_ADDR_WIDTH'(reg2hw.destination_address_lo.q) +
                SYS_ADDR_WIDTH'(reg2hw.chunk_data_size.q)) >
                SYS_ADDR_WIDTH'(reg2hw.enabled_memory_range_limit.q)))) begin
          bad_dst_addr = 1'b1;
        end

        // If data from the OT internal memory is transferred  to the SOC system bus, the control
        // bus, or the external flash, we must check if the source address range falls into the DMA
        // enabled memory region.
        if (((reg2hw.address_space_id.destination_asid.q == SocControlAddr) ||
             (reg2hw.address_space_id.destination_asid.q == SocSystemAddr)  ||
             (reg2hw.address_space_id.destination_asid.q == OtExtFlashAddr)) &&
             (reg2hw.address_space_id.source_asid.q == OtInternalAddr) &&
              // Out-of-bound check
              ((reg2hw.source_address_lo.q > reg2hw.enabled_memory_range_limit.q) ||
               (reg2hw.source_address_lo.q < reg2hw.enabled_memory_range_base.q)  ||
               ((SYS_ADDR_WIDTH'(reg2hw.source_address_lo.q) +
                SYS_ADDR_WIDTH'(reg2hw.chunk_data_size.q)) >
                SYS_ADDR_WIDTH'(reg2hw.enabled_memory_range_limit.q)))) begin
          bad_src_addr = 1'b1;
        end

        // If the source ASID is the SOC control port, the OT internal port, or the external flash,
        //  we are accessing a 32-bit address space. Thus the upper bits of the source address must
        // be zero
        if (((reg2hw.address_space_id.source_asid.q == SocControlAddr) ||
             (reg2hw.address_space_id.source_asid.q == OtExtFlashAddr) ||
             (reg2hw.address_space_id.source_asid.q == OtInternalAddr)) &&
            (|reg2hw.source_address_hi.q)) begin
          bad_src_addr = 1'b1;
        end

        // If the destination ASID is the SOC control port, the OT internal port or the external
        // flash, we are accessing a 32-bit address space. Thus the upper bits of the destination
        // address must be zero
        if (((reg2hw.address_space_id.destination_asid.q == SocControlAddr) ||
             (reg2hw.address_space_id.destination_asid.q == OtExtFlashAddr) ||
             (reg2hw.address_space_id.destination_asid.q == OtInternalAddr)) &&
            (|reg2hw.destination_address_hi.q)) begin
          bad_dst_addr = 1'b1;
        end

        if (!reg2hw.range_valid.q) begin
          bad_go_config = 1'b1;
        end

        config_error = bad_src_addr   ||
                       bad_dst_addr   ||
                       bad_size       ||
                       bad_base_limit ||
                       bad_opcode     ||
                       bad_go_config  ||
                       bad_asid;

        if (config_error) begin
          next_error[DmaSourceAddrErr]      = bad_src_addr;
          next_error[DmaDestinationAddrErr] = bad_dst_addr;
          next_error[DmaOpcodeErr]          = bad_opcode;
          next_error[DmaSizeErr]            = bad_size;
          next_error[DmaBaseLimitErr]       = bad_base_limit;
          next_error[DmaGoConfigErr]        = bad_go_config;
          next_error[DmaAsidErr]            = bad_asid;

          ctrl_state_d = DmaError;
        end else if (cfg_abort_en) begin
          ctrl_state_d = DmaIdle;
        end else begin
          // Start the inline hashing if we are in the very first transfer. If we are in the first
          // iteration of a transfer, which is not the very first transfer, only capture the
          // transfer length to compute the final message length
          if (reg2hw.control.initial_transfer.q) begin
            if (use_inline_hashing) begin
              sha2_hash_start = 1'b1;
            end
          end
          ctrl_state_d = DmaSendRead;
        end
      end

      DmaSendRead,
      DmaWaitReadResponse: begin
        if (cfg_abort_en) begin
          ctrl_state_d = DmaIdle;
        end else if (read_rsp_valid) begin
          if (read_rsp_error) begin
            next_error[DmaCompletionErr] = 1'b1;
            ctrl_state_d                 = DmaError;
          end else begin
            capture_return_data = 1'b1;
            // We received data, feed it into the SHA2 engine
            if (use_inline_hashing) begin
              sha2_valid      = 1'b1;
              sha2_consumed_d = sha2_ready;
            end
            ctrl_state_d = DmaSendWrite;
          end
        end else if (read_gnt) begin
          // Only Request handled
          ctrl_state_d = DmaWaitReadResponse;
        end
      end

      DmaSendWrite,
      DmaWaitWriteResponse: begin
        // If using inline hashing and data is not yet consumed, apply it
        if (use_inline_hashing && !sha2_consumed_q) begin
          sha2_valid = 1'b1;
          sha2_consumed_d = sha2_ready;
        end

        if (cfg_abort_en) begin
          ctrl_state_d = DmaIdle;
        end else if (write_rsp_valid) begin

          if (write_rsp_error) begin
            next_error[DmaCompletionErr] = 1'b1;
            ctrl_state_d                 = DmaError;
          end else begin
            // Advance by the number of bytes just transferred
            transfer_byte_d       = transfer_byte_q + TRANSFER_BYTES_WIDTH'(transfer_width_q);
            chunk_byte_d          = chunk_byte_q + TRANSFER_BYTES_WIDTH'(transfer_width_q);
            capture_transfer_byte = 1'b1;
            capture_chunk_byte    = 1'b1;

            // Will there still be more to do _after_ this advance?
            if (transfer_byte_d >= reg2hw.total_data_size.q) begin
              if (use_inline_hashing) begin
                ctrl_state_d = DmaShaFinalize;
              end else begin
                clear_go     = 1'b1;
                ctrl_state_d = DmaIdle;
              end
            end else if (chunk_byte_d >= reg2hw.chunk_data_size.q) begin
              // Conditionally clear the go bit when not being in hardware handshake mode.
              // In non-hardware handshake mode, finishing one chunk should raise the done IRQ
              // and done bit, and release the go bit for the next FW-controlled chunk.
              clear_go     = !cfg_handshake_en;
              ctrl_state_d = DmaIdle;
            end else begin
              ctrl_state_d = DmaAddrSetup;
            end

            // In all cases from above, if we are doing inline hashing and the data was not consumed
            // yet, wait until it consumed by the SHA engine and then continue
            if (use_inline_hashing) begin
              if (!(sha2_ready || sha2_consumed_q)) begin
                ctrl_state_d = DmaShaWait;
              end
            end
          end
        end else if (write_gnt) begin
          // Only Request handled
          ctrl_state_d = DmaWaitWriteResponse;
        end
      end

      DmaShaWait: begin
        // Still waiting for the SHA engine to consume the data
        sha2_valid = 1'b1;

        if (cfg_abort_en) begin
          ctrl_state_d = DmaIdle;
        end else if (sha2_ready) begin
          // Byte count has already been updated for this transfer
          if (transfer_byte_q >= reg2hw.total_data_size.q) begin
            ctrl_state_d = DmaShaFinalize;
          end else if (chunk_byte_q >= reg2hw.chunk_data_size.q) begin
            // Conditionally clear the go bit when not being in hardware handshake mode.
            // In non-hardware handshake mode, finishing one chunk should raise the done IRQ
            // and done bit, and release the go bit for the next FW-controlled chunk.
            clear_go     = !cfg_handshake_en;
            ctrl_state_d = DmaIdle;
          end else begin
            ctrl_state_d = DmaAddrSetup;
          end
        end
      end

      DmaShaFinalize: begin
        if (sha2_hash_done_q) begin
          // Digest is ready, capture it to the CSRs
          sha2_digest_set = 1'b1;
          ctrl_state_d   = DmaIdle;
          clear_go       = 1'b1;
        end else if (cfg_abort_en) begin
          ctrl_state_d = DmaIdle;
        end
      end

        // wait here until error is cleared
      DmaError: begin
        if (!reg2hw.status.error.q) begin
          ctrl_state_d = DmaIdle;
          clear_go     = 1'b1;
        end
      end

      default: begin
        // Should not be reachable
        dma_state_error = 1'b1;
      end
    endcase
  end

  always_comb begin
    read_return_data_d = '0;
    if (capture_return_data) begin
      unique case (src_asid_q)
        OtInternalAddr: read_return_data_d = dma_host_tlul_rsp_data;
        SocControlAddr,
        OtExtFlashAddr: read_return_data_d = dma_ctn_tlul_rsp_data;
        default:        read_return_data_d = sys_resp_q.read_data;
      endcase
    end
  end


  prim_generic_flop_en #(
    .Width(top_pkg::TL_DW)
  ) aff_read_return_data (
    .clk_i ( gated_clk             ),
    .rst_ni( rst_ni                ),
    .en_i  ( capture_return_data   ),
    .d_i   ( read_return_data_d    ),
    .q_o   ( read_return_data_q    )
  );

  // Mux the data for the SHA2 engine. When capturing the data we
  // can use the data from the bus, otherwise the captured data from the flop
  assign sha2_data.data = capture_return_data? read_return_data_d :
                                               read_return_data_q;
  assign sha2_data.mask = req_dst_be_q;

  // Interrupt logic
  logic test_done_interrupt;
  logic test_error_interrupt;
  logic test_memory_buffer_limit_interrupt;
  logic send_memory_buffer_limit_interrupt;
  logic sent_almost_limit_interrupt_d, sent_almost_limit_interrupt_q;
  logic send_almost_limit_interrupt;
  logic sent_limit_interrupt_d, sent_limit_interrupt_q;
  logic send_limit_interrupt;

  logic data_move_state, data_move_state_valid;
  logic update_destination_addr_reg, update_source_addr_reg;

  assign test_done_interrupt  = reg2hw.intr_test.dma_done.q  && reg2hw.intr_test.dma_done.qe;
  assign test_error_interrupt = reg2hw.intr_test.dma_error.q && reg2hw.intr_test.dma_error.qe;
  assign test_memory_buffer_limit_interrupt =
    reg2hw.intr_test.dma_memory_buffer_limit.q &&
    reg2hw.intr_test.dma_memory_buffer_limit.qe;

  // Signal interrupt controller whenever an enabled interrupt info bit is set
  assign intr_dma_done_o  = reg2hw.intr_state.dma_done.q  && reg2hw.intr_enable.dma_done.q;
  assign intr_dma_error_o = reg2hw.intr_state.dma_error.q && reg2hw.intr_enable.dma_error.q;
  assign intr_dma_memory_buffer_limit_o = reg2hw.intr_state.dma_memory_buffer_limit.q &&
                                          reg2hw.intr_enable.dma_memory_buffer_limit.q;

  always_comb begin
    sent_almost_limit_interrupt_d = sent_almost_limit_interrupt_q;

    if (send_almost_limit_interrupt) begin
      sent_almost_limit_interrupt_d = 1'b1;
    end else if ((ctrl_state_q == DmaIdle) && handshake_interrupt) begin
      sent_almost_limit_interrupt_d = 1'b0;
    end
  end

  prim_flop #(
    .Width(1)
  ) aff_send_almost_limit_interrupt (
    .clk_i ( gated_clk                     ),
    .rst_ni( rst_ni                        ),
    .d_i   ( sent_almost_limit_interrupt_d ),
    .q_o   ( sent_almost_limit_interrupt_q )
  );

  assign send_almost_limit_interrupt =
    (!sent_almost_limit_interrupt_q)    &&  // only want to send once
    data_move_state_valid               &&  // only trigger for single cycle when data has moved
    cfg_handshake_en                    &&
    cfg_memory_buffer_auto_increment_en &&
    (!cfg_data_direction)               &&
    (dst_addr_q >= {reg2hw.destination_address_almost_limit_hi.q,
                    reg2hw.destination_address_almost_limit_lo.q});

  always_comb begin
    sent_limit_interrupt_d = sent_limit_interrupt_q;

    if (send_limit_interrupt) begin
      sent_limit_interrupt_d = 1'b1;
    end else if ((ctrl_state_q == DmaIdle) && handshake_interrupt) begin
      sent_limit_interrupt_d = 1'b0;
    end
  end

  prim_flop #(
    .Width(1)
  ) aff_send_limit_interrupt (
    .clk_i ( gated_clk              ),
    .rst_ni( rst_ni                 ),
    .d_i   ( sent_limit_interrupt_d ),
    .q_o   ( sent_limit_interrupt_q )
  );

  assign send_limit_interrupt =
    (!sent_limit_interrupt_q)           &&  // only want to send once
    data_move_state_valid               &&  // only trigger for single cycle when data has moved
    cfg_handshake_en                    &&
    cfg_memory_buffer_auto_increment_en &&
    (!cfg_data_direction)               &&
    (dst_addr_q >= {reg2hw.destination_address_limit_hi.q,
                    reg2hw.destination_address_limit_lo.q});

  // Send out an interrupt when reaching almost the buffer limit or when really reaching the limit
  // Ensures that all data until the IRQ is transferred.
  assign send_memory_buffer_limit_interrupt = send_almost_limit_interrupt || send_limit_interrupt;

  // Data was moved if we get a write valid response
  assign data_move_state_valid = (write_rsp_valid && (ctrl_state_q == DmaSendWrite));

  assign data_move_state = (ctrl_state_q == DmaSendWrite)         ||
                           (ctrl_state_q == DmaWaitWriteResponse) ||
                           (ctrl_state_q == DmaShaWait)           ||
                           (ctrl_state_q == DmaShaFinalize);

  assign new_destination_addr = cfg_data_direction ?
    ({reg2hw.destination_address_hi.q, reg2hw.destination_address_lo.q} +
     SYS_ADDR_WIDTH'(transfer_width_q)) :
    ({reg2hw.destination_address_hi.q, reg2hw.destination_address_lo.q} +
     SYS_ADDR_WIDTH'(reg2hw.chunk_data_size.q));

  assign new_source_addr = cfg_data_direction ?
    ({reg2hw.source_address_hi.q, reg2hw.source_address_lo.q} +
      SYS_ADDR_WIDTH'(reg2hw.chunk_data_size.q)) :
    ({reg2hw.source_address_hi.q, reg2hw.source_address_lo.q} +
      SYS_ADDR_WIDTH'(transfer_width_q));

  // Calculate remaining amount of data
  assign remaining_bytes = reg2hw.chunk_data_size.q - chunk_byte_q;

  always_comb begin
    hw2reg = '0;

    // If we are in hardware handshake mode with auto-increment increment the corresponding address
    // when finishing a DMA operation when transitioning from a data move state to the idle state
    update_destination_addr_reg = 1'b0;
    update_source_addr_reg      = 1'b0;
    if (cfg_handshake_en && cfg_memory_buffer_auto_increment_en &&
        data_move_state && (ctrl_state_d == DmaIdle)) begin
      if (cfg_data_direction) begin
        update_source_addr_reg = 1'b1;
      end else begin
        update_destination_addr_reg = 1'b1;
      end
    end

    // Clear the inline initial transfer flag starting flag when leaving the
    // DmaAddrSetup the first time
    if ((ctrl_state_q == DmaAddrSetup) & reg2hw.control.initial_transfer.q) begin
      hw2reg.control.initial_transfer.de = 1'b1;
    end

    // Write digest to CSRs when needed. The digest is an 8-element  64-bit datatype. Depending on
    // the selected hashing algorithm, the digest is stored differently in the digest datatype:
    // SHA2-256: digest[0-7][31:0] store the 256-bit digest. The upper 32-bits of all digest
    //           elements are zero
    // SHA2-384: digest[0-5][63:0] store the 384-bit digest.
    // SHA2-512: digest[0-7][63:0] store the 512-bit digest.
    for (int i = 0; i < NR_SHA_DIGEST_ELEMENTS; i++) begin
      hw2reg.sha2_digest[i].de = sha2_digest_set | sha2_digest_clear;
    end

    for (int unsigned i = 0; i < NR_SHA_DIGEST_ELEMENTS / 2; i++) begin
      unique case (reg2hw.control.opcode.q)
        OpcSha256: begin
          hw2reg.sha2_digest[i].d = sha2_digest_clear? '0 : sha2_digest[i][0 +: 32];
        end
        OpcSha384: begin
          if (i < 6) begin
            hw2reg.sha2_digest[i*2].d     = sha2_digest_clear? '0 : sha2_digest[i][32 +: 32];
            hw2reg.sha2_digest[(i*2)+1].d = sha2_digest_clear? '0 : sha2_digest[i][0  +: 32];
          end
        end
        default: begin // SHA2-512
          hw2reg.sha2_digest[i*2].d     = sha2_digest_clear? '0 : sha2_digest[i][32 +: 32];
          hw2reg.sha2_digest[(i*2)+1].d = sha2_digest_clear? '0 : sha2_digest[i][0  +: 32];
        end
      endcase
    end

    hw2reg.status.sha2_digest_valid.de = sha2_digest_set | sha2_digest_clear;
    hw2reg.status.sha2_digest_valid.d  = sha2_digest_set;

    hw2reg.destination_address_hi.de = update_destination_addr_reg;
    hw2reg.destination_address_hi.d  = new_destination_addr[63:32];

    hw2reg.destination_address_lo.de = update_destination_addr_reg;
    hw2reg.destination_address_lo.d  = new_destination_addr[31:0];

    hw2reg.source_address_hi.de = update_source_addr_reg;
    hw2reg.source_address_hi.d  = new_source_addr[63:32];

    hw2reg.source_address_lo.de = update_source_addr_reg;
    hw2reg.source_address_lo.d  = new_source_addr[31:0];

    // Clear the go bit if we are in a single transfer and finished the DMA operation,
    // hardware handshake mode when we finished all transfers, or when aborting the transfer.
    hw2reg.control.go.de = clear_go || (cfg_abort_en && (ctrl_state_d == DmaIdle));
    hw2reg.control.go.d  = 1'b0;

    // Assert busy write enable on
    // - transitions from IDLE out
    // - clearing the go bit (going back to idle)
    // - abort               (going back to idle)
    hw2reg.status.busy.de = ((ctrl_state_q  == DmaIdle) && (ctrl_state_d != DmaIdle)) ||
                            hw2reg.control.go.de;
    // If transitioning from IDLE, set busy, otherwise clear it
    hw2reg.status.busy.d  = ((ctrl_state_q == DmaIdle) &&
                            (ctrl_state_d != DmaIdle)) ? 1'b1 : 1'b0;

    // Set done bit and raise interrupt when we either finished a single transfer or all transfers
    // in hardware handshake mode.
    hw2reg.status.done.de = (!cfg_abort_en)     &&
                             data_move_state    &&
                             clear_go;
    hw2reg.status.done.d  = 1'b1;

    hw2reg.status.error.d  = 1'b1;
    hw2reg.status.error.de = (ctrl_state_d == DmaError);

    hw2reg.status.error_code.d  = next_error;
    hw2reg.status.error_code.de = (ctrl_state_d == DmaError);

    hw2reg.status.aborted.de = cfg_abort_en && (ctrl_state_d == DmaIdle);
    hw2reg.status.aborted.d  = 1'b1;

    // interrupt management
    hw2reg.intr_state.dma_done.de = reg2hw.status.done.q | test_done_interrupt;
    hw2reg.intr_state.dma_done.d  = 1'b1;

    hw2reg.intr_state.dma_error.de = reg2hw.status.error.q | test_error_interrupt;
    hw2reg.intr_state.dma_error.d  = 1'b1;

    hw2reg.intr_state.dma_memory_buffer_limit.de = send_memory_buffer_limit_interrupt |
                                                   test_memory_buffer_limit_interrupt;
    hw2reg.intr_state.dma_memory_buffer_limit.d  = 1'b1;

    // write to clear state register, value doesn't matter
    // clearing overrides new setting, and needs to be the last thing in this always_comb
    if (reg2hw.clear_state.qe) begin
      hw2reg.status.done.de = 1'b1;
      hw2reg.status.done.d  = 1'b0;

      hw2reg.status.error.de = 1'b1;
      hw2reg.status.error.d  = 1'b0;

      hw2reg.status.error_code.de = 1'b1;
      hw2reg.status.error_code.d  = {$bits(hw2reg.status.error_code.d){1'b0}};

      hw2reg.status.aborted.de = 1'b1;
      hw2reg.status.aborted.d  = 1'b0;

      hw2reg.status.sha2_digest_valid.de = 1'b1;
      hw2reg.status.sha2_digest_valid.d  = 1'b0;

      for (int i = 0; i < NR_SHA_DIGEST_ELEMENTS; i++) begin
        hw2reg.sha2_digest[i].de = 1'b0;
        hw2reg.sha2_digest[i].d  = '0;
      end

      hw2reg.intr_state.dma_done.de = 1'b1;
      hw2reg.intr_state.dma_done.d  = 1'b0;

      hw2reg.intr_state.dma_error.de = 1'b1;
      hw2reg.intr_state.dma_error.d  = 1'b0;

      hw2reg.intr_state.dma_memory_buffer_limit.de = 1'b1;
      hw2reg.intr_state.dma_memory_buffer_limit.d  = 1'b0;
    end
  end

  always_comb begin
    cfg_handshake_en                    = reg2hw.control.hardware_handshake_enable.q;
    cfg_data_direction                  = reg2hw.control.data_direction.q;
    cfg_fifo_auto_increment_en          = reg2hw.control.fifo_auto_increment_enable.q;
    cfg_memory_buffer_auto_increment_en = reg2hw.control.memory_buffer_auto_increment_enable.q;
    cfg_abort_en                        = reg2hw.control.abort.q;
  end

  //////////////////////////////////////////////////////////////////////////////
  // Interface signal flopping
  //////////////////////////////////////////////////////////////////////////////

  prim_flop #(
    .Width(SYS_NUM_REQ_CH)
  ) u_sys_vld_vec (
    .clk_i ( gated_clk         ),
    .rst_ni( rst_ni            ),
    .d_i   ( sys_req_d.vld_vec ),
    .q_o   ( sys_o.vld_vec     )
  );

  prim_generic_flop_en #(
    .Width(SYS_METADATA_WIDTH)
  ) u_sys_metadata_write_vec (
    .clk_i ( gated_clk                           ),
    .rst_ni( rst_ni                              ),
    .en_i  ( sys_req_d.vld_vec[SysCmdWrite]      ),
    .d_i   ( sys_req_d.metadata_vec[SysCmdWrite] ),
    .q_o   ( sys_o.metadata_vec[SysCmdWrite]     )
  );

  logic [$bits(sys_opc_e)-1:0] sys_req_opcode_write_vec_q;
  prim_generic_flop_en #(
    .Width($bits(sys_opc_e))
  ) u_sys_opcode_write_vec (
    .clk_i ( gated_clk                         ),
    .rst_ni( rst_ni                            ),
    .en_i  ( sys_req_d.vld_vec[SysCmdWrite]    ),
    .d_i   ( sys_req_d.opcode_vec[SysCmdWrite] ),
    .q_o   ( sys_req_opcode_write_vec_q        )
  );
  assign sys_o.opcode_vec[SysCmdWrite] = sys_opc_e'(sys_req_opcode_write_vec_q);

  prim_generic_flop_en #(
    .Width(SYS_ADDR_WIDTH)
  ) u_sys_iova_write_vec (
    .clk_i ( gated_clk                       ),
    .rst_ni( rst_ni                          ),
    .en_i  ( sys_req_d.vld_vec[SysCmdWrite]  ),
    .d_i   ( sys_req_d.iova_vec[SysCmdWrite] ),
    .q_o   ( sys_o.iova_vec[SysCmdWrite]     )
  );

  prim_generic_flop_en #(
    .Width(SYS_RACL_WIDTH)
  ) u_sys_racl_write_vec (
    .clk_i ( gated_clk                       ),
    .rst_ni( rst_ni                          ),
    .en_i  ( sys_req_d.vld_vec[SysCmdWrite]  ),
    .d_i   ( sys_req_d.racl_vec[SysCmdWrite] ),
    .q_o   ( sys_o.racl_vec[SysCmdWrite]     )
  );

  prim_generic_flop_en #(
    .Width(SYS_METADATA_WIDTH)
  ) u_sys_metadata_read_vec (
    .clk_i ( gated_clk                          ),
    .rst_ni( rst_ni                             ),
    .en_i  ( sys_req_d.vld_vec[SysCmdRead]      ),
    .d_i   ( sys_req_d.metadata_vec[SysCmdRead] ),
    .q_o   ( sys_o.metadata_vec[SysCmdRead]     )
  );

  logic [$bits(sys_opc_e)-1:0] sys_req_opcode_read_vec_q;
  prim_generic_flop_en #(
    .Width($bits(sys_opc_e))
  ) u_sys_opcode_read_vec (
    .clk_i ( gated_clk                        ),
    .rst_ni( rst_ni                           ),
    .en_i  ( sys_req_d.vld_vec[SysCmdRead]    ),
    .d_i   ( sys_req_d.opcode_vec[SysCmdRead] ),
    .q_o   ( sys_req_opcode_read_vec_q        )
  );
  assign sys_o.opcode_vec[SysCmdRead] = sys_opc_e'(sys_req_opcode_read_vec_q);

  prim_generic_flop_en #(
    .Width(SYS_ADDR_WIDTH)
  ) u_sys_iova_read_vec (
    .clk_i ( gated_clk                      ),
    .rst_ni( rst_ni                         ),
    .en_i  ( sys_req_d.vld_vec[SysCmdRead]  ),
    .d_i   ( sys_req_d.iova_vec[SysCmdRead] ),
    .q_o   ( sys_o.iova_vec[SysCmdRead]     )
  );

  prim_generic_flop_en #(
    .Width(SYS_RACL_WIDTH)
  ) u_sys_racl_read_vec (
    .clk_i ( gated_clk                      ),
    .rst_ni( rst_ni                         ),
    .en_i  ( sys_req_d.vld_vec[SysCmdRead]  ),
    .d_i   ( sys_req_d.racl_vec[SysCmdRead] ),
    .q_o   ( sys_o.racl_vec[SysCmdRead]     )
  );

  prim_generic_flop_en #(
    .Width(SYS_DATA_WIDTH)
  ) u_sys_write_data (
    .clk_i ( gated_clk                      ),
    .rst_ni( rst_ni                         ),
    .en_i  ( sys_req_d.vld_vec[SysCmdWrite] ),
    .d_i   ( sys_req_d.write_data           ),
    .q_o   ( sys_o.write_data               )
  );

  prim_generic_flop_en #(
    .Width(SYS_DATA_BYTEWIDTH)
  ) u_sys_write_be (
    .clk_i ( gated_clk                      ),
    .rst_ni( rst_ni                         ),
    .en_i  ( sys_req_d.vld_vec[SysCmdWrite] ),
    .d_i   ( sys_req_d.write_be             ),
    .q_o   ( sys_o.write_be                 )
  );

  prim_generic_flop_en #(
    .Width(SYS_DATA_BYTEWIDTH)
  ) u_sys_read_be (
    .clk_i ( gated_clk                      ),
    .rst_ni( rst_ni                         ),
    .en_i  ( sys_req_d.vld_vec[SysCmdWrite] ),
    .d_i   ( sys_req_d.read_be              ),
    .q_o   ( sys_o.read_be                  )
  );

  prim_flop #(
    .Width(SYS_NUM_REQ_CH)
  ) u_sys_gnt_vec (
    .clk_i ( gated_clk            ),
    .rst_ni( rst_ni               ),
    .d_i   ( sys_i.grant_vec      ),
    .q_o   ( sys_resp_q.grant_vec )
  );

  prim_flop #(
    .Width(1)
  ) u_sys_read_data_valid (
    .clk_i ( gated_clk                ),
    .rst_ni( rst_ni                   ),
    .d_i   ( sys_i.read_data_vld      ),
    .q_o   ( sys_resp_q.read_data_vld )
  );

  prim_flop #(
    .Width(SYS_DATA_WIDTH)
  ) u_sys_read_data (
    .clk_i ( gated_clk            ),
    .rst_ni( rst_ni               ),
    .d_i   ( sys_i.read_data      ),
    .q_o   ( sys_resp_q.read_data )
  );

  prim_flop #(
    .Width(SYS_METADATA_WIDTH)
  ) u_sys_read_metadata (
    .clk_i ( gated_clk                ),
    .rst_ni( rst_ni                   ),
    .d_i   ( sys_i.read_metadata      ),
    .q_o   ( sys_resp_q.read_metadata )
  );

  prim_flop #(
    .Width(1)
  ) u_sys_read_error_valid (
    .clk_i ( gated_clk            ),
    .rst_ni( rst_ni               ),
    .d_i   ( sys_i.error_vld      ),
    .q_o   ( sys_resp_q.error_vld )
  );

  prim_flop #(
    .Width(SYS_NUM_ERROR_TYPES)
  ) u_sys_read_error (
    .clk_i ( gated_clk            ),
    .rst_ni( rst_ni               ),
    .d_i   ( sys_i.error_vec      ),
    .q_o   ( sys_resp_q.error_vec )
  );

  //////////////////////////////////////////////////////////////////////////////
  // Unused signals
  //////////////////////////////////////////////////////////////////////////////
  logic unused_signals;
  assign unused_signals = ^{reg2hw.clear_state.q,
                            reg2hw.enabled_memory_range_base.qe,
                            reg2hw.enabled_memory_range_limit.qe,
                            sys_resp_q.error_vec,
                            sys_resp_q.read_metadata,
                            sys_resp_q.grant_vec[0]};

  //////////////////////////////////////////////////////////////////////////////
  // Assertions
  //////////////////////////////////////////////////////////////////////////////

  // All outputs should be known value after reset
  `ASSERT_KNOWN(AlertsKnown_A, alert_tx_o)

  // Alert assertions for reg_we onehot check
  `ASSERT_PRIM_REG_WE_ONEHOT_ERROR_TRIGGER_ALERT(RegWeOnehotCheck_A, u_dma_reg, alert_tx_o[0])

  // Handshake interrupt enable register must be expanded if there are more than 32 handshake
  // trigger wires
  `ASSERT_NEVER(LimitHandshakeTriggerWires_A, NumIntClearSources > 32)

  // The RTL code assumes the BE signal is 4-bit wide
  `ASSERT_NEVER(BeLengthMustBe4_A, top_pkg::TL_DBW != 4)

  `ASSERT_IF(RegsWritesInIdleOrErrorExceptAbort_A,
             (ctrl_state_q == DmaIdle) | (ctrl_state_q == DmaError),
             sw_reg_wr && (!cfg_abort_en))

  // The DMA enabled memory should not be changed after lock
  `ASSERT_NEVER(NoDmaEnabledMemoryChangeAfterLock_A,
                prim_mubi_pkg::mubi4_test_false_loose(
                  prim_mubi_pkg::mubi4_t'(reg2hw.range_regwen.q)) &&
                  (reg2hw.enabled_memory_range_base.qe ||
                   reg2hw.enabled_memory_range_limit.qe))
endmodule