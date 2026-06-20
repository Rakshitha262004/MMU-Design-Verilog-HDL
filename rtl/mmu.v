// =====================================================================
// Module      : mmu
// Description : Memory Management Unit - Virtual to Physical Address
//               Translation with Page Table, Valid Bit, and Permission
//               Checking
//
// Author      : Rakshitha A S (1AH23CY042)
// Project     : MMU Design using Verilog HDL
// =====================================================================
//
// ADDRESS FORMAT
// --------------
// Virtual Address  (16-bit) : [15:8] Page Number | [7:0]  Offset
// Physical Address (16-bit) : [15:8] Frame Number | [7:0]  Offset
// Page Size                 : 256 bytes  (offset = 8 bits)
// Page Table Size           : 256 entries (2^8 pages)
//
// PAGE TABLE ENTRY FORMAT (10 bits per entry)
// --------------------------------------------
//  Bit 9   : Valid bit       (1 = page present in memory)
//  Bit 8   : Write permission (1 = write allowed)
//  Bit 7   : Read permission  (1 = read allowed)
//  Bits 6:0+Frame : Frame number (8 bits, stored in bits [7:0] separately
//                    -- see packed entry layout below)
//
// To keep the table simple and synthesizable, each entry is stored as:
//   entry[17:10] = frame number (8 bits)
//   entry[9]     = valid bit
//   entry[8]     = write permission
//   entry[7]     = read permission
//   entry[6:0]   = unused / reserved
// =====================================================================

module mmu #(
    parameter VA_WIDTH   = 16,   // Virtual address width
    parameter PA_WIDTH   = 16,   // Physical address width
    parameter OFFSET_BITS = 8,   // Bits used for page offset
    parameter PAGE_BITS  = VA_WIDTH - OFFSET_BITS,  // Page number bits
    parameter FRAME_BITS = PA_WIDTH - OFFSET_BITS,  // Frame number bits
    parameter NUM_PAGES  = (1 << PAGE_BITS)         // Number of page table entries
)(
    input  wire                     clk,
    input  wire                     rst_n,        // active-low reset
    input  wire                     enable,       // translation request enable
    input  wire [VA_WIDTH-1:0]      virtual_addr, // incoming virtual address
    input  wire                     access_type,  // 0 = read, 1 = write

    // Page table programming interface (used to load entries via testbench
    // or an external loader — mimics how an OS would populate the table)
    input  wire                     pt_write_en,
    input  wire [PAGE_BITS-1:0]     pt_write_index,
    input  wire [FRAME_BITS-1:0]    pt_write_frame,
    input  wire                     pt_write_valid,
    input  wire                     pt_write_read_perm,
    input  wire                     pt_write_write_perm,

    output reg  [PA_WIDTH-1:0]      physical_addr,
    output reg                      page_fault,        // page not valid
    output reg                      protection_fault,  // permission denied
    output reg                      translation_valid  // successful translation
);

    // -----------------------------------------------------------------
    // Page Table Storage
    // Each entry packs: { frame_number , valid , write_perm , read_perm }
    // Width = FRAME_BITS + 3
    // -----------------------------------------------------------------
    localparam ENTRY_WIDTH = FRAME_BITS + 3;

    reg [ENTRY_WIDTH-1:0] page_table [0:NUM_PAGES-1];

    integer i;

    // -----------------------------------------------------------------
    // Page Table Initialization / Programming
    // Synchronous write port so the testbench (acting like an OS) can
    // load page table entries before requesting translations.
    // -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_PAGES; i = i + 1) begin
                page_table[i] <= {ENTRY_WIDTH{1'b0}}; // all pages invalid on reset
            end
        end else if (pt_write_en) begin
            page_table[pt_write_index] <= { pt_write_frame,
                                             pt_write_valid,
                                             pt_write_write_perm,
                                             pt_write_read_perm };
        end
    end

    // -----------------------------------------------------------------
    // Address Translation (combinational)
    // -----------------------------------------------------------------
    wire [PAGE_BITS-1:0]   page_number;
    wire [OFFSET_BITS-1:0] page_offset;
    wire [ENTRY_WIDTH-1:0] entry;
    wire                   entry_valid;
    wire                   entry_write_perm;
    wire                   entry_read_perm;
    wire [FRAME_BITS-1:0]  entry_frame;

    assign page_number = virtual_addr[VA_WIDTH-1 : OFFSET_BITS];
    assign page_offset = virtual_addr[OFFSET_BITS-1 : 0];

    assign entry            = page_table[page_number];
    assign entry_read_perm  = entry[0];
    assign entry_write_perm = entry[1];
    assign entry_valid      = entry[2];
    assign entry_frame      = entry[ENTRY_WIDTH-1 : 3];

    // -----------------------------------------------------------------
    // Output Generation
    // Priority: page_fault > protection_fault > successful translation
    // -----------------------------------------------------------------
    always @(*) begin
        if (!enable) begin
            physical_addr      = {PA_WIDTH{1'b0}};
            page_fault         = 1'b0;
            protection_fault   = 1'b0;
            translation_valid  = 1'b0;
        end
        else if (!entry_valid) begin
            // Page not present -> page fault
            physical_addr      = {PA_WIDTH{1'b0}};
            page_fault         = 1'b1;
            protection_fault   = 1'b0;
            translation_valid  = 1'b0;
        end
        else if ((access_type == 1'b0 && !entry_read_perm) ||
                 (access_type == 1'b1 && !entry_write_perm)) begin
            // Page valid but permission denied -> protection fault
            physical_addr      = {PA_WIDTH{1'b0}};
            page_fault         = 1'b0;
            protection_fault   = 1'b1;
            translation_valid  = 1'b0;
        end
        else begin
            // Successful translation
            physical_addr      = {entry_frame, page_offset};
            page_fault         = 1'b0;
            protection_fault   = 1'b0;
            translation_valid  = 1'b1;
        end
    end

endmodule