// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class dma_env_cfg extends cip_base_env_cfg #(.RAL_T(dma_reg_block));
  // TL Port Configuration
  tl_agent_cfg tl_agent_dma_host_cfg;
  tl_agent_cfg tl_agent_dma_ctn_cfg;
  tl_agent_cfg tl_agent_dma_sys_cfg;

  // Interface
  dma_vif               dma_vif;
  virtual clk_rst_if    clk_rst_vif;

  // Scoreboard
  dma_scoreboard        scoreboard_h;
  // Variable to indicate if any memory checks are in progress
  bit mem_check_in_progress;

  // Names of interfaces used in DMA block
  // These variables are used to store names of FIFO that are used
  // in scoreboard and environment
  string fifo_names[3];
  // Names of a_channel_fifo
  string dma_a_fifo[string];
  // Names of d_channel_fifo
  string dma_d_fifo[string];
  // Names of dir_channel_fifo
  string dma_dir_fifo[string];

  // For each TLUL interface declare a separate mem model
  // These sequences are used in TL device sequences
  // Data comparison is done in scoreboard
  mem_model mem_host;
  mem_model mem_ctn;
  mem_model #(.AddrWidth(SYS_ADDR_WIDTH), .DataWidth(SYS_DATA_WIDTH)) mem_sys;

  // Constraints
  //  TODO

  `uvm_object_utils_begin(dma_env_cfg)
    `uvm_field_object(tl_agent_dma_host_cfg, UVM_DEFAULT)
    `uvm_field_object(tl_agent_dma_ctn_cfg, UVM_DEFAULT)
    `uvm_field_object(tl_agent_dma_sys_cfg, UVM_DEFAULT)
  `uvm_object_utils_end
  `uvm_object_new

  // Function for Initialization
  virtual function void initialize(bit [31:0] csr_base_addr = '1);
    list_of_alerts = dma_env_pkg::LIST_OF_ALERTS;
    // Populate FIFO names
    fifo_names = '{"host", "ctn", "sys"};
    foreach (fifo_names[i]) begin
      dma_a_fifo[fifo_names[i]] = $sformatf("tl_a_%s_fifo", fifo_names[i]);
      dma_d_fifo[fifo_names[i]] = $sformatf("tl_d_%s_fifo", fifo_names[i]);
      dma_dir_fifo[fifo_names[i]] = $sformatf("tl_dir_%s_fifo", fifo_names[i]);
    end

    // Initialize cip_base_env_cfg
    super.initialize(csr_base_addr);

    // TL Agent Configuration objects - Non RAL
    `uvm_create_obj(tl_agent_cfg, tl_agent_dma_host_cfg)
    tl_agent_dma_host_cfg.max_outstanding_req = dma_env_pkg::NUM_MAX_OUTSTANDING_REQS;
    tl_agent_dma_host_cfg.if_mode = dv_utils_pkg::Device;

    `uvm_create_obj(tl_agent_cfg, tl_agent_dma_ctn_cfg)
    tl_agent_dma_ctn_cfg.max_outstanding_req = dma_env_pkg::NUM_MAX_OUTSTANDING_REQS;
    tl_agent_dma_ctn_cfg.if_mode = dv_utils_pkg::Device;

    `uvm_create_obj(tl_agent_cfg, tl_agent_dma_sys_cfg)
    tl_agent_dma_sys_cfg.max_outstanding_req = dma_env_pkg::NUM_MAX_OUTSTANDING_REQS;
    tl_agent_dma_sys_cfg.if_mode = dv_utils_pkg::Device;

    // TL Agent Configuration - RAL based
    m_tl_agent_cfg.max_outstanding_req = 1;

    // Create memory models
    `uvm_create_obj(mem_model, mem_host)
    `uvm_create_obj(mem_model, mem_ctn)
    mem_sys = mem_model#(.AddrWidth(SYS_ADDR_WIDTH), .DataWidth(SYS_DATA_WIDTH))::type_id::create(
      "mem_sys");
    // Initialize memory
    mem_host.init();
    mem_ctn.init();
    mem_sys.init();

  endfunction: initialize

endclass
