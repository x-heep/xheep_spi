// Copyright 2026 EPFL
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// This module contains the metadata for each of the cache ways.
// It is used to check a hit/miss, if the line is dirty and which line to replace
// if needed.
//
// The cache data lives in `cache.sv`.
//
// Author: Patrick Pataky     <patrick.pataky@epfl.ch>
//                            <patdb10@gmail.com>

module flash_llc_cache_way
  import flash_llc_cache_reg_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    cache_op_e active_op_i,
    logic [N_SETS_WIDTH-1:0] current_set_i,
    input [TAG_WIDTH-1:0] current_tag_i,
    input  logic                            request_dirty_i, // Only valid for WRITE, indicates whether the sector being written is dirty or clean
    input logic last_sector_word_i,

    output logic                            hit_o,
    output logic                            dirty_o,
    output logic [SECTOR_ADDRESS_WIDTH-1:0] victim_sector_o  // Only defined in case of miss
);

  logic [N_SETS-1:0] valid_q, valid_d;
  logic [N_SETS-1:0] dirty_q, dirty_d;
  logic [TAG_WIDTH-1:0] tags_q[N_SETS-1:0], tags_d[N_SETS-1:0];

  logic hit;

  assign hit = valid_q[current_set_i] & (tags_q[current_set_i] == current_tag_i);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= 'h0;
      dirty_q <= 'h0;

      for (int i = 0; i < N_SETS; i++) tags_q[i] <= 'h0;
    end else begin
      valid_q <= valid_d;
      dirty_q <= dirty_d;

      for (int i = 0; i < N_SETS; i++) tags_q[i] <= tags_d[i];
    end
  end

  always_comb begin
    valid_d = valid_q;
    dirty_d = dirty_q;

    for (int i = 0; i < N_SETS; i++) tags_d[i] = tags_q[i];

    unique case (active_op_i)
      CACHE_WRITE: begin
        // Sector is now fully in cache (valid), and may be dirty if it's a write
        if (last_sector_word_i) begin
          valid_d[current_set_i] = 1'b1;
          dirty_d[current_set_i] = request_dirty_i;
          tags_d[current_set_i]  = current_tag_i;
        end
      end

      CACHE_EVICT: begin
        // Sector is evicted (not valid)
        if (hit) begin
          valid_d[current_set_i] = 1'b0;
        end
      end

      default: ;
    endcase
  end

  assign hit_o = hit;
  assign dirty_o = dirty_q[current_set_i];
  assign victim_sector_o = {tags_q[current_set_i], current_set_i};

endmodule
