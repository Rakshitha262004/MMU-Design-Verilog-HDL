// =====================================================================
// Testbench   : mmu_tb
// DUT         : mmu
// Description : Verifies valid translation, page fault, protection
//               fault (read & write), and boundary address cases.
// =====================================================================
`timescale 1ns / 1ps

module mmu_tb;

    // Parameters matching DUT
    localparam VA_WIDTH    = 16;
    localparam PA_WIDTH    = 16;
    localparam OFFSET_BITS = 8;
    localparam PAGE_BITS   = VA_WIDTH - OFFSET_BITS;
    localparam FRAME_BITS  = PA_WIDTH - OFFSET_BITS;

    // DUT signals
    reg                     clk;
    reg                     rst_n;
    reg                     enable;
    reg  [VA_WIDTH-1:0]     virtual_addr;
    reg                     access_type;

    reg                     pt_write_en;
    reg  [PAGE_BITS-1:0]    pt_write_index;
    reg  [FRAME_BITS-1:0]   pt_write_frame;
    reg                     pt_write_valid;
    reg                     pt_write_read_perm;
    reg                     pt_write_write_perm;

    wire [PA_WIDTH-1:0]     physical_addr;
    wire                    page_fault;
    wire                    protection_fault;
    wire                    translation_valid;

    integer                 test_num;
    integer                 errors;

    // -----------------------------------------------------------------
    // DUT Instantiation
    // -----------------------------------------------------------------
    mmu #(
        .VA_WIDTH(VA_WIDTH),
        .PA_WIDTH(PA_WIDTH),
        .OFFSET_BITS(OFFSET_BITS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .virtual_addr(virtual_addr),
        .access_type(access_type),
        .pt_write_en(pt_write_en),
        .pt_write_index(pt_write_index),
        .pt_write_frame(pt_write_frame),
        .pt_write_valid(pt_write_valid),
        .pt_write_read_perm(pt_write_read_perm),
        .pt_write_write_perm(pt_write_write_perm),
        .physical_addr(physical_addr),
        .page_fault(page_fault),
        .protection_fault(protection_fault),
        .translation_valid(translation_valid)
    );

    // -----------------------------------------------------------------
    // Clock generation: 10ns period
    // -----------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -----------------------------------------------------------------
    // Task: load a page table entry
    // -----------------------------------------------------------------
    task load_entry(
        input [PAGE_BITS-1:0]  index,
        input [FRAME_BITS-1:0] frame,
        input                  valid_b,
        input                  read_b,
        input                  write_b
    );
        begin
            @(negedge clk);
            pt_write_en          = 1'b1;
            pt_write_index       = index;
            pt_write_frame       = frame;
            pt_write_valid       = valid_b;
            pt_write_read_perm   = read_b;
            pt_write_write_perm  = write_b;
            @(negedge clk);
            pt_write_en          = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------
    // Task: apply a translation request and check result
    // -----------------------------------------------------------------
    task check_translation(
        input [VA_WIDTH-1:0] va,
        input                acc_type,
        input                exp_translation_valid,
        input                exp_page_fault,
        input                exp_protection_fault,
        input [PA_WIDTH-1:0] exp_pa,
        input [127:0]        test_name
    );
        begin
            test_num = test_num + 1;
            @(negedge clk);
            enable        = 1'b1;
            virtual_addr  = va;
            access_type   = acc_type;
            #1; // allow combinational logic to settle

            if (translation_valid !== exp_translation_valid ||
                page_fault        !== exp_page_fault        ||
                protection_fault  !== exp_protection_fault  ||
                (exp_translation_valid && physical_addr !== exp_pa)) begin
                errors = errors + 1;
                $display("[FAIL] Test %0d (%0s): VA=%h ACC=%b -> PA=%h valid=%b pf=%b prot=%b | EXPECTED PA=%h valid=%b pf=%b prot=%b",
                          test_num, test_name, va, acc_type,
                          physical_addr, translation_valid, page_fault, protection_fault,
                          exp_pa, exp_translation_valid, exp_page_fault, exp_protection_fault);
            end else begin
                $display("[PASS] Test %0d (%0s): VA=%h ACC=%b -> PA=%h valid=%b pf=%b prot=%b",
                          test_num, test_name, va, acc_type,
                          physical_addr, translation_valid, page_fault, protection_fault);
            end

            @(negedge clk);
            enable = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------
    // Main Test Sequence
    // -----------------------------------------------------------------
    initial begin
        $dumpfile("mmu_waveform.vcd");
        $dumpvars(0, mmu_tb);

        test_num = 0;
        errors   = 0;

        // Initialize
        rst_n                = 0;
        enable               = 0;
        virtual_addr         = 0;
        access_type          = 0;
        pt_write_en          = 0;
        pt_write_index       = 0;
        pt_write_frame       = 0;
        pt_write_valid       = 0;
        pt_write_read_perm   = 0;
        pt_write_write_perm  = 0;

        // Apply reset (clears entire page table to invalid)
        repeat (2) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // -------------------------------------------------------------
        // Program the page table (acts like the OS setting up mappings)
        // -------------------------------------------------------------
        // Page 0  -> Frame 0x10, valid, read+write   (normal RW page)
        load_entry(8'h00, 8'h10, 1'b1, 1'b1, 1'b1);
        // Page 1  -> Frame 0x20, valid, read-only
        load_entry(8'h01, 8'h20, 1'b1, 1'b1, 1'b0);
        // Page 2  -> left invalid intentionally (not loaded) -> page fault test
        // Page 255 (0xFF) -> Frame 0xAA, valid, read+write (boundary test)
        load_entry(8'hFF, 8'hAA, 1'b1, 1'b1, 1'b1);

        // -------------------------------------------------------------
        // TEST 1: Valid translation, read access on Page 0
        // VA = page0 | offset 0x05  -> PA = frame 0x10 | offset 0x05
        // -------------------------------------------------------------
        check_translation(16'h0005, 1'b0, 1'b1, 1'b0, 1'b0, 16'h1005, "Valid_Read_Page0");

        // -------------------------------------------------------------
        // TEST 2: Valid translation, write access on Page 0 (RW page)
        // -------------------------------------------------------------
        check_translation(16'h0042, 1'b1, 1'b1, 1'b0, 1'b0, 16'h1042, "Valid_Write_Page0");

        // -------------------------------------------------------------
        // TEST 3: Page fault — Page 2 was never loaded (valid bit = 0)
        // -------------------------------------------------------------
        check_translation(16'h0210, 1'b0, 1'b0, 1'b1, 1'b0, 16'h0000, "PageFault_Page2");

        // -------------------------------------------------------------
        // TEST 4: Protection fault — write attempt on read-only Page 1
        // -------------------------------------------------------------
        check_translation(16'h0107, 1'b1, 1'b0, 1'b0, 1'b1, 16'h0000, "ProtectionFault_WriteOnReadOnly");

        // -------------------------------------------------------------
        // TEST 5: Valid translation, read access on read-only Page 1
        // -------------------------------------------------------------
        check_translation(16'h0107, 1'b0, 1'b1, 1'b0, 1'b0, 16'h2007, "Valid_Read_ReadOnlyPage1");

        // -------------------------------------------------------------
        // TEST 6: Boundary address — highest page (0xFF), max offset
        // -------------------------------------------------------------
        check_translation(16'hFFFF, 1'b0, 1'b1, 1'b0, 1'b0, 16'hAAFF, "Boundary_MaxPage_MaxOffset");

        // -------------------------------------------------------------
        // TEST 7: Boundary address — highest page (0xFF), zero offset
        // -------------------------------------------------------------
        check_translation(16'hFF00, 1'b1, 1'b1, 1'b0, 1'b0, 16'hAA00, "Boundary_MaxPage_ZeroOffset");

        // -------------------------------------------------------------
        // TEST 8: Disabled translation request (enable = 0)
        // -------------------------------------------------------------
        test_num = test_num + 1;
        @(negedge clk);
        enable       = 1'b0;
        virtual_addr = 16'h0005;
        access_type  = 1'b0;
        #1;
        if (translation_valid !== 1'b0 || page_fault !== 1'b0 || protection_fault !== 1'b0) begin
            errors = errors + 1;
            $display("[FAIL] Test %0d (Disabled_Enable): outputs not idle", test_num);
        end else begin
            $display("[PASS] Test %0d (Disabled_Enable): outputs correctly idle", test_num);
        end

        // -------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------
        $display("-----------------------------------------------------");
        if (errors == 0)
            $display("ALL %0d TESTS PASSED", test_num);
        else
            $display("%0d OF %0d TESTS FAILED", errors, test_num);
        $display("-----------------------------------------------------");

        #20;
        $finish;
    end

endmodule