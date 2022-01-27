`include "common_cells/assertions.svh"

module soc_ctrl #(
    parameter type reg_req_t = logic,
    parameter type reg_rsp_t = logic
) (
  input           clk_i,
  input           rst_ni,

  // Bus Interface
  input  reg_req_t reg_req_i,
  output reg_rsp_t reg_rsp_o,

  output logic         tests_passed_o,
  output logic         tests_failed_o,
  output logic         exit_valid_o,
  output logic [31:0]  exit_value_o
);

  import soc_ctrl_reg_pkg::*;

  soc_ctrl_reg2hw_t reg2hw;

  soc_ctrl_reg_top #(
    .reg_req_t(reg_req_t),
    .reg_rsp_t(reg_rsp_t)
  ) soc_ctrl_reg_top_i (
    .clk_i,
    .rst_ni,
    .reg_req_i,
    .reg_rsp_o,
    .reg2hw,
    .devmode_i  (1'b1)
  );

  assign tests_passed_o = reg2hw.scratch_reg.q == 123456789;
  assign tests_failed_o = reg2hw.scratch_reg.q == 1;
  assign exit_valid_o   = reg2hw.exit_valid.q;
  assign exit_value_o   = reg2hw.exit_value.q;

endmodule : soc_ctrl