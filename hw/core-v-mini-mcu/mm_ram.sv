// Copyright 2017 Embecosm Limited <www.embecosm.com>
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// RAM and MM wrapper for RI5CY
// Contributor: Jeremy Bennett <jeremy.bennett@embecosm.com>
//              Robert Balas <balasr@student.ethz.ch>
//
// This maps the dp_ram module to the instruction and data ports of the RI5CY
// processor core and some pseudo peripherals

module mm_ram import obi_pkg::*; #(
    parameter NUM_BYTES = 2**16
) (
    input logic clk_i,
    input logic rst_ni,

    input  obi_req_t     core_instr_req_i,
    output obi_resp_t    core_instr_resp_o,

    input  obi_req_t     core_data_req_i,
    output obi_resp_t    core_data_resp_o,

    input logic [4:0]  irq_id_i,
    input logic        irq_ack_i,

    output logic        irq_software_o,
    output logic        irq_timer_o,
    output logic        irq_external_o,
    output logic [15:0] irq_fast_o,

    input logic [31:0] pc_core_id_i,

    output logic        tests_passed_o,
    output logic        tests_failed_o,
    output logic        exit_valid_o,
    output logic [31:0] exit_value_o
);

  localparam int TIMER_IRQ_ID = 7;
  localparam int IRQ_MAX_ID = 31;
  localparam int IRQ_MIN_ID = 26;

  localparam int NumWords  = NUM_BYTES/4;
  localparam int AddrWidth = $clog2(NUM_BYTES);

  typedef enum logic [1:0] {
    T_RAM,
    T_PER,
    T_ERR
  } transaction_t;
  transaction_t transaction, transaction_q;

  class rand_default_gnt;
    rand logic gnt;
  endclass : rand_default_gnt

  // signals for handshake
  logic data_rvalid_q;
  logic instr_rvalid_q;

  logic data_req_dec;
  logic [31:0] data_wdata_dec;
  logic [31:0] data_addr_dec;
  logic data_we_dec;
  logic [3:0] data_be_dec;

  logic [31:0] ram_instr_rdata;
  logic ram_instr_req;
  logic ram_instr_gnt;

  logic perip_gnt;

  // signals to print peripheral
  logic [31:0] print_wdata;
  logic print_valid;

  // signature data
  logic [31:0] sig_end_d, sig_end_q;
  logic [31:0] sig_begin_d, sig_begin_q;

  // signals to timer
  logic [31:0] timer_irq_mask_q;
  logic [31:0] timer_cnt_q;
  logic        irq_timer_q;
  logic        timer_reg_valid;
  logic        timer_val_valid;
  logic [31:0] timer_wdata;


  // IRQ related internal signals

  // struct irq_lines
  typedef struct packed {
    logic irq_software;
    logic irq_timer;
    logic irq_external;
    logic [15:0] irq_fast;
  } Interrupts_tb_t;

  Interrupts_tb_t irq_rnd_lines;

  // handle the mapping of read and writes to either memory or pseudo
  // peripherals (currently just a redirection of writes to stdout)
  always_comb begin
    tests_passed_o  = '0;
    tests_failed_o  = '0;
    exit_value_o    = 0;
    exit_valid_o    = '0;
    perip_gnt       = '0;
    data_req_dec    = '0;
    data_addr_dec   = '0;
    data_wdata_dec  = '0;
    data_we_dec     = '0;
    data_be_dec     = '0;
    print_wdata     = '0;
    print_valid     = '0;
    timer_wdata     = '0;
    timer_reg_valid = '0;
    timer_val_valid = '0;
    sig_end_d       = sig_end_q;
    sig_begin_d     = sig_begin_q;
    transaction     = T_PER;

    if (core_data_req_i.req) begin
      if (core_data_req_i.we) begin  // handle writes
        if (core_data_req_i.addr < 2 ** AddrWidth) begin  // TODO: fail here if requesting atop or smth?
          data_req_dec   = core_data_req_i.req;
          data_addr_dec  = core_data_req_i.addr;
          data_wdata_dec = core_data_req_i.wdata;
          data_we_dec    = core_data_req_i.we;
          data_be_dec    = core_data_req_i.be;
          transaction    = T_RAM;
        end else if (core_data_req_i.addr == 32'h1000_0000) begin
          print_wdata = core_data_req_i.wdata;
          print_valid = core_data_req_i.req;
          perip_gnt   = 1'b1;

        end else if (core_data_req_i.addr == 32'h2000_0000) begin
          if (core_data_req_i.wdata == 123456789) tests_passed_o = '1;
          else if (core_data_req_i.wdata == 1) tests_failed_o = '1;
          perip_gnt = 1'b1;

        end else if (core_data_req_i.addr == 32'h2000_0004) begin
          exit_valid_o = '1;
          exit_value_o = core_data_req_i.wdata;
          perip_gnt    = 1'b1;

        end else if (core_data_req_i.addr == 32'h2000_0008) begin
          // sets signature begin
          sig_begin_d = core_data_req_i.wdata;
          perip_gnt   = 1'b1;

        end else if (core_data_req_i.addr == 32'h2000_000C) begin
          // sets signature end
          sig_end_d = core_data_req_i.wdata;
          perip_gnt = 1'b1;

        end else if (core_data_req_i.addr == 32'h2000_0010) begin
          // halt and dump signature
`ifndef SYNTHESIS
          automatic string sig_file;
          automatic bit use_sig_file;
          automatic integer sig_fd;
          automatic integer errno;
          automatic string error_str;

          if ($value$plusargs("signature=%s", sig_file)) begin
            sig_fd = $fopen(sig_file, "w");
            if (sig_fd == 0) begin
  `ifndef VERILATOR
              errno = $ferror(sig_fd, error_str);
              $error(error_str);
  `else
              $error("can't open file");
  `endif
              use_sig_file = 1'b0;
            end else begin
              use_sig_file = 1'b1;
            end
          end

          $display("Dumping signature");
          for (logic [31:0] addr = sig_begin_q; addr < sig_end_q; addr += 4) begin
            $display("%x%x%x%x", ram1_i.tc_ram_i.sram[addr+3], ram1_i.tc_ram_i.sram[addr+2], ram1_i.tc_ram_i.sram[addr+1],
                     ram1_i.tc_ram_i.sram[addr+0]);
            if (use_sig_file) begin
              $fdisplay(sig_fd, "%x%x%x%x", ram1_i.tc_ram_i.sram[addr+3], ram1_i.tc_ram_i.sram[addr+2],
                        ram1_i.tc_ram_i.sram[addr+1], ram1_i.tc_ram_i.sram[addr+0]);
            end
          end
`endif
          // end simulation
          exit_valid_o = '1;
          exit_value_o = '0;
          perip_gnt    = 1'b1;

        end else if (core_data_req_i.addr == 32'h1500_0000) begin
          timer_wdata = core_data_req_i.wdata;
          timer_reg_valid = '1;
          perip_gnt    = 1'b1;

        end else if (core_data_req_i.addr == 32'h1500_0004) begin
          timer_wdata = core_data_req_i.wdata;
          timer_val_valid = '1;
          perip_gnt = 1'b1;

        end else begin
          // out of bounds write
        end

      end else begin  // handle reads
        if (core_data_req_i.addr < 2 ** AddrWidth) begin
          data_req_dec   = core_data_req_i.req;
          data_addr_dec  = core_data_req_i.addr;
          data_wdata_dec = core_data_req_i.wdata;
          data_we_dec    = core_data_req_i.we;
          data_be_dec    = core_data_req_i.be;
          transaction    = T_RAM;
        end else if (core_data_req_i.addr[31:00] == 32'h1500_1000) begin
          transaction = T_PER;
          perip_gnt   = 1'b1;
        end else transaction = T_ERR;
      end
    end
  end

`ifndef SYNTHESIS
`ifndef VERILATOR
  // signal out of bound writes
  out_of_bounds_write :
  assert property
    (@(posedge clk_i) disable iff (~rst_ni)
     (core_data_req_i.req && core_data_req_i.we |-> core_data_req_i.addr < 2 ** AddrWidth
      || core_data_req_i.addr == 32'h1000_0000
      || core_data_req_i.addr == 32'h1500_0000
      || core_data_req_i.addr == 32'h1500_0004
      || core_data_req_i.addr == 32'h2000_0000
      || core_data_req_i.addr == 32'h2000_0004
      || core_data_req_i.addr == 32'h2000_0008
      || core_data_req_i.addr == 32'h2000_000c
      || core_data_req_i.addr == 32'h2000_0010
      || core_data_req_i.addr[31:16] == 16'h1600))
  else $fatal("out of bounds write to %08x with %08x", core_data_req_i.addr, core_data_req_i.wdata);
`endif

  // make sure we select the proper read data
  always_comb begin : read_mux
    if (transaction_q == T_ERR) begin
      $display("out of bounds read from %08x", core_data_req_i.addr);
      $fatal(2);
    end
  end

  // print to stdout pseudo peripheral
  always_ff @(posedge clk_i, negedge rst_ni) begin : print_peripheral
    if (print_valid) begin
      if ($test$plusargs("verbose")) begin
        if (32 <= print_wdata && print_wdata < 128) $display("OUT: '%c'", print_wdata[7:0]);
        else $display("OUT: %3d", print_wdata);

      end else begin
        $write("%c", print_wdata[7:0]);
`ifndef VERILATOR
        $fflush();
`endif
      end
    end
  end

`endif

  // Control timer. We need one to have some kind of timeout for tests that
  // get stuck in some loop. The riscv-tests also mandate that. Enable timer
  // interrupt by writing 1 to timer_irq_mask_q. Write initial value to
  // timer_cnt_q which gets counted down each cycle. When it transitions from
  // 1 to 0, and interrupt request (irq_q) is made (masked by timer_irq_mask_q).
  always_ff @(posedge clk_i, negedge rst_ni) begin : tb_timer
    if (~rst_ni) begin
      timer_irq_mask_q <= '0;
      timer_cnt_q      <= '0;
      irq_timer_q      <= '0;
    end else begin
      // set timer irq mask
      if (timer_reg_valid) begin
        timer_irq_mask_q <= timer_wdata;

        // write timer value
      end else if (timer_val_valid) begin
        timer_cnt_q <= timer_wdata;

      end else begin
        if (timer_cnt_q > 0) timer_cnt_q <= timer_cnt_q - 1;

        if (timer_cnt_q == 1) irq_timer_q <= 1'b1 && timer_irq_mask_q[TIMER_IRQ_ID];

        if (irq_ack_i == 1'b1 && irq_id_i == TIMER_IRQ_ID) irq_timer_q <= '0;

      end
    end
  end

`ifndef SYNTHESIS
  // show writes if requested
  always_ff @(posedge clk_i, negedge rst_ni) begin : verbose_writes
    if ($test$plusargs("verbose") && core_data_req_i.req && core_data_req_i.we)
      $display("write addr=0x%08x: data=0x%08x", core_data_req_i.addr, core_data_req_i.wdata);
  end
`endif

  sram_wrapper #(
    .NumWords(NumWords/2),
    .DataWidth(32'd32)
  ) ram0_i (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .req_i  (core_instr_req_i.req),
    .we_i   (1'b0),
    .addr_i (core_instr_req_i.addr[AddrWidth-1-1:2]),
    .wdata_i('0),
    .be_i   (4'b1111),
    // output ports
    .rdata_o(core_instr_resp_o.rdata)
  );


  //8Kwords per bank (32KB)
  sram_wrapper #(
    .NumWords(NumWords/2),
    .DataWidth(32'd32)
  ) ram1_i (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .req_i  (data_req_dec),
    .we_i   (data_we_dec),
    .addr_i (data_addr_dec[AddrWidth-1-1:2]),
    .wdata_i(data_wdata_dec),
    .be_i   (data_be_dec),
    // output ports
    .rdata_o(core_data_resp_o.rdata)
  );




  assign core_instr_resp_o.gnt = core_instr_req_i.req;
  assign core_data_resp_o.gnt  = data_req_dec | perip_gnt;

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (~rst_ni) begin
      data_rvalid_q  <= '0;
      instr_rvalid_q <= '0;
    end else begin
      data_rvalid_q  <= core_data_resp_o.gnt;
      instr_rvalid_q <= core_instr_resp_o.gnt;
    end
  end

  assign core_instr_resp_o.rvalid   = instr_rvalid_q;
  assign core_data_resp_o.rvalid    = data_rvalid_q;

  // signature range
  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (~rst_ni) begin
      sig_end_q   <= '0;
      sig_begin_q <= '0;
    end else begin
      sig_end_q   <= sig_end_d;
      sig_begin_q <= sig_begin_d;
    end
  end

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (~rst_ni) begin
      transaction_q <= T_RAM;
    end else begin
      transaction_q <= transaction;
    end
  end


  // IRQ SIGNALS ROUTING
  assign irq_software_o = '0;
  assign irq_timer_o    = '0;
  assign irq_external_o = '0;
  assign irq_fast_o     = '0;


endmodule  // ram
