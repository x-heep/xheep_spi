package core_v_mini_mcu_pkg;
    
    localparam Parallelism = 32+32*1;
    
    localparam int MAX_CLK_F = 1e9;

    localparam logic [63:0] SPI_FLASH_START_ADDRESS = '0;

endpackage