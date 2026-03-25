/*
 
  axi_to_flash_controller.sv
  Hardware controller for W25Q128JW flash memory , request set by axi interface rather than software.
 
  Uses a local scratchpad memory as sector buffer and a fifo as queue write beats, 
  former connected directly to spi_host's data fifos to perform data transfers without CPU or DMA intervention (RAM access is avoided).

  axi_burst = INC always
 
  Author : Alessandro Barocci
 
  Based on XHEEP's w25q128jw_controller.sv

  TODO : add more blank space in the FSM
  TODO : add some comments from original w25q128jw_controller ? Improve readability
  TODO : between first and second sector write of the single beat might not be required to FWAIT , maybe even between beats
  TODO : correct code to avioid WIDTH warnings, allowing waiver file reduction.

  TODO : at last, remove verilator scope signals in tc_sram (and also spiflash)

  // CRITICAL //
  TODO : why do we access registers @ SPI_HOST_COMMAND_OFFSET when we modify the rxwm rather than SPI_HOST_CONTROL_OFFSET ?
  << CORRECTED >>

  TODO : probably should use direct access to spi_host_hw2reg.status.rxwm rather than sampled with register interface
  << CORRECTED >>

  TODO : NO POWERUP ?!?!?!?!?!?
  << FORCED AT 1 IN SPI_FLASH >>

  // MORE CHANGES //
  1) dual and quad spi support (thus dummy cycles) (register cfg + states)

 */
 
module axi_to_flash_controller
  import core_v_mini_mcu_pkg::*;
  import spi_host_reg_pkg::*;
#(

  localparam int MaxBeats = 17,
  localparam int MaxBeatsDW = sizeInBits(MaxBeats+1),
  localparam int SE_PSIZE = 32'(SE_WSIZE) / 32'(PAGE_WSIZE),
  localparam int PageCountDW = sizeInBits(SE_PSIZE+1),
  localparam int SectorBufferLatency = 1,
  localparam int SecBuffLatencyDW = sizeInBits(SectorBufferLatency+1),
  localparam int ClockFrequencyMAX_kHz = 1e6,
  localparam int w25q128jw_tPUW_ms = 5, // 5ms , from datasheet
  localparam int PowerOnWaitCycles = ClockFrequencyMAX_kHz * w25q128jw_tPUW_ms,
  localparam int PoweronWaitCycles_SIM = 10,
  localparam int PowerOnWaitCyclesDW = sizeInBits(PowerOnWaitCycles+1),
  parameter logic ByteOrder = 1, // 1 == Little Endian , 0 == Big Endian  ; @ 0 , beat_queues swap bytes.
  parameter int AddrWidth = 64,
  parameter int FlashAddrW = 24,
  parameter int DataWidth = 64,
  parameter int DataBytes = DataWidth/8,
  parameter int RegDataWidth = 32,
  parameter type axi_req_t = logic,
  parameter type axi_resp_t = logic,
  parameter type reg_req_t = logic,
  parameter type reg_rsp_t = logic
)(
  input logic clk_i,
  input logic rst_ni,

  // Enable by xspi register
  input logic en_i,

  // Master ports to the SPI HOST
  output reg_req_t spi_host_reg_req_o,
  input  reg_rsp_t spi_host_reg_rsp_i,

  // SPI HW register
  input spi_host_reg_pkg::spi_host_hw2reg_status_reg_t external_spi_host_hw2reg_status_i,

  // Axi interface
  input  axi_req_t  axi_req_i,
  output axi_resp_t axi_rsp_o
  /*
  References:
  https://github.com/pulp-platform/axi/blob/master/include/axi/typedef.svh
  https://github.com/pulp-platform/axi/blob/master/src/axi_pkg.sv
  https://github.com/pulp-platform/axi/blob/master/src/axi_to_detailed_mem.sv
  */
);

  // // AXI interface renaming
  localparam int lenDW = 8;
  localparam int sizeDW = 3;
  localparam int burstDW = 2;
  localparam int respDW = 2;
  logic [AddrWidth-1:0]     aw_addr;
  logic [sizeDW-1:0]        aw_size;
  logic [lenDW-1:0]         aw_len;
  logic                     aw_valid;
  logic                     aw_ready;
  // AXI - Write Data Channel
  logic [DataWidth-1:0]     w_data;
  logic [DataBytes-1:0]     w_strb;
  logic                     w_last;
  logic                     w_valid;
  logic                     w_ready;
  // AXI - Response Channel
  logic                     b_valid;
  logic                     b_ready;
  // AXI - Read Address Channel
  logic [AddrWidth-1:0]     ar_addr;
  logic [sizeDW-1:0]        ar_size;
  logic [lenDW-1:0]         ar_len;
  logic                     ar_valid;
  logic                     ar_ready;
  // AXI - Read Data Channel
  logic [DataWidth-1:0]     r_data;
  logic                     r_last;
  logic                     r_valid;
  logic                     r_ready;
  // assignments
  always_comb begin
    aw_addr  = axi_req_i.aw.addr;
    aw_size  = axi_req_i.aw.size;
    aw_len   = axi_req_i.aw.len;
    aw_valid = axi_req_i.aw_valid;
    w_data   = axi_req_i.w.data;
    w_strb   = axi_req_i.w.strb;
    w_last   = axi_req_i.w.last;
    w_valid  = axi_req_i.w_valid;
    b_ready  = axi_req_i.b_ready;
    ar_addr  = axi_req_i.ar.addr;
    ar_size  = axi_req_i.ar.size;
    ar_len   = axi_req_i.ar.len;
    ar_valid = axi_req_i.ar_valid;
    r_ready  = axi_req_i.r_ready;

    axi_rsp_o.aw_ready = aw_ready;
    axi_rsp_o.w_ready  = w_ready;
    axi_rsp_o.b_valid  = b_valid;
    axi_rsp_o.ar_ready = ar_ready;
    axi_rsp_o.r.data   = r_data;
    axi_rsp_o.r.last   = r_last;
    axi_rsp_o.r_valid  = r_valid;
  end

  // // Assert data width flag
  logic [DataWidth-1:0] A;
  logic datawidth_is_64_n32;
  always_comb begin
    A[DataWidth-1] = '1;
    A = A >> 32;
    datawidth_is_64_n32 = A[0];
  end

  // // Local parameters
  localparam int SPI_FLASH_TX_FIFO_DEPTH = spi_host_reg_pkg::TxDepth;
  // Flash commands
  localparam logic [12:0] FC_RD = 13'h03,  // Read Data
  FC_PO = 13'hab,   // Power On
  FC_RSR1 = 13'h05,  // Read Status Register 1
  FC_WE = 13'h06,  // Write Enable
  FC_SE = 13'h20,  // Sector Erase 4KB
  FC_PP = 13'h02,  // Page Program
  // W25Q128JW size constants
  SE_WSIZE = 13'h400,  // Sector size in words
  SE_BSIZE = 13'h1000,  // Sector size in bytes
  PAGE_WSIZE = 13'h40,  // Page size in words
  PAGE_BSIZE = 13'h100;  // Page size in bytes
  localparam int SE_WSIZE_DW = sizeInBits(32'(SE_WSIZE+1));

  // Byte swap function
  function automatic [31:0] bitfield_byteswap32(input [31:0] adress_to_swap);
    bitfield_byteswap32 = {
      adress_to_swap[7:0],  // Byte 0 -> Byte 3
      adress_to_swap[15:8],  // Byte 1 -> Byte 2
      adress_to_swap[23:16],  // Byte 2 -> Byte 1
      adress_to_swap[31:24]  // Byte 3 -> Byte 0
    };
  endfunction

  // Size computation in bits function
  function automatic int sizeInBits (input int value);
    int i;
    if (value > 1) begin
      begin
        value = value - 1;
        for (i = 0; value > 0; i = i + 1)
          value = value >> 1;
        return i;
      end
    end else return 1;
  endfunction

  // // // SFM
  // // TOP SFM state definition
  // Top controller FSM
  typedef enum logic [sizeInBits(9)-1:0] {
    TOP_IDLE,     // Wait for valid AXI request
    TOP_AXIREQ,   // Memorize data from AXI master channels , spi_host_data_fifos is cleared
    TOP_POWERON,  // Issue the power-on command to the flash and wait cycles before operating
    TOP_READ,     // Read beats from flash to beat queue or sector to sector buffer , beat queues are cleared
    TOP_FWAIT,    // Wait for flash internal operation
    TOP_ERASE,    // Erase flash sector
    TOP_MODIFY,   // Modify sector buffer with AXI beat to write-back to flash
    TOP_WRITE,    // Page program the sector in the flash with sector buffer content
    TOP_AXIRESP   // Respond to AXI master
  } top_state_e;
  // // AXI REQUEST SFM state definition
  // Handles AXI request
  typedef enum logic [sizeInBits(5)-1:0] {
    AXIREQ_IDLE,       // Clear beat queues
    AXIREQ_AR,         // Answer to AR channel request
    AXIREQ_AW,         // Answer to AW channel request
    AXIREQ_W           // Answer to W channel request
  } axireq_state_e;
  // // POWER ON SFM state definition
  // Sends the power on command to the flash. Executed after AXIREQ if it hasn't been done before since reset.
  typedef enum logic [sizeInBits(6)-1:0] {
    POWERON_IDLE,                 
    POWERON_SPI_CHECK_TX_FIFO,    // Check whether tx_fifo has room
    POWERON_SPI_FILL_TX_FIFO,     // Write power-on command into tx_fifo (FC_PO)
    POWERON_SPI_WAIT_READY,       // Wait for spi_host to be ready
    POWERON_SPI_SEND_CMD,         // Send power-on flash write command to spi_host
    POWERON_WAIT_CYCLES           // Wait cycles before normal operation
  } poweron_state_e;
  // // READ SFM state definition
  // Handles flash read operation
  typedef enum logic [sizeInBits(16)-1:0] {
    READ_IDLE,
    READ_INIT,               // define some parameters for following operations
    READ_SET_RXWM_R,         // Read spi_host command
    READ_SET_RXWM_W,         // Rewrite the command with rx_fifo watermark set to 1, to be immediately warned when one word arrives
    READ_SPI_CHECK_TX_FIFO,  // Check whether tx_fifo has room
    READ_SPI_FILL_TX_FIFO,   // Write read command (FC_RD) + address to tx_fifo
    READ_SPI_WAIT_READY_1,   // Wait for spi_host to be ready
    READ_SPI_SEND_CMD_1,     // Send address write command to spi_host
    READ_SPI_WAIT_READY_2,   // Wait for spi_host to be ready
    READ_SPI_SEND_CMD_2,     // Send read command to spi_host
    READ_WAIT_RXWM,          // Check whether data is present in rx_fifo
    READ_W_SECTOR_STORE,     // Store the beat's sector inside the local sector buffer, word by word
    READ_R_BEAT_PUSH_DW32,   // Store current beat inside local buffer (32 bit case)
    READ_R_BEAT_PUSH_DW64_1, // Store current beat inside local buffer (64 bit case) (1 of 2)
    READ_R_BEAT_PUSH_DW64_2, // Store current beat inside local buffer (64 bit case) (2 of 2)  
    READ_R_BEAT_PUSH_FIN     // Store current beat inside rd_beat_queue
  } read_state_e;           
  // // FLASH WAIT SFM state definition
  // Waits for flash internal operations to complete (erase/program)
  // by polling the flash status register (Read Status Register 1) (Not necessary in simulation)
  typedef enum logic [sizeInBits(11)-1:0] {
    FWAIT_IDLE,
    FWAIT_SET_RXWM_R,         // Read current RX watermark setting (within SPI Host Control Register)
    FWAIT_SET_RXWM_W,         // Set RX watermark to 1 (for single word read: flash status register 1)
    FWAIT_SPI_CHECK_TX_FIFO,  // Check if TX FIFO has space
    FWAIT_SPI_FILL_TX_FIFO,   // Write Read Status Register 1 command (FC_RSR1)
    FWAIT_SPI_WAIT_READY_1,   // Wait for SPI Host ready
    FWAIT_SPI_SEND_CMD_1,     // Send FC_RSR1 command
    FWAIT_SPI_WAIT_READY_2,   // Wait for SPI Host ready
    FWAIT_SPI_SEND_CMD_2,     // Send command for flash to send status byte
    FWAIT_WAIT_RXWM,          // Wait for RX watermark to be passed (status byte received)
    FWAIT_READ_FLASH_STATUS   // Read status byte and check BUSY bit (bit 0). If busy then repeat process, else redirect to correct FSM/complete operation
  } fwait_state_e;
  // // ERASE FSM state definition
  // Erases a 4KB sector before writing new data
  // Sequence: Write Enable (WE) -> Sector Erase (SE)
  typedef enum logic [sizeInBits(9)-1:0] {
    ERASE_IDLE,              // Idle state (simply redirects to WE and SE sequences)
    // Write Enable command sequence (required before any write/erase)
    ERASE_WE_CHECK_TX_FIFO,  // Check if TX FIFO has space
    ERASE_WE_FILL_TX_FIFO,   // Write Write Enable command (FC_WE)
    ERASE_WE_WAIT_READY,     // Wait for SPI Host ready
    ERASE_WE_SEND_CMD,       // Send Write Enable command
    // Sector Erase command sequence
    ERASE_SE_CHECK_TX_FIFO,  // Check if TX FIFO has space
    ERASE_SE_FILL_TX_FIFO,   // Write Sector Erase command + address (FC_SE)
    ERASE_SE_WAIT_READY,     // Wait for SPI Host ready
    ERASE_SE_SEND_CMD        // Send Sector Erase command
  } erase_state_e;
  // // MODIFY SFM state definition
  // Copies new write beat data into the sector buffer
  typedef enum logic [sizeInBits(7)-1:0] {
    MODIFY_IDLE,
    MODIFY_BEAT_POP,              // pop write beat from wr_beat_queue
    MODIFY_SECTOR_UPDATE_DW32_1,  // update sector with new data (32 bit case) (1 of 2)
    MODIFY_SECTOR_UPDATE_DW32_2,  // update sector with new data (32 bit case) (2 of 2)
    MODIFY_SECTOR_UPDATE_DW64_1,  // update sector with new data (64 bit case) (1 of 3)
    MODIFY_SECTOR_UPDATE_DW64_2,  // update sector with new data (64 bit case) (2 of 3)
    MODIFY_SECTOR_UPDATE_DW64_3   // update sector with new data (64 bit case) (3 of 3)
  } modify_state_e;
  // WRITE SFM state definition
  // Programs sector buffer into flash, page by page (256 bytes per page , 64 words, 16 pages in total in a sector)
  typedef enum logic [sizeInBits(14)-1:0] {
    WRITE_IDLE,
    // Write Enable command sequence (required before each page program)
    WRITE_WE_CHECK_TX_FIFO,  // Check if TX FIFO has space
    WRITE_WE_FILL_TX_FIFO,   // Write Write Enable command (FC_WE)
    WRITE_WE_WAIT_READY,     // Wait for SPI Host ready
    WRITE_WE_SEND_CMD,       // Send Write Enable command
    // Page Program command sequence
    WRITE_PP_CHECK_TX_FIFO,  // Check if TX FIFO has space
    WRITE_PP_FILL_TX_FIFO,   // Write Page Program command + address (FC_PP)
    WRITE_PP_WAIT_READY,     // Wait for SPI Host ready
    WRITE_PP_SEND_CMD,       // Send Page Program command
    // Page data write
    WRITE_PP_PAGE_WRITE_1,   // Send read request to sector buffer
    WRITE_PP_PAGE_WRITE_2,   // Save read 32 bit data into buffer
    WRITE_PP_PAGE_WRITE_3,   // Check whether tx_fifo has room
    WRITE_PP_PAGE_WRITE_4,   // Store 32 bit data in tx_fifo
    // Finalize page write
    WRITE_PP_WAIT_READY_2,   // Wait for SPI Host ready
    WRITE_PP_SEND_CMD_2      // Send final command to release CS (ends page program) 
    //and redirect depending on number of pages programmed and if more sectors need to be written
  } write_state_e;
  // // AXI RESPONSE state definition
  // Handles AXI Repsonse
  typedef enum logic [sizeInBits(3)-1:0] {
    AXIRESP_IDLE,
    AXIRESP_B,         // Make response in B channel
    AXIRESP_R          // Make response in R channel
  } axiresp_state_e;

  // // Signals definition
  // FSM states
  top_state_e     top_state_q     , top_state_d;
  axireq_state_e  axireq_state_q  , axireq_state_d;
  poweron_state_e poweron_state_q , poweron_state_d;
  read_state_e    read_state_q    , read_state_d;
  erase_state_e   erase_state_q   , erase_state_d;
  fwait_state_e   fwait_state_q   , fwait_state_d;
  modify_state_e  modify_state_q  , modify_state_d;
  write_state_e   write_state_q   , write_state_d;
  axiresp_state_e axiresp_state_q , axiresp_state_d;
  // Registers and counters
  logic [MaxBeatsDW-1:0]             beat_count_q           , beat_count_d;
  logic [AddrWidth-1:0]              beat_addr_q            , beat_addr_d;
  logic [AddrWidth-1:0]              first_beat_addr_q      , first_beat_addr_d;
  logic [MaxBeatsDW-1:0]             beat_number_q          , beat_number_d;
  logic [DataBytes-1:0]              beat_size_q            , beat_size_d;
  logic                              rnw_q                  , rnw_d;
  logic [PowerOnWaitCyclesDW-1:0]    poweron_wait_count_q   , poweron_wait_count_d;
  logic                              flash_is_on_q          , flash_is_on_d;
  logic [FlashAddrW-1:0]             flash_addr_q           , flash_addr_d;
  logic                              first_sector_write_q   , first_sector_write_d;
  logic                              second_sector_write_q  , second_sector_write_d;
  logic [RegDataWidth-1:0]           spi_host_command_q     , spi_host_command_d;
  logic                              beat_half_index_q      , beat_half_index_d;
  logic [SE_WSIZE_DW-1:0]            word_count_q           , word_count_d;
  logic [DataWidth-1:0]              rd_queue_buffer_q      , rd_queue_buffer_d;
  logic [DataWidth-1:0]              wr_queue_buffer_data_q , wr_queue_buffer_data_d;
  logic [DataBytes-1:0]              wr_queue_buffer_be_q   , wr_queue_buffer_be_d;  
  logic [1:0]                        fwait_cnt_q            , fwait_cnt_d;
  logic [PageCountDW-1:0]            page_count_q           , page_count_d;
  logic [SecBuffLatencyDW-1:0]       wait_latency_count_q   , wait_latency_count_d;
  logic [SectorBuffer_DataWidth-1:0] sec_buf_buffer_q       , sec_buf_buffer_d;

  // First and second halves of wr_queue_buffer , used for beat write from wr_beat_queue and sector_buffer @ 64 bits
  logic [DataWidth/2-1:0] wr_queue_buffer_data_LSH , wr_queue_buffer_data_MSH;
  logic [DataBytes/2-1:0] wr_queue_buffer_be_LSH , wr_queue_buffer_be_MSH;
  always_comb begin
    wr_queue_buffer_data_LSH = wr_queue_buffer_data_q[DataWidth/2-1:0];
    wr_queue_buffer_data_MSH = wr_queue_buffer_data_q[DataWidth-1:DataWidth/2];
    wr_queue_buffer_be_LSH = wr_queue_buffer_be_q[DataBytes/2-1:0];
    wr_queue_buffer_be_MSH = wr_queue_buffer_be_q[DataBytes-1:DataBytes/2];
  end

  // // // FSM sequential logic
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // // Reset
      // States
      top_state_q     <= TOP_IDLE;
      axireq_state_q  <= AXIREQ_IDLE;
      poweron_state_q <= POWERON_IDLE;
      read_state_q    <= READ_IDLE;
      erase_state_q   <= ERASE_IDLE;
      fwait_state_q   <= FWAIT_IDLE;
      modify_state_q  <= MODIFY_IDLE;
      write_state_q   <= WRITE_IDLE;
      axiresp_state_q <= AXIRESP_IDLE;
      // Registers and counters
      beat_count_q           <= '0;
      beat_addr_q            <= '0;
      first_beat_addr_q      <= '0;
      beat_number_q          <= '0;
      beat_size_q            <= '0;
      rnw_q                  <= '0;
      poweron_wait_count_q   <= '0;
      flash_is_on_q          <= '0;
      flash_addr_q           <= '0;
      first_sector_write_q   <= '0;
      second_sector_write_q  <= '0;
      spi_host_command_q     <= '0;
      beat_half_index_q      <= '0;
      word_count_q           <= '0;
      rd_queue_buffer_q      <= '0;
      wr_queue_buffer_data_q <= '0;
      wr_queue_buffer_be_q   <= '0;
      fwait_cnt_q            <= '0;
      page_count_q           <= '0;
      wait_latency_count_q   <= '0;
      sec_buf_buffer_q       <= '0;
    end else begin
      // // Sampling
      // States
      top_state_q            <= top_state_d;
      axireq_state_q         <= axireq_state_d;
      poweron_state_q        <= poweron_state_d;
      read_state_q           <= read_state_d;
      erase_state_q          <= erase_state_d;
      fwait_state_q          <= fwait_state_d;
      modify_state_q         <= modify_state_d;
      write_state_q          <= write_state_d;
      axiresp_state_q        <= axiresp_state_d;
      // Registers and counters
      beat_count_q           <= beat_count_d;
      beat_addr_q            <= beat_addr_d;
      first_beat_addr_q      <= first_beat_addr_d;
      beat_number_q          <= beat_number_d;
      beat_size_q            <= beat_size_d;
      rnw_q                  <= rnw_d;
      poweron_wait_count_q   <= poweron_wait_count_d;
      flash_is_on_q          <= flash_is_on_d;
      flash_addr_q           <= flash_addr_d;
      first_sector_write_q   <= first_sector_write_d;
      second_sector_write_q  <= second_sector_write_d;
      spi_host_command_q     <= spi_host_command_d;
      beat_half_index_q      <= beat_half_index_d;
      word_count_q           <= word_count_d;
      rd_queue_buffer_q      <= rd_queue_buffer_d;
      wr_queue_buffer_data_q <= wr_queue_buffer_data_d;
      wr_queue_buffer_be_q   <= wr_queue_buffer_be_d;  
      fwait_cnt_q            <= fwait_cnt_d;
      page_count_q           <= page_count_d;
      wait_latency_count_q   <= wait_latency_count_d;
      sec_buf_buffer_q       <= sec_buf_buffer_d;    
    end
  end

  // reg_req.addr to spi_host definition : only the offset changes
  logic [spi_host_reg_pkg::BlockAw-1:0] spi_host_reg_req_offset;
  assign spi_host_reg_req_o.addr = core_v_mini_mcu_pkg::SPI_FLASH_START_ADDRESS + {{(64 - spi_host_reg_pkg::BlockAw){1'b0}}, spi_host_reg_req_offset};

// to shorten the simulation and to allow a smaller watchdog in the testbench, reduce the number of cycles waited inside the power-on rutine
int actual_poweron_wait_cycles;
`ifndef FPGA_SYNTHESIS
`ifndef SYNTHESIS
  assign actual_poweron_wait_cycles = PoweronWaitCycles_SIM;
`else
  assign actual_poweron_wait_cycles = PoweronWaitCycles;
`endif
`else
  assign actual_poweron_wait_cycles = PoweronWaitCycles;
`endif


  // // SFM flow : 
  //   - Read  (rnw=1): TOP_IDLE -> TOP_AXIREQ -> TOP_READ -> TOP_AXIRESP -> TOP_IDLE
  //   - Write (rnw=0): TOP_IDLE -> TOP_AXIREQ -> TOP_READ -> TOP_FWAIT -> TOP_ERASE -> TOP_FWAIT -> 
  //                    TOP_MODIFY -> TOP_WRITE -> TOP_FWAIT -> TOP_AXIRESP -> TOP_IDLE

  // // // FSM combinational logic
  always_comb begin
    // // default values
    // States
    top_state_d     = top_state_q;
    axireq_state_d  = axireq_state_q;
    poweron_state_d = poweron_state_q;
    read_state_d    = read_state_q;
    erase_state_d   = erase_state_q;
    fwait_state_d   = fwait_state_q;
    modify_state_d  = modify_state_q;
    write_state_d   = write_state_q;
    axiresp_state_d = axiresp_state_q;
    // Registers
    beat_count_d           = beat_count_q;
    beat_addr_d            = beat_addr_q;
    first_beat_addr_d      = first_beat_addr_q;
    beat_number_d          = beat_number_q;
    beat_size_d            = beat_size_q;
    rnw_d                  = rnw_q;
    poweron_wait_count_d   = poweron_wait_count_q;
    flash_is_on_d          = flash_is_on_q;
    flash_addr_d           = flash_addr_q;
    first_sector_write_d   = first_sector_write_q;
    second_sector_write_d  = second_sector_write_q;
    spi_host_command_d     = spi_host_command_q;
    beat_half_index_d      = beat_half_index_q;
    word_count_d           = word_count_q;
    rd_queue_buffer_d      = rd_queue_buffer_q;
    wr_queue_buffer_data_d = wr_queue_buffer_data_q;
    wr_queue_buffer_be_d   = wr_queue_buffer_be_q; 
    fwait_cnt_d            = fwait_cnt_q;
    page_count_d           = page_count_q;
    wait_latency_count_d   = wait_latency_count_q;
    sec_buf_buffer_d       = sec_buf_buffer_q;
    // AXI
    ar_ready = 1'b0;
    aw_ready = 1'b0;
    w_ready = 1'b0;
    b_valid = 1'b0;
    r_valid = 1'b0;
    r_last = 1'b0;
    r_data = '0;
    // Queues
    axi2fls_wr_valid = '0;
    axi2fls_wr_data = '0;
    axi2fls_wr_be = '0;
    spihost_wr_ready = '0;
    spihost_rd_valid = '0;
    spihost_rd_data = '0;
    clear_queues = '0;
    // Sector buffer
    sect_buffer_req = 1'b0;
    sect_buffer_we = 1'b0;
    sect_buffer_addr = '0;
    sect_buffer_wdata ='0;
    sect_buffer_be = 4'b0000;
    // spi_host Register interface
    spi_host_reg_req_o.valid = 1'b0;
    spi_host_reg_req_o.wstrb = 4'b1111;
    spi_host_reg_req_o.write = 1'b0;
    spi_host_reg_req_o.wdata = '0;
    spi_host_reg_req_offset  = '0;

    // // TOP SFM
    case (top_state_q)
      TOP_IDLE: begin
        // Wait for a valid request from any AXI channel
        // Next state evaluation
        if (en_i) begin
          if ( (aw_valid && w_valid) || ar_valid ) begin
            top_state_d = TOP_AXIREQ;
            axireq_state_d = AXIREQ_IDLE;
          end
        end
      end
      // // AXIREQ SFM
      // respond to axi request and recieve transaction attributes
      // WRITE : store data in wr_beat_queue
      TOP_AXIREQ: begin
        case(axireq_state_q)
          AXIREQ_IDLE: begin
            // Clear the beat queues
            clear_queues = 1'b1;
            // Reset beat counter
            beat_count_d = 0;
            // Next state evaluation
            if (aw_valid && w_valid) axireq_state_d = AXIREQ_AW;
            if (ar_valid)            axireq_state_d = AXIREQ_AR;
          end
          AXIREQ_AR: begin
            // Answer to the AR channel
            rnw_d = 1'b1; // We are reading
            first_beat_addr_d = ar_addr;
            beat_addr_d = ar_addr;
            beat_number_d = ar_len + 1;
            beat_size_d = 1 << ar_size;
            ar_ready = 1'b1;
            // Next state evaluation
            if (~flash_is_on_q) begin
              // if, since last reset, the flash has not been powered on, the POWERON sfm needs to be executed to issue the power-on command
              axireq_state_d = AXIREQ_IDLE;
              top_state_d = TOP_POWERON;
            end
            else begin
              // otherwise, we can go on with the normal operation
              axireq_state_d = AXIREQ_IDLE;
              top_state_d = TOP_READ;
            end
          end
          AXIREQ_AW: begin
            // Answer to the AW channel
            rnw_d = 1'b0; // We are writing
            first_beat_addr_d = aw_addr;
            beat_addr_d = aw_addr;
            beat_number_d = aw_len + 1;
            beat_size_d = 1 << aw_size;
            aw_ready = 1'b1;
            // Next state evaluation
            axireq_state_d = AXIREQ_W;
          end
          AXIREQ_W: begin
            // Answer to the W channel
            logic [AddrWidth-1:0] beat_addr_at_beat_count;
            int   lower_byte_lane, upper_byte_lane;
            logic [AddrWidth-1:0] alligned_beat_addr = (first_beat_addr_q / beat_size_q) * beat_size_q;
            int n;
            // Here w_data is put into the wr_beat_queue, however we need to be concious about which byte lanes in w_data are active for the current beat
            if (w_valid) begin
              axi2fls_wr_valid = 1'b1;
              // Define the bytelanes
              if (beat_count_q == 0) begin
                lower_byte_lane = first_beat_addr_q - (first_beat_addr_q / DataBytes)*DataBytes;
                upper_byte_lane = alligned_beat_addr - (first_beat_addr_q / DataBytes)*DataBytes + (beat_size_q - 1);
              end
              if (beat_count_q > 0) begin
                beat_addr_at_beat_count = alligned_beat_addr + (beat_count_q)*beat_size_q;
                lower_byte_lane = beat_addr_at_beat_count - (first_beat_addr_q / DataBytes)*DataBytes;
                upper_byte_lane = lower_byte_lane + (beat_size_q - 1);
              end
              // Assign the correct bytelanes to the wr_beat_queue
              axi2fls_wr_data = '0;
              axi2fls_wr_be = '0;
              n = 0;
              for (int i = lower_byte_lane ; i <= upper_byte_lane ; i++) begin
                // axi2fls_wr_data[n*8+7:n*8] =  w_data[i*8+7:i*8];
                axi2fls_wr_data[n*8 +: 8] = w_data[i*8 +: 8];
                axi2fls_wr_be[n] = w_strb[i];
                n++;
              end
              // As the queue samples, respond to write channel
              if (axi2fls_wr_ready) begin
                w_ready = 1'b1;
                // counter needs to be resused, after this state we want it to return to 0
                beat_count_d = w_last ? 0 : beat_count_q + 1;
              end
            end
            // Next state evaluation
            if ( w_valid && axi2fls_wr_ready && w_last ) begin
              if (~flash_is_on_q) begin
                // if, since last reset, the flash has not been powered on, the POWERON sfm needs to be executed to issue the power-on command
                axireq_state_d = AXIREQ_IDLE;
                top_state_d = TOP_POWERON;
              end
              else begin
                // otherwise, we can go on with the normal operation
                axireq_state_d = AXIREQ_IDLE;
                top_state_d = TOP_READ;
              end
            end
          end
        default: begin
          axireq_state_d = AXIREQ_IDLE;
        end
        endcase
      end
      // // POWERON SFM
      // Issue the power-on command to the flash and wait the required cycles before comencing operation
      TOP_POWERON: begin
        case(poweron_state_q)
          POWERON_IDLE: begin
            poweron_state_d = POWERON_SPI_CHECK_TX_FIFO;
          end
          POWERON_SPI_CHECK_TX_FIFO: begin
            // Proceed only if tx_fifo is not full, exploit direct access to spi_host status
            if (external_spi_host_hw2reg_status_i.txqd.d < SPI_FLASH_TX_FIFO_DEPTH[7:0]) begin
              poweron_state_d = POWERON_SPI_FILL_TX_FIFO;
            end
          end
          POWERON_SPI_FILL_TX_FIFO: begin
            // Write "power on" command in tx_fifo
            spi_host_reg_req_offset  = SPI_HOST_TXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {19'b0, FC_PO};
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              poweron_state_d = POWERON_SPI_WAIT_READY;
            end
          end
          POWERON_SPI_WAIT_READY: begin
            // Wait for spi_host to be ready (command queue not busy)
            if (external_spi_host_hw2reg_status_i.ready.d) begin //TODO : update similar states checking this
              poweron_state_d = POWERON_SPI_SEND_CMD;
            end
          end
          POWERON_SPI_SEND_CMD: begin
            // Send command to spi_host : send PO command to flash 
            // COMMAND register format:
            //   [31:29] = Reserved
            //   [28:27] = Direction (2 = TX only)
            //   [24]    = CSAAT (1 = keep CS asserted for next command)
            //   [23:0]  = Length-1 (0 = 1 byte) (FC_OP is 1 byte command)
            spi_host_reg_req_offset = SPI_HOST_COMMAND_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {
              3'h0, 2'h2, 2'h0, 1'h1, 24'h0
            };  // Empty + Direction + Speed + Csaat + Length
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              poweron_state_d = POWERON_WAIT_CYCLES;
            end
          end
          POWERON_WAIT_CYCLES: begin
            poweron_wait_count_d = poweron_wait_count_q + 1;
            flash_is_on_d = (poweron_wait_count_d == actual_poweron_wait_cycles) ? 1'b1 : 1'b0;
            // Next state evaluation
            if (poweron_wait_count_d == actual_poweron_wait_cycles) begin
              poweron_state_d = POWERON_IDLE;
              top_state_d = TOP_READ;
            end
          end
          default: begin
            poweron_state_d = POWERON_IDLE;
          end
        endcase
      end
      // // READ SFM
      // Write : read the beats' sector into the sector buffer
      // Read : read the beats into the rd_beat_queue
      TOP_READ: begin
        case (read_state_q)
          READ_IDLE: begin
            // Next state evaluation
            read_state_d = READ_INIT;
          end
          READ_INIT: begin
            logic skip_sector_read;
            logic [FlashAddrW-1:0] previous_flash_addr = flash_addr_q;
            // Note : Flash address is byte-precise and 24 bits wide
            // flash_addr evaluation
            if (rnw_q) begin  // READ case
              flash_addr_d = beat_addr_q[FlashAddrW-1:0]; // READ : flash address = beat address
            end
            if (~rnw_q) begin // WRITE case
              logic [AddrWidth-1:0] sector_addr_of_first_byte , sector_addr_of_last_byte;
              sector_addr_of_first_byte = (beat_addr_q >> 12) << 12;
              sector_addr_of_last_byte =  ((beat_addr_q + beat_size_q) >> 12) << 12;
              // WRITE : flash address = sector address = beat address & fff000
              flash_addr_d = sector_addr_of_first_byte[FlashAddrW-1:0];  
              // If the sector would change inside the beat - in the flash the beat is located between two vectors
              // It means that two sector read+modify+write cycles are needed rather than just one , for the single beat
              if ( (sector_addr_of_last_byte > sector_addr_of_first_byte) && ~second_sector_write_q ) begin
                // This is the first of the two cycles
                first_sector_write_d = 1'b1; 
              end
              if (second_sector_write_q) begin
                // This is the second of the two cycles
                first_sector_write_d = 1'b0; 
                flash_addr_d = sector_addr_of_last_byte[FlashAddrW-1:0]; // Next sector
              end
            end
            // skip_sector_read evaluation
            // We want to skip the sector storage into the sector buffer in case nothing would change from the previous beat
            // Skip the sector read if we are writing and the sector base address sent to the flash would be the same
            skip_sector_read = ((flash_addr_d == previous_flash_addr) && ~rnw_q) ? 1'b1 : 1'b0;
            // Next state evaluation
            if (skip_sector_read) begin
              read_state_d = READ_IDLE;
              top_state_d = TOP_FWAIT;
            end else begin
              read_state_d = READ_SET_RXWM_R;
            end
          end
          READ_SET_RXWM_R: begin
            // Set RX watermark to 1 word so we get notified when status byte arrives
            // but we need to preserve other bits when modifying RXWM
            // this is why here we first read the entire spi_host command to then write back the rest of the bits alongside the new wm
            // Read the command:
            spi_host_reg_req_offset = SPI_HOST_CONTROL_OFFSET;
            spi_host_reg_req_o.write = 1'b0;
            spi_host_reg_req_o.valid = 1'b1;
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              spi_host_command_d = spi_host_reg_rsp_i.rdata;
            end
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              read_state_d = READ_SET_RXWM_W;
            end
          end
          READ_SET_RXWM_W: begin
            // Rewrite the command with updated wm:
            spi_host_reg_req_offset = SPI_HOST_CONTROL_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            // Keep upper CONTROL bits, set RXWM = 1
            spi_host_reg_req_o.wdata = {
              spi_host_command_q[31:8], 8'h01
            };  
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              read_state_d = READ_SPI_CHECK_TX_FIFO;
            end
          end
          READ_SPI_CHECK_TX_FIFO: begin
            // Proceed only if tx_fifo is not full, exploit direct access to spi_host status
            if (external_spi_host_hw2reg_status_i.txqd.d < SPI_FLASH_TX_FIFO_DEPTH[7:0]) begin
              read_state_d = READ_SPI_FILL_TX_FIFO;
            end
          end
          READ_SPI_FILL_TX_FIFO: begin
            // Write READ command + flash address in tx_fifo
            spi_host_reg_req_offset  = SPI_HOST_TXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata =  {
              (bitfield_byteswap32({ 8'h00 , flash_addr_q })) | {19'h0, FC_RD}
            };
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              read_state_d = READ_SPI_WAIT_READY_1;
            end
          end
          READ_SPI_WAIT_READY_1: begin
            // Wait for spi_host to be ready (command queue not busy)
            if (external_spi_host_hw2reg_status_i.ready.d) begin //TODO : update similar states checking this
              read_state_d = READ_SPI_SEND_CMD_1;
            end
          end
          READ_SPI_SEND_CMD_1: begin
            // Send command to spi_host : send opcode and address to flash 
            // COMMAND register format:
            //   [31:29] = Reserved
            //   [28:27] = Direction (2 = TX only)
            //   [26:25] = Speed (0 = standard)
            //   [24]    = CSAAT (1 = keep CS asserted for next command)
            //   [23:0]  = Length-1 (3 = 4 bytes: 1 command + 3 address)
            spi_host_reg_req_offset = SPI_HOST_COMMAND_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {
              3'h0, 2'h2, 2'h0, 1'h1, 24'h3
            }; // Reserved + Direction + Speed + Csaat + Length
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              read_state_d = READ_SPI_WAIT_READY_2;
            end
          end
          READ_SPI_WAIT_READY_2: begin
            // Wait for spi_host to be ready (command queue not busy)
            if (external_spi_host_hw2reg_status_i.ready.d) begin
              read_state_d = READ_SPI_SEND_CMD_2;
            end
          end
          READ_SPI_SEND_CMD_2: begin
            // Send command to spi_host : store flash content into rx_fifo from flash
            // COMMAND register format:
            //   [31:29] = Reserved
            //   [28:27] = Direction (1 = RX only)
            //   [26:25] = Speed (0 = standard)
            //   [24]    = CSAAT (0 = release CS after transfer, no more commands to send)
            //   [23:0]  = Length-1 (See comments below)
            spi_host_reg_req_offset  = SPI_HOST_COMMAND_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            if (rnw_q) begin
              // READ: receive a number of bytes specified by axi (beat_size) (up to 4)
              spi_host_reg_req_o.wdata = {
                3'h0, 2'h1, 2'h0, 1'h0,  {16'h0 , (beat_size_q - 1'h1)}
              }; // Empty + Direction + Speed + Csaat + Length
            end
            if (~rnw_q) begin
              // WRITE: read full sector (4096 bytes)
              spi_host_reg_req_o.wdata = {
                3'h0, 2'h1, 2'h0, 1'h0, {11'b0, SE_BSIZE - 1'h1}
              }; // Empty + Direction + Speed + Csaat + Length
              word_count_d = 0; // restart the word counter to count up to one sector
            end
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              read_state_d = READ_WAIT_RXWM;
            end
          end
          READ_WAIT_RXWM: begin
            // Wait for flash data to be present in the rx_fifo before sending a pop request (check whether wm is reached)
            // This is why we set rx_wm to 1
            if (external_spi_host_hw2reg_status_i.rxwm.d) begin
              // wm Flag is sampled, valid and set
              if (rnw_q) begin
                // Read
                // Depending on the size of the data coming from axi data bus chose a different sfm branch
                if (~datawidth_is_64_n32) begin   // 32bit
                  read_state_d = READ_R_BEAT_PUSH_DW32;   
                end
                if (datawidth_is_64_n32) begin   // 64bit
                  if (beat_half_index_q == 0) begin   // First half of the beat
                    read_state_d = READ_R_BEAT_PUSH_DW64_1;
                  end 
                  if (beat_half_index_q == 1) begin   // Second half of the beat
                    read_state_d = READ_R_BEAT_PUSH_DW64_2;
                  end
                end 
              end 
              // Write -> load sector in sector buffer
              if (~rnw_q) read_state_d = READ_W_SECTOR_STORE;
            end
          end
          READ_W_SECTOR_STORE: begin
            // Copy the sector from flash to buffer
            // Send a pop request to rx_fifo
            spi_host_reg_req_offset  = SPI_HOST_RXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b0;
            spi_host_reg_req_o.valid = 1'b1;
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              // When word is popped, send a write request to the sector buffer
              sect_buffer_req = 1'b1;
              sect_buffer_we = 1'b1;
              sect_buffer_addr = '0 + word_count_q;
              sect_buffer_wdata = spi_host_reg_rsp_i.rdata;
              sect_buffer_be = 4'b1111;
              word_count_d = word_count_q + 1;
            end
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              if (word_count_d == SE_WSIZE) begin
                top_state_d = TOP_FWAIT;
                read_state_d = READ_IDLE;
              end
              if (word_count_d < SE_WSIZE) begin
                read_state_d = READ_WAIT_RXWM;
              end
            end
          end
          READ_R_BEAT_PUSH_DW32: begin
            // Bring the beat into rd_queue_buffer, where spi_host rx_fifo data is stored temporarily before going into the rd_beat_queue
            // Send a pop request to rx_fifo
            spi_host_reg_req_offset  = SPI_HOST_RXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b0;
            spi_host_reg_req_o.valid = 1'b1;
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              // When beat is popped, save it first in the rd_queue_buffer
              rd_queue_buffer_d = spi_host_reg_rsp_i.rdata;
            end
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              read_state_d = READ_R_BEAT_PUSH_FIN;
            end
          end
          READ_R_BEAT_PUSH_DW64_1: begin
            /*
            If AXI's DataWidth (and this module's) is 64, beat queues and their buffer also are 64 bit wide,
            however the width of spi_host and its fifos (and the flash) stays the same at 32 bits.
            This means that two states are required to load data from rx_fifo to rd_beat_queue_buffer, since beat_size can be > 4.
            Here we write the lower 32 bites of the rd_queue_buffer.
            */
            // Bring the beats into rd_beat_queue
            // Send a pop request to rx_fifo
            spi_host_reg_req_offset  = SPI_HOST_RXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b0;
            spi_host_reg_req_o.valid = 1'b1;
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              // When beat is popped, save it first in the rd_queue_buffer
              rd_queue_buffer_d[31:0] = spi_host_reg_rsp_i.rdata;
              beat_half_index_d = 1'b1;
            end
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              read_state_d = READ_WAIT_RXWM;
            end
          end
          READ_R_BEAT_PUSH_DW64_2: begin
            /*
            Here we write the upper 32 bites of the rd_queue_buffer
            */
            // If the beat size is not higher than 4 bytes, then we can bypass the request and just write zeroes
            if (beat_size_q > 4) begin
              spi_host_reg_req_offset  = SPI_HOST_RXDATA_OFFSET;
              spi_host_reg_req_o.write = 1'b0;
              spi_host_reg_req_o.valid = 1'b1;
              if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
                // When beat is popped, save it first in the rd_queue_buffer
                rd_queue_buffer_d[DataWidth-1:DataWidth/2] = spi_host_reg_rsp_i.rdata;
                beat_half_index_d = 1'b0;
              end
            end
            beat_half_index_d = 1'b0;
            // Next state evaluation
            if (beat_size_q > 4) begin
              if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
                read_state_d = READ_R_BEAT_PUSH_FIN;
              end
            end
            else begin  // Bypass register response if second half was not required
              read_state_d = READ_R_BEAT_PUSH_FIN;
            end
          end
          READ_R_BEAT_PUSH_FIN: begin
            spihost_rd_valid = 1'b1;
            spihost_rd_data = rd_queue_buffer_q;
            if (spihost_rd_ready) begin
              beat_count_d = beat_count_q + 1;
              // If there are more beats to read we update beat_address, otherwise we move to TOP_AXIRESP
              if (beat_count_d < beat_number_q) begin
                // This controller assumes to work only in INCR bursts
                // addr_0 = ax_addr
                // addr_0_alligned = INT(addr_0 / size) * size
                // addr_N = addr_0_alligned + size*N
                beat_addr_d = ((first_beat_addr_q / beat_size_q ) * beat_size_q) + (beat_count_q + 1)*beat_size_q;
                flash_addr_d = beat_addr_d; // It is enstablished that we are reading
              end
            end
            // Next state evaluation
            if (spihost_rd_ready && beat_count_d <  beat_number_q) begin
              read_state_d = READ_SPI_CHECK_TX_FIFO;
            end
            if (spihost_rd_ready && beat_count_d == beat_number_q) begin
              read_state_d = READ_IDLE;
              top_state_d = TOP_AXIRESP;
            end
          end
          default: begin
            read_state_d = READ_IDLE;
          end
        endcase
      end
      // // FWAIT SFM
      // Polls the flash Status Register 1 (SR1) to check if the flash is busy
      // The BUSY bit (bit 0) is set during erase/program operations in spi_host
      // This FSM is called multiple times during a write operation:
      //
      //   fwait_cnt = 0: After READ  -> wait for flash ready, then go to ERASE
      //   fwait_cnt = 1: After ERASE -> wait for flash ready, then go to MODIFY
      //   fwait_cnt = 2: After WRITE -> wait for flash ready, then complete
      //
      // Note: fwait_cnt is reset to 0 if total length has not been written yet and more sectors need to be processed
      // Hence the operation only finishes when all the data has been written back into flash
      TOP_FWAIT: begin
        case (fwait_state_q)
          FWAIT_IDLE: begin
            fwait_state_d = FWAIT_SET_RXWM_R;
          end
          FWAIT_SET_RXWM_R: begin
            // Set RX watermark to 1 word so we get notified when status byte arrives
            // but we need to preserve other bits when modifying RXWM
            // this is why here we first read the entire spi_host command to then write back the rest of the bits alongside the new wm
            // Read the command:
            spi_host_reg_req_offset = SPI_HOST_CONTROL_OFFSET;
            spi_host_reg_req_o.write = 1'b0;
            spi_host_reg_req_o.valid = 1'b1;
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              spi_host_command_d = spi_host_reg_rsp_i.rdata;
            end
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              fwait_state_d = FWAIT_SET_RXWM_W;
            end
          end
          FWAIT_SET_RXWM_W: begin
            // Rewrite the command with updated wm:
            spi_host_reg_req_offset = SPI_HOST_CONTROL_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            // Keep upper CONTROL bits, set RXWM = 1
            spi_host_reg_req_o.wdata = {
              spi_host_command_q[31:8], 8'h01
            };  
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              fwait_state_d = FWAIT_SPI_CHECK_TX_FIFO;
            end
          end
          FWAIT_SPI_CHECK_TX_FIFO: begin
            // Proceed only if tx_fifo is not full, exploit direct access to spi_host status
            if (external_spi_host_hw2reg_status_i.txqd.d < SPI_FLASH_TX_FIFO_DEPTH[7:0]) begin
              fwait_state_d = FWAIT_SPI_FILL_TX_FIFO;
            end
          end
          FWAIT_SPI_FILL_TX_FIFO: begin
            // Write Status Register 1 Read command in tx_fifo
            spi_host_reg_req_offset  = SPI_HOST_TXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {19'b0, FC_RSR1};
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              fwait_state_d = FWAIT_SPI_WAIT_READY_1;
            end
          end
          FWAIT_SPI_WAIT_READY_1: begin
            // Wait for spi_host to be ready (command queue not busy) 
            if (external_spi_host_hw2reg_status_i.ready.d) begin
              fwait_state_d = FWAIT_SPI_SEND_CMD_1;
            end
          end
          FWAIT_SPI_SEND_CMD_1: begin
            // Send command to spi_host : send RSR1 command to flash 
            // COMMAND register format:
            //   [31:29] = Reserved
            //   [28:27] = Direction (2 = TX only)
            //   [24]    = CSAAT (1 = keep CS asserted for next command)
            //   [23:0]  = Length-1 (0 = 1 byte) (FC_RSR1 is 1 byte command)
            spi_host_reg_req_offset = SPI_HOST_COMMAND_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {
              3'h0, 2'h2, 2'h0, 1'h1, 24'h0
            };  // Empty + Direction + Speed + Csaat + Length
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              fwait_state_d = FWAIT_SPI_WAIT_READY_2;
            end
          end
          FWAIT_SPI_WAIT_READY_2: begin
            // Wait for spi_host to be ready (command queue not busy) 
            if (external_spi_host_hw2reg_status_i.ready.d) begin
              fwait_state_d = FWAIT_SPI_SEND_CMD_2;
            end
          end
          FWAIT_SPI_SEND_CMD_2: begin
            // Send command to spi_host : recieve status from flash
            // COMMAND register format:
            //   [31:29] = Reserved
            //   [28:27] = Direction (1 = RX only)
            //   [24]    = CSAAT (0 = release CS after transfer, no more commands to send)
            //   [23:0]  = Length-1 (0 = 1 byte)
            spi_host_reg_req_offset = SPI_HOST_COMMAND_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {
              3'h0, 2'h1, 2'h0, 1'h0, 24'h0
            };  // Empty + Direction + Speed + Csaat + Length
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              fwait_state_d = FWAIT_WAIT_RXWM;
            end
          end
          FWAIT_WAIT_RXWM: begin
            // Wait for flash status to be present in the rx_fifo before sending a pop request (check whether wm is reached)
            // This is why we set rx_wm to 1
            // Next state evaluation
            if (external_spi_host_hw2reg_status_i.rxwm.d) begin
              fwait_state_d = FWAIT_READ_FLASH_STATUS;
            end
          end
          FWAIT_READ_FLASH_STATUS: begin
            // Check flash status and go next if not busy, otherwise repeat FWAIT
            // Send request to rx_fifo and wait for status to be sampled
            spi_host_reg_req_offset  = SPI_HOST_RXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b0;
            spi_host_reg_req_o.valid = 1'b1;
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              // Check BUSY bit: 0 = ready, 1 = busy
              if (spi_host_reg_rsp_i.rdata[0] == 1'b0) begin
                // Flash is READY , Proceed to next TOP_STATE
                case (fwait_cnt_q)
                  // After READ: Flash ready -> go to ERASE
                  2'h0: begin
                    fwait_cnt_d   = 2'h1;
                    fwait_state_d = FWAIT_IDLE;
                    top_state_d   = TOP_ERASE;
                    erase_state_d = ERASE_IDLE;
                  end
                  // After ERASE: Flash ready -> go to MODIFY
                  2'h1: begin
                    fwait_cnt_d = 2'h2;
                    fwait_state_d = FWAIT_IDLE;
                    top_state_d = TOP_MODIFY;
                    modify_state_d = MODIFY_IDLE;
                  end
                  // After WRITE:
                  2'h2: begin
                    if(page_count_q < SE_PSIZE) begin
                      // There are still pages to program for the current sector
                      fwait_state_d = FWAIT_IDLE;
                      top_state_d   = TOP_WRITE;
                      write_state_d = WRITE_IDLE;
                    end else begin
                      // Current sector write is complete
                      fwait_cnt_d = 2'h0;
                      // Reset page counter
                      page_count_d = 0;
                      if (first_sector_write_q) begin
                        // If only the first sector out of two has been written, return to READ and do the second
                        second_sector_write_d = 1;
                        fwait_state_d = FWAIT_IDLE;
                        top_state_d = TOP_READ;
                      end else begin
                        // Current beat write is completed
                        beat_count_d = beat_count_q + 1;
                        if (beat_count_d < beat_number_q) begin
                          // There are more beats to go for this AXI transmission
                          /*

                          Evaluate address of next beat

                          If there are more beats to write then return to READ to proces the next one
                          This controller assumes to work only in INCR bursts
                          addr_0 = axi_addr
                          addr_0_alligned = INT(addr_0 / size) * size
                          addr_N = addr_0_alligned + size*N
                          */
                          beat_addr_d = ((first_beat_addr_q / beat_size_q ) * beat_size_q) + (beat_count_q + 1)*beat_size_q;
                          
                          fwait_state_d = FWAIT_IDLE;
                          top_state_d = TOP_READ;
                        end else begin
                          // AXI transmission is over
                          // Reset some registers
                          first_sector_write_d = 0;
                          second_sector_write_d = 0;

                          top_state_d = TOP_AXIRESP;
                          fwait_state_d = FWAIT_IDLE;
                        end
                      end
                    end
                  end
                default: begin  // TODO double check these if begin-end
                end
              endcase
              end else begin
                // Flash is BUSY, repeat TOP_FWAIT
                fwait_state_d = FWAIT_SET_RXWM_R;
              end
            end
          end
          default: begin
            fwait_state_d = FWAIT_IDLE;
          end
        endcase
      end
      // // ERASE FSM
      // Erases a 4KB sector in the flash memory
      // Flash memory requires erasing (setting all bits to 1) before programming as a switch from 0 to 1 is not possible for this technology
      //
      // The erase sequence consists of two SPI commands:
      //   1. Write Enable (WE): Required before any write/erase operation
      //   2. Sector Erase (SE): Erases 4KB sector at specified address
      TOP_ERASE: begin
        case (erase_state_q)
          ERASE_IDLE: begin
            erase_state_d = ERASE_WE_CHECK_TX_FIFO;
          end
          ERASE_WE_CHECK_TX_FIFO: begin
            // Proceed only if tx_fifo is not full, exploit direct access to spi_host status
            if (external_spi_host_hw2reg_status_i.txqd.d < SPI_FLASH_TX_FIFO_DEPTH[7:0]) begin
              erase_state_d = ERASE_WE_FILL_TX_FIFO;
            end
          end
          ERASE_WE_FILL_TX_FIFO: begin
            // Write "write enable" command in tx_fifo
            spi_host_reg_req_offset  = SPI_HOST_TXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {19'b0, FC_WE};
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              erase_state_d = ERASE_WE_WAIT_READY;
            end
          end
          ERASE_WE_WAIT_READY: begin
            // Wait for spi_host to be ready (command queue not busy) 
            if (external_spi_host_hw2reg_status_i.ready.d) begin
              erase_state_d = ERASE_WE_SEND_CMD;
            end
          end
          ERASE_WE_SEND_CMD: begin
            // Send command to spi_host : send write enable command to flash
            // COMMAND register format:
            //   [31:29] = Reserved
            //   [28:27] = Direction (2 = TX only)
            //   [24]    = CSAAT (0 = release CS after, WE is standalone command)
            //   [23:0]  = Length-1 (0 = 1 byte)
            spi_host_reg_req_offset = SPI_HOST_COMMAND_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {
              3'h0, 2'h2, 2'h0, 1'h0, 24'h0
            };  // Empty + Direction + Speed + Csaat + Length
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              erase_state_d = ERASE_SE_CHECK_TX_FIFO;
            end
          end
          ERASE_SE_CHECK_TX_FIFO: begin
            // Proceed only if tx_fifo is not full, exploit direct access to spi_host status
            if (external_spi_host_hw2reg_status_i.txqd.d < SPI_FLASH_TX_FIFO_DEPTH[7:0]) begin
              erase_state_d = ERASE_SE_FILL_TX_FIFO;
            end
          end
          ERASE_SE_FILL_TX_FIFO: begin
            // Write sector erase command + address in tx_fifo
            spi_host_reg_req_offset = SPI_HOST_TXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata =  {
              (bitfield_byteswap32({ 8'h0 , flash_addr_q })) | {19'h0, FC_SE}
            };
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              erase_state_d = ERASE_SE_WAIT_READY;
            end
          end
          ERASE_SE_WAIT_READY: begin
            // Wait for spi_host to be ready (command queue not busy)
            if (external_spi_host_hw2reg_status_i.ready.d) begin
              erase_state_d = ERASE_SE_SEND_CMD;
            end
          end
          ERASE_SE_SEND_CMD: begin
            //  Send command to spi_host : send sector erase command
            // COMMAND register format:
            //   [31:29] = Reserved
            //   [28:27] = Direction (2 = TX only)
            //   [24]    = CSAAT (0 = release CS after transfer, no more commands to send)
            //   [23:0]  = Length-1 (3 = 4 bytes: 1 cmd + 3 addr bytes)
            spi_host_reg_req_offset = SPI_HOST_COMMAND_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {
              3'h0, 2'h2, 2'h0, 1'h0, 24'h3
            };  // Empty + Direction + Speed + Csaat + Length
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              // Go to FWAIT FSM to poll status register until erase completes
              erase_state_d = ERASE_IDLE;
              top_state_d = TOP_FWAIT;
              fwait_state_d = FWAIT_IDLE; // Start polling
            end
          end
          default: begin
            erase_state_d = ERASE_IDLE;
          end
        endcase
      end

      // // MODIFY FSM
      // At this point, the sector buffer already contains the original sector data
      // from flash (loaded by READ FSM). This FSM overlays the new beat data in the wr_beeat_queue at the
      // correct position within the sector.
      TOP_MODIFY: begin
        case (modify_state_q)
          MODIFY_IDLE: begin
            modify_state_d = MODIFY_BEAT_POP;
          end
          MODIFY_BEAT_POP: begin
            if (spihost_wr_valid) begin
              spihost_wr_ready = 1'b1;
              wr_queue_buffer_data_d = spihost_wr_data;
              wr_queue_buffer_be_d = spihost_wr_be;
            end
            // Next state evaluation
            // Sector buffer, like flash, has a constant datawidth of 32, so we need separate SFM branches depending on AXI datawitdh
            if (spihost_wr_valid &&  datawidth_is_64_n32) modify_state_d = MODIFY_SECTOR_UPDATE_DW32_1;
            if (spihost_wr_valid && ~datawidth_is_64_n32) modify_state_d = MODIFY_SECTOR_UPDATE_DW64_1;
          end
          /*

          Notes : 
  
          Address in the sector buffer scratchpad is not byte precise but word precise, unlike the flash
              Thus : beat address and word address can be misaligned
                  Thus : one beat (up to one word of size) can cover more words in the sector buffer
          datawidth_is_64_n32 = 0 : up to two adiacent words
          datawidth_is_64_n32 = 1 : up to three adiacent words
  
          Each branch MODIFY_SECTOR_UPDATE has a state for each word that could be overwritten by the beat in the sector buffer
          32 bits : 2 words , 2 states
          64 bits : 3 words , 3 states
  
          32 bits:
                              word n+1       word n
                              3  2  1  0  |  3  2  1  0  
          beat bytes :           3  2  1     0
  
          missalignment = 3
  
  
          64 bits:
                                  word n+2      word n+1       word n
                              3  2  1  0  |  3  2  1  0  |  3  2  1  0 
          beat bytes :                 7     6  5  4  3     2  1  0  
  
          missalignment = 1
  
          keep in mind that two words can be in separated sectors, 
          this means that before progressing to the next word/state we need to interrupt MODIFY_SECTOR_UPDATE branch,
          finish first the current sector write in TOP_WRITE and then go back to TOP READ and repeat with the second sector
  

          cases for MODIFY_SECTOR_UPDATE_DW32:
  
          (I) beat fits in one sector
          MODIFY_SECTOR_UPDATE_DW32_1    MODIFY_SECTOR_UPDATE_DW32_2                
          sector_relative_addr = x       sector_relative_addr = x+1 
  
          (II) beat needs two sectors
          MODIFY_SECTOR_UPDATE_DW32_1    MODIFY_SECTOR_UPDATE_DW32_2    MODIFY_SECTOR_UPDATE_DW32_1    MODIFY_SECTOR_UPDATE_DW32_2
          first_sector_write == 1        first_sector_write == 1        second_sector_write == 1       second_sector_write == 1
          sector_relative_addr = x       skipped                        sector_relative_addr = 0       skipped                    
  
          case distinguished by looking at first_sector_write, second_sector_write


          cases for MODIFY_SECTOR_UPDATE_DW64:

          (I) beat fits in one sector , sector doesn't change
          MODIFY_SECTOR_UPDATE_DW64_1    MODIFY_SECTOR_UPDATE_DW64_2    MODIFY_SECTOR_UPDATE_DW64_3
          sector_relative_addr = x       sector_relative_addr = x+1     sector_relative_addr = x+2
          
          (II) beat needs two sectors , sector changes @ third word of sector buffer
          MODIFY_SECTOR_UPDATE_DW64_1    MODIFY_SECTOR_UPDATE_DW64_2    MODIFY_SECTOR_UPDATE_DW64_3    MODIFY_SECTOR_UPDATE_DW64_1    MODIFY_SECTOR_UPDATE_DW64_2    MODIFY_SECTOR_UPDATE_DW64_3
          first_sector_write == 1        first_sector_write == 1        first_sector_write == 1        second_sector_write == 1       second_sector_write == 1       second_sector_write == 1
          sector_relative_addr = x       sector_relative_addr = x+1     skipped                        skipped                        skipped                        sector_relative_addr = 0
      
          (III) beat needs two sectors , sector changes @ second word of sector buffer
          MODIFY_SECTOR_UPDATE_DW64_1    MODIFY_SECTOR_UPDATE_DW64_2    MODIFY_SECTOR_UPDATE_DW64_3    MODIFY_SECTOR_UPDATE_DW64_1    MODIFY_SECTOR_UPDATE_DW64_2    MODIFY_SECTOR_UPDATE_DW64_3
          first_sector_write == 1        first_sector_write == 1        first_sector_write == 1        second_sector_write == 1       second_sector_write == 1       second_sector_write == 1
          sector_relative_addr = x       skipped                        skipped                        skipped                        sector_relative_addr = 0       sector_relative_addr = 1
  
          case distinguished by looking at first_address_write, second_address_write, (sector_relative_address == 12'hfff)
          
          */
          MODIFY_SECTOR_UPDATE_DW32_1: begin
            int m;
            int n;
            // The first word covered by the beat is written in the sector buffer
            // If this is the second sector write out of two of the beat, it means that the first word was already written, so we skip this state
            if(~second_sector_write_q) begin
              // The beat address relative to the sector are the 12 LSB
              // That is beat address & 000fff
              logic [AddrWidth-1:0] sector_relative_addr = '0;
              sector_relative_addr[11:0] = beat_addr_q[11:0];
              // Measure the address misaligment (m) between beat and word address
              m = '0;
              // The two bits relative to the byte inside the beat indicate the misalignment
              m[1:0] = sector_relative_addr[1:0];

              // The address to send to the sector buffer is 32bit word precise , so we push out the 2 LSB relative to the single byte
              sect_buffer_addr = sector_relative_addr >> 2;
              
              // Overwriting the current 4 bytes of the word @ the sect_buffer_addr in the sector buffer the beat
              sect_buffer_be = '0;
              n = 0;
              for (int i=0 ; i<4 ; i++) begin
              // the first "m" bytes are sent unvaid
              if (n < m) begin 
                sect_buffer_be[i] = 1'b0;
                n++;
              end
              else begin
                // Byte i of sector buffer is overwritten by byte (i-m) of beat, due to misalignment
                // sect_buffer_wdata[i*8+7:i*8] = wr_queue_buffer_data_q[(i-m)*8+7:(i-m)*8];
                sect_buffer_wdata[i*8 +: 8] = wr_queue_buffer_data_q[(i-m)*8 +: 8];
                sect_buffer_be[i] = wr_queue_buffer_be_q[(i-m)];
              end
              end

              // Other request bits
              sect_buffer_req = 1'b1;
              sect_buffer_we = 1'b1;

              // Next state evaluation
              modify_state_d = MODIFY_SECTOR_UPDATE_DW32_2;
            end
          end
        MODIFY_SECTOR_UPDATE_DW32_2: begin
          int m;
          // The second word covered by the beat is written in the sector buffer
          // If this is the first sector write out of two of the beat, the second word write is postponed later after we finished working with this sector
          if(~first_sector_write_q) begin
            // The beat address relative to the sector are the 12 LSB
            // That is beat address & 000fff
            logic [AddrWidth-1:0] sector_relative_addr = '0;
            sector_relative_addr[11:0] = beat_addr_q[11:0];
            // Measure the address misaligment (m) between beat and word address
            m = '0;
            // The two bits relative to the byte inside the beat indicate the misalignment
            m[1:0] = sector_relative_addr[1:0];

            // If it is the second sector write, then we wrap down to the first word, otherwise we increment to the next word
            sect_buffer_addr = second_sector_write_q ? 0 : (sector_relative_addr >> 2) + 1;

            // Overwriting the current 4 bytes of the word @ the sect_buffer_addr in the sector buffer the beat
            sect_buffer_be = '0;
            for (int i=0 ; i<m ; i++) begin
              // sect_buffer_wdata[i*8+7:i*8] = wr_queue_buffer_data_q[(i+4-m)*8+7:(i+4-m)*8];
              sect_buffer_wdata[i*8 +: 8] = wr_queue_buffer_data_q[(i+4-m)*8 +: 8];
              sect_buffer_be[i] = wr_queue_buffer_be_q[(i+4-m)];
            end

            // Other request bits
            sect_buffer_req = 1'b1;
            sect_buffer_we = 1'b1;

            // Next state evaluation
            modify_state_d = MODIFY_IDLE;
            top_state_d = TOP_WRITE;
          end
        end
        MODIFY_SECTOR_UPDATE_DW64_1: begin
          int n;
          int m;
          // The first word covered by the beat is written in the sector buffer
          // If this is the second sector write out of two of the beat, it means that the first word was already written, so we skip this state
          if(~second_sector_write_q) begin
            // The beat address relative to the sector are the 12 LSB
            // That is beat address & 000fff
            logic [AddrWidth-1:0] sector_relative_addr = '0;
            sector_relative_addr[11:0] = beat_addr_q[11:0];
            // Measure the address misaligment (m) between beat and word address
            m = '0;
            // The two bits relative to the byte inside the beat indicate the misalignment
            m[1:0] = sector_relative_addr[1:0];

            // The address to send to the sector buffer is 32bit word precise , so we push out the 2 LSB relative to the single byte
            sect_buffer_addr = sector_relative_addr >> 2;
            
            // overwriting the current 4 bytes of the word @ the sect_buffer_addr in the sector buffer the beat
            sect_buffer_be = '0;
            n = 0;
            for (int i=0 ; i<4 ; i++) begin
            // the first "m" bytes are sent unvaid
            if (n < m) begin 
              sect_buffer_be[i] = 1'b0;
              n++;
            end
            else begin
              // byte i of sector buffer is overwritten by byte (i-m) of beat, due to misalignment
              // sect_buffer_wdata[i*8+7:i*8] = wr_queue_buffer_data_LSH[(i-m)*8+7:(i-m)*8];
              sect_buffer_wdata[i*8 +: 8] = wr_queue_buffer_data_LSH[(i-m)*8 +: 8];
              sect_buffer_be[i] = wr_queue_buffer_be_LSH[(i-m)];
            end
            end

            // Other request bits
            sect_buffer_req = 1'b1;
            sect_buffer_we = 1'b1;

            // Next state evaluation
            modify_state_d = MODIFY_SECTOR_UPDATE_DW64_2;
          end
        end
        MODIFY_SECTOR_UPDATE_DW64_2: begin
          logic skip;
          int m;
          // The second word covered by the beat is written in the sector buffer
          // The beat address relative to the sector are the 12 LSB
          // That is beat address & 000fff
          logic [AddrWidth-1:0] sector_relative_addr = '0;
          sector_relative_addr[11:0] = beat_addr_q[11:0];

          // If this is the first sector write out of two of the beat, and the previous word was at the edge of the sector buffer, 
          // the sector is changed and we need to postpone this state.
          // On the other hand, if it is the second sector write out of two of the beat, if we didn't skip before, we do it now.
          skip = 0;
          if (first_sector_write_q)
            if (sector_relative_addr[11:0] == 12'hfff)
              skip = 1;
          if (second_sector_write_q)
            if (sector_relative_addr[11:0] != 12'hfff)
              skip = 1;
          if(!skip) begin
            // Measure the address misaligment (m) between beat and word address
            m = '0;
            // The two bits relative to the byte inside the beat indicate the misalignment
            m[1:0] = sector_relative_addr[1:0];

            // If it is the second sector write, then we wrap down to the first word, otherwise we increment to the next word
            sect_buffer_addr = second_sector_write_q ? 0 : (sector_relative_addr >> 2) + 1;

            // overwriting the current 4 bytes of the word @ the sect_buffer_addr in the sector buffer the beat
            // this word could be split between bits of both the first and second half of wr_queue_buffer
            // assigning wr_queue_buffer_LSH (first 4 bytes)
            sect_buffer_be = '0;
            for (int i=0 ; i<m ; i++) begin
              //sect_buffer_wdata[i*8+7:i*8] = wr_queue_buffer_data_LSH[(i+4-m)*8+7:(i+4-m)*8];
              sect_buffer_wdata[i*8 +: 8] = wr_queue_buffer_data_LSH[(i+4-m)*8 +: 8];
              sect_buffer_be[i] = wr_queue_buffer_be_LSH[(i+4-m)];
            end
            // assigning wr_queue_buffer_MSH (last 4 bytes)
            for (int i=m ; i<4 ; i++) begin
              // sect_buffer_wdata[i*8+7:i*8] = wr_queue_buffer_data_MSH[(i+4-m)*8+7:(i+4-m)*8];
              sect_buffer_wdata[i*8 +: 8] = wr_queue_buffer_data_MSH[(i+4-m)*8 +: 8];
              sect_buffer_be[i] = wr_queue_buffer_be_MSH[i];
            end

            // Other request bits
            sect_buffer_req = 1'b1;
            sect_buffer_we = 1'b1;

            // Next state evaluation
            modify_state_d = MODIFY_SECTOR_UPDATE_DW64_3;
          end
        end
        MODIFY_SECTOR_UPDATE_DW64_3: begin
          int m;
          // The third word covered by the beat is written in the sector buffer
          // If this is the first sector write out of two of the beat, the second word write is postponed later after we finished working with this sector
          if(~first_sector_write_q) begin
            int n;
            // The beat address relative to the sector are the 12 LSB
            // That is beat address & 000fff
            logic [AddrWidth-1:0] sector_relative_addr = '0;
            sector_relative_addr[11:0] = beat_addr_q[11:0];
            // The address to send to the sector buffer is 32bit word precise , so we push out the 2 LSB relative to the single byte
            sect_buffer_addr = sector_relative_addr >> 2;
            // Measure the address misaligment (m) between beat and word address
            m = '0;
            // The two bits relative to the byte inside the beat indicate the misalignment
            m[1:0] = sector_relative_addr[1:0];

            // Depending on where the sector changed between the three states/words, a different address is chosen
            if (second_sector_write_q)
              if (sector_relative_addr[11:0] == 12'hfff)
                sect_buffer_addr = 0;
              if (sector_relative_addr[11:0] != 12'hfff)
                sect_buffer_addr = 0 + 1;
            if (~second_sector_write_q)
                sect_buffer_addr = (sector_relative_addr >> 2) + 2;

            // overwriting the current 4 bytes of the word @ the sect_buffer_addr in the sector buffer the beat
            sect_buffer_be = '0;
            n = 0;
            for (int i=0 ; i<m ; i++) begin
            // sect_buffer_wdata[i*8+7:i*8] = wr_queue_buffer_data_MSH[(i+4-m)*8+7:(i+4-m)*8];
            sect_buffer_wdata[i*8 +: 8] = wr_queue_buffer_data_MSH[(i+4-m)*8 +: 8];
            sect_buffer_be[i] = wr_queue_buffer_be_MSH[(i+4-m)];
            end

            // Other request bits
            sect_buffer_req = 1'b1;
            sect_buffer_we = 1'b1;

            // Next state evaluation
            modify_state_d = MODIFY_IDLE;
            top_state_d = TOP_WRITE;
          end
        end
        default: begin
        end
        endcase
      end
      // // WRITE SFM
      // Programs the modified sector buffer back to flash, page by page
      // Flash page size is 256 bytes and a sector contains 16 pages resulting in 4096 bytes per sector
      //
      // For each page, the sequence is:
      //   1. Write Enable (WE): Required before each write/erase flash operation
      //   2. Page Program (PP): Send command + address, then data is transfered from local sector buffer to SPI Host TX FIFO
      TOP_WRITE: begin
        case (write_state_q)
          WRITE_IDLE: begin
            write_state_d = WRITE_WE_CHECK_TX_FIFO;
          end
          WRITE_WE_CHECK_TX_FIFO: begin
            // Proceed only if tx_fifo is not full, exploit direct access to spi_host status
            if (external_spi_host_hw2reg_status_i.txqd.d < SPI_FLASH_TX_FIFO_DEPTH[7:0]) begin
              write_state_d = WRITE_WE_FILL_TX_FIFO;
            end
          end
          WRITE_WE_FILL_TX_FIFO: begin
            // Write "write enable" command in tx_fifo
            spi_host_reg_req_offset  = SPI_HOST_TXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {19'b0, FC_WE};
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              write_state_d = WRITE_WE_WAIT_READY;
            end
          end
          WRITE_WE_WAIT_READY: begin
            // Wait for spi_host to be ready (command queue not busy) 
            if (external_spi_host_hw2reg_status_i.ready.d) begin
              write_state_d = WRITE_WE_SEND_CMD;
            end
          end
          WRITE_WE_SEND_CMD: begin
            // Send command to spi_host : send write enable command
            // COMMAND register format:
            //   [31:29] = Reserved
            //   [28:27] = Direction (2 = TX only)
            //   [24]    = CSAAT (0 = release CS after, WE is standalone command)
            //   [23:0]  = Length-1 (0 = 1 byte)
            spi_host_reg_req_offset = SPI_HOST_COMMAND_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {
              3'h0, 2'h2, 2'h0, 1'h0, 24'h0
            };  // Empty + Direction + Speed + Csaat + Length
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              write_state_d = WRITE_PP_CHECK_TX_FIFO;
            end
          end
          WRITE_PP_CHECK_TX_FIFO: begin
            // Proceed only if tx_fifo is not full, exploit direct access to spi_host status
            if (external_spi_host_hw2reg_status_i.txqd.d < SPI_FLASH_TX_FIFO_DEPTH[7:0]) begin
              write_state_d = WRITE_PP_FILL_TX_FIFO;
            end
          end
          WRITE_PP_FILL_TX_FIFO: begin
            // Write page program command + page address in tx_fifo
            spi_host_reg_req_offset = SPI_HOST_TXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            // Compute page address: sector base + sector offset + page offset
            spi_host_reg_req_o.wdata = bitfield_byteswap32(
											                      ({8'h0 , flash_addr_q} & 32'h00fff000) |
											                      ({28'h0, page_count_q} << 8)
										                    ) | {19'h0, FC_PP};
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              write_state_d = WRITE_PP_WAIT_READY;
            end
          end
          WRITE_PP_WAIT_READY: begin
            // Wait for spi_host to be ready (command queue not busy) 
            if (external_spi_host_hw2reg_status_i.ready.d) begin
              write_state_d = WRITE_PP_SEND_CMD;
            end
          end
          WRITE_PP_SEND_CMD: begin
            // Send command to spi_host : send page program command + address to flash 
            // COMMAND register format:
            //   [31:29] = Reserved
            //   [28:27] = Direction (2 = TX only)
            //   [24]    = CSAAT (1 = keep CS asserted for next command)
            //   [23:0]  = Length-1 (3 = 4 bytes: 1 cmd + 3 addr)
            spi_host_reg_req_offset = SPI_HOST_COMMAND_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {
              3'h0, 2'h2, 2'h0, 1'h1, 24'h3
            };  // Empty + Direction + Speed + Csaat + Length
            // Reset word counter
            word_count_d = 0;
            // Reset sector buffer latency cycles counter
            wait_latency_count_d = 0;
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              write_state_d = WRITE_PP_PAGE_WRITE_1;
            end
          end
          WRITE_PP_PAGE_WRITE_1: begin
            // Send read request to the sector buffer and wait for its Latency cycles before sampling the read data in a buffer
            sect_buffer_req = 1'b1;
            sect_buffer_we = 1'b0;
            sect_buffer_addr = '0 + page_count_q + word_count_q;
            // Count the latency to sample the rdata in the right cycle
            wait_latency_count_d = wait_latency_count_q + 1;
            // Next state evaluation
            if (wait_latency_count_q == SectorBufferLatency) begin
              write_state_d = WRITE_PP_PAGE_WRITE_2;
            end
          end
          WRITE_PP_PAGE_WRITE_2: begin
            wait_latency_count_d = 0; // Reset latency counter
            // Store read content in the sector buffer's buffer (single register)
            sec_buf_buffer_d = sect_buffer_rdata;
            // Next state evaluation
            write_state_d = WRITE_PP_PAGE_WRITE_3;
          end
          WRITE_PP_PAGE_WRITE_3: begin
            // Proceed only if tx_fifo is not full, exploit direct access to spi_host status
            if (external_spi_host_hw2reg_status_i.txqd.d < SPI_FLASH_TX_FIFO_DEPTH[7:0]) begin
              write_state_d = WRITE_PP_PAGE_WRITE_4;
            end
          end
          WRITE_PP_PAGE_WRITE_4: begin
            // send 32bit word to tx_fifo from the current page in the sector buffer
            spi_host_reg_req_offset = SPI_HOST_TXDATA_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = sec_buf_buffer_d;
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              word_count_d = word_count_q + 1;
              if (word_count_d == PAGE_WSIZE) begin
                page_count_d = page_count_q + 1;
              end
            end
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
              // complete page program
              if (word_count_d == PAGE_WSIZE) write_state_d = WRITE_PP_WAIT_READY_2;
              // load next word in tx_fifo
              if (word_count_d <  PAGE_WSIZE) write_state_d = WRITE_PP_PAGE_WRITE_1;
            end
          end
          WRITE_PP_WAIT_READY_2: begin
            // Wait for spi_host to be ready (command queue not busy)
            if (external_spi_host_hw2reg_status_i.ready.d) begin
              write_state_d = WRITE_PP_SEND_CMD_2;
            end
          end
          WRITE_PP_SEND_CMD_2: begin
            // Send command to spi_host: send direction and length of write operation
            // COMMAND register format:
            //   [31:29] = Reserved
            //   [28:27] = Direction (2 = TX only)
            //   [24]    = CSAAT (0 = release CS after transfer, no more commands to send)
            //   [23:0]  = Length-1 (255 = 256 bytes = 1 page)
            spi_host_reg_req_offset = SPI_HOST_COMMAND_OFFSET;
            spi_host_reg_req_o.write = 1'b1;
            spi_host_reg_req_o.valid = 1'b1;
            spi_host_reg_req_o.wdata = {
              3'h0, 2'h2, 2'h0, 1'h0, {11'b0, PAGE_BSIZE - 1'h1}
            };  // Empty + Direction + Speed + Csaat + Length
            // Next state evaluation
            if (spi_host_reg_rsp_i.ready && ~spi_host_reg_rsp_i.error) begin
                top_state_d = TOP_FWAIT;
                write_state_d = WRITE_IDLE;
            end
          end
          default: begin
            write_state_d = WRITE_IDLE;
          end
        endcase
      end
      // // AXIRESP FSM
      // Create a response to the manager from its last request, either on R or B channel
      TOP_AXIRESP: begin
        case(axiresp_state_q)
          AXIRESP_IDLE: begin
            // Reset beat counter
            beat_count_d = 0;
            // Next state evaluation
            if ( rnw_q) axiresp_state_d = AXIRESP_R;
            if (~rnw_q) axiresp_state_d = AXIRESP_B;
          end
          AXIRESP_B: begin
            // Respond to the  channel
            b_valid = 1'b1;
            // Next state evaluation
            if (b_ready) begin 
              axiresp_state_d = AXIRESP_IDLE;
              top_state_d = TOP_IDLE;
            end
          end
          AXIRESP_R: begin
            // Respond to the R channel
            // There needs to be handling done regarding the active byte lanes of the axi data bus
            int n;
            if (axi2fls_rd_valid) begin
              logic [AddrWidth-1:0] beat_addr_at_beat_count;
              int   lower_byte_lane, upper_byte_lane;
              logic [AddrWidth-1:0] alligned_beat_addr = (first_beat_addr_q / beat_size_q) * beat_size_q;

              if (beat_count_q == 0) begin
                lower_byte_lane = first_beat_addr_q - (first_beat_addr_q / DataBytes)*DataBytes;
                upper_byte_lane = alligned_beat_addr - (first_beat_addr_q / DataBytes)*DataBytes + (beat_size_q - 1);
              end
              if (beat_count_q > 0) begin
                beat_addr_at_beat_count = alligned_beat_addr + (beat_count_q)*beat_size_q;
                lower_byte_lane = beat_addr_at_beat_count - (first_beat_addr_q / DataBytes)*DataBytes;
                upper_byte_lane = lower_byte_lane + (beat_size_q - 1); 
              end
              r_valid = 1'b1;
              r_data = '0;
              n = 0;
              for (int i = lower_byte_lane ; i <= upper_byte_lane ; i++) begin
                // r_data[i*8+7:i*8] = axi2fls_rd_data[n*8+7:n*8];
                r_data[i*8 +: 8] = axi2fls_rd_data[n*8 +: 8];
                n++;
              end
              if (beat_count_d == beat_number_q)  begin 
                r_last = 1'b1;
              end
              if (r_ready) begin
                beat_count_d = beat_count_q + 1;
                axi2fls_rd_ready = 1'b1;
              end
            end
            // Next state evaluation
            if ( axi2fls_rd_valid && r_ready && (beat_count_d == beat_number_q) ) begin
              top_state_d = TOP_IDLE;
              axiresp_state_d = AXIRESP_IDLE;
            end
          end
          default:begin
            axiresp_state_d = AXIRESP_IDLE;
          end
        endcase
      end
      default: begin
        top_state_d = TOP_IDLE;
      end
    endcase
  end

  // // AXI beat queues
  // Data from axi w channel is stored beat by beat inside the queue to be written separatedly
  
  logic [DataWidth-1:0] axi2fls_wr_data;
  logic [DataBytes-1:0] axi2fls_wr_be;
  logic                 axi2fls_wr_valid;
  logic                 axi2fls_wr_ready;

  logic [DataWidth-1:0] spihost_wr_data;
  logic [DataBytes-1:0] spihost_wr_be;
  logic                 spihost_wr_valid;
  logic                 spihost_wr_ready;

  logic [DataWidth-1:0] spihost_rd_data;
  logic                 spihost_rd_valid;
  logic                 spihost_rd_ready;

  logic [DataWidth-1:0] axi2fls_rd_data;
  logic                 axi2fls_rd_valid;
  logic                 axi2fls_rd_ready;

  logic [7:0] wr_qd, rd_qd;

  logic wr_empty, wr_full;
  logic rd_empty, rd_full;
  logic clear_queues;
  
  axi_to_flash_beat_queues #(
    .DataWidth,
    .WrDepth(MaxBeats),
    .RdDepth(MaxBeats),
    .SwapBytes(~ByteOrder)
  ) beat_queues_i (
    .clk_i,
    .rst_ni,

    .axi2fls_wr_data_i         (axi2fls_wr_data),
    .axi2fls_wr_be_i           (axi2fls_wr_be),
    .axi2fls_wr_valid_i        (axi2fls_wr_valid),
    .axi2fls_wr_ready_o        (axi2fls_wr_ready),

    .spihost_wr_data_o         (spihost_wr_data),
    .spihost_wr_be_o           (spihost_wr_be),
    .spihost_wr_valid_o        (spihost_wr_valid),
    .spihost_wr_ready_i        (spihost_wr_ready),

    .spihost_rd_data_i         (spihost_rd_data),
    .spihost_rd_valid_i        (spihost_rd_valid),
    .spihost_rd_ready_o        (spihost_rd_ready),

    .axi2fls_rd_data_o         (axi2fls_rd_data),
    .axi2fls_rd_valid_o        (axi2fls_rd_valid),
    .axi2fls_rd_ready_i        (axi2fls_rd_ready),

    .wr_watermark_i            (),
    .rd_watermark_i            (),

    .wr_empty_o                (wr_empty),
    .wr_full_o                 (wr_full),
    .wr_qd_o                   (wr_qd),
    .wr_wm_o                   (),
    .rd_empty_o                (rd_empty),
    .rd_full_o                 (rd_full),
    .rd_qd_o                   (rd_qd),
    .rd_wm_o                   (),

    .clear_i                  (clear_queues)
);

  // // Sector buffer scratchpad

  localparam int SectorBuffer_AddrWidth = sizeInBits(SE_WSIZE);
  localparam int SectorBuffer_DataWidth = 32;
  localparam int SectorBuffer_DataBytes = SectorBuffer_DataWidth/8;

  logic                              sect_buffer_req;
  logic                              sect_buffer_we;
  logic [SectorBuffer_DataWidth-1:0] sect_buffer_wdata;
  logic [SectorBuffer_DataBytes-1:0] sect_buffer_be;
  logic [AddrWidth-1:0]              sect_buffer_addr;
  logic [SectorBuffer_DataWidth-1:0] sect_buffer_rdata;

  logic [SectorBuffer_AddrWidth-1:0] sect_buffer_addr_resized;
  assign sect_buffer_addr_resized = sect_buffer_addr[SectorBuffer_AddrWidth-1:0];

  sram_wrapper #(
      .NumWords(SE_WSIZE),
      .DataWidth(SectorBuffer_DataWidth),
  ) sector_buffer_i (
      .clk_i,
      .rst_ni,
      .req_i(sect_buffer_req),
      .we_i(sect_buffer_we),
      .addr_i(sect_buffer_addr_resized),
      .wdata_i(sect_buffer_wdata),
      .be_i(sect_buffer_be),
      .rdata_o(sect_buffer_rdata)
  );

endmodule