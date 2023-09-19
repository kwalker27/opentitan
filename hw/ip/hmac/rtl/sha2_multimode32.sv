// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// 32-bit input wrapper for the SHA-2 multi-mode engine
//

module sha2_multimode32 import hmac_multimode_pkg::*; (
  input clk_i,
  input rst_ni,

  input              wipe_secret,
  input sha_word32_t wipe_v,

  // Control signals and message words input to the message FIFO
  input               fifo_rvalid,      // indicates that there are data words/word parts
                                        // fifo_rdata ready to write into the SHA-2 padding buffer
  input  sha_fifo32_t fifo_rdata,
  output logic        word_buffer_ready, // indicates that the wrapper word accumulation buffer is
                                         // ready to receive words to feed into the SHA-2 engine

  // Control signals
  input                sha_en,   // if disabled, it clears internal content
  input                hash_start,
  input digest_mode_e  digest_mode,
  input                hash_process,
  output logic         hash_done,

  input [127:0]             message_length,   // bits but byte based
  output sha_word64_t [7:0] digest,
  output logic              idle
);

  sha_fifo64_t  word_buffer_d, word_buffer_q;
  sha_fifo64_t  full_word;
  logic [1:0]   word_part_count;
  logic         word_part_inc, word_part_reset;
  logic         sha_process, catch_process, process_flag, reset_process;
  logic         word_valid, sha_ready;
  digest_mode_e digest_mode_flag;

  always_comb begin : accumulate_word
    word_part_inc                 = 1'b0;
    word_part_reset               = 1'b0;
    full_word.mask                = '1; // to keep the padding buffer ready to receive
    full_word.data                = '0;
    sha_process                   = 1'b0;
    catch_process                 = 1'b0;
    reset_process                 = 1'b0;
    word_valid                    = 1'b0;
    word_buffer_ready             = 1'b0;
    word_buffer_d                 = word_buffer_q;

    if (sha_en && fifo_rvalid) begin // valid incoming word part and SHA engine is enabled
      if (word_part_count == 2'b00) begin
        if (digest_mode_flag != SHA2_256) begin
          // accumulate most significant 32 bits of word and mask bits
          word_buffer_d.data[63:32] = fifo_rdata.data;
          word_buffer_d.mask[7:4] = fifo_rdata.mask;
          word_part_inc =  1'b1;
          word_buffer_ready = 1'b1;
        end else begin   // SHA2_256 so pad and push out the word if SHA engine is ready
          word_valid = 1'b1;
          // store the word with padding
          word_buffer_d.data = {32'b0, fifo_rdata.data};
          word_buffer_d.mask = {4'hF, fifo_rdata.mask}; // pad with all-1 byte mask
          // pad with all-zero data and all-one byte masking and push word out already for 256
          full_word.data =  {32'b0, fifo_rdata.data};
          full_word.mask = {4'hF, fifo_rdata.mask};
          if (sha_ready == 1'b1) begin
            // if word has been absorbed into hash engine
            word_buffer_ready = 1'b1; // word has been pushed out to SHA engine so word buffer ready
            if (hash_process || process_flag) begin
              sha_process = 1'b1;
              reset_process = 1'b1;
            end
          end else begin
            word_buffer_ready = 1'b0;
          end
        end
      end else if (word_part_count == 2'b01) begin
        word_buffer_ready = 1'b1; // buffer still has room for another word
        // accumulate least significant 32 bits and mask
        word_buffer_d.data [31:0] = fifo_rdata.data;
        word_buffer_d.mask [3:0] = fifo_rdata.mask;
        word_part_inc = 1'b1;
        // now ready to pass full word through
        word_valid = 1'b1;
        full_word.data [63:32] = word_buffer_q.data[63:32];
        full_word.mask [7:4]  = word_buffer_q.mask[7:4];
        full_word.data [31:0] = fifo_rdata.data;
        full_word.mask  [3:0] = fifo_rdata.mask;
        if (sha_ready == 1'b1) begin
          // word has been absorbed
          word_buffer_ready = 1'b1; // word has been pushed out to SHA engine so word buffer ready
          if (hash_process || process_flag) begin
            sha_process = 1'b1;
            reset_process = 1'b1;
          end
          word_part_reset = 1'b1;
          word_part_inc   = 1'b0;
        end else begin
          word_buffer_ready = 1'b1;
        end
      end else if (word_part_count == 2'b10) begin // word buffer is full and has not loaded out yet
        // word_buffer_ready is now deasserted: accumulated word is waiting to be pushed out
        word_buffer_ready = 1'b0;
        word_valid = 1'b1; // word buffer is ready to shift word out to SHA engine whenever ready
        full_word = word_buffer_q;
        if (sha_ready == 1'b1) begin // waiting on sha_ready to turn 1
          // do not assert word_buffer_ready yet
          if (hash_process || process_flag) begin
            sha_process = 1'b1;
            reset_process = 1'b1;
          end
          word_part_reset = 1'b1;
        end
      end
    end else if (sha_en && process_flag) begin // end of message (not byte-aligned)
      // no new valid input, provide the last latched input
      full_word = word_buffer_q;
    end

    // catch hash_process command until word is full and passed to SHA-2 engine
    if (hash_process) begin
      catch_process = 1'b1;
    end
  end

  // Instantiate 64-bit SHA-2 multi-mode engine
  sha2_multimode u_sha2_multimode64 (
    .clk_i (clk_i),
    .rst_ni (rst_ni),

    .wipe_secret      (wipe_secret),
    .wipe_v           ({wipe_v, wipe_v}),

    .fifo_rvalid      (word_valid),
    .fifo_rdata       (full_word),
    .fifo_rready      (sha_ready),

    .sha_en           (sha_en),
    .hash_start       (hash_start),
    .digest_mode      (digest_mode),
    .hash_process     (sha_process),
    .hash_done        (hash_done),

    .message_length   (message_length),
    .digest           (digest),

    .idle             (idle)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      word_part_count <= '0;
    end else if (word_part_inc) begin
      word_part_count <= word_part_count + 1'b1;
    end else if (word_part_reset) begin
      word_part_count <= '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
       word_buffer_q <= 0;
    end else begin
       word_buffer_q <= word_buffer_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      process_flag <= '0;
    end else if (catch_process) begin
      process_flag <= '1;
    end else if (reset_process) begin
      process_flag <= '0;
    end
  end

  // Latch SHA-2 configured mode
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      digest_mode_flag <= None;
    end else if (hash_start) begin
      digest_mode_flag <= digest_mode;
    end else if (hash_done == 1'b1) begin
      digest_mode_flag <= None;
    end
  end
endmodule : sha2_multimode32
