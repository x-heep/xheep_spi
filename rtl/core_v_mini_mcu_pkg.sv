package core_v_mini_mcu_pkg;
    
    localparam Parallelism = 32+32*1;
    
    localparam int CLK_F = 1e9;

    localparam logic [AddrWidth-1:0] SPI_FLASH_START_ADDRESS = '0;

endpackage