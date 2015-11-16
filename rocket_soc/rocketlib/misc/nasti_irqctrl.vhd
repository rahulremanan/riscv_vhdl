-----------------------------------------------------------------------------
--! @file
--! @copyright Copyright 2015 GNSS Sensor Ltd. All right reserved.
--! @author    Sergey Khabarov - sergeykhbr@gmail.com
--! @brief     Interrupt controller with the AXI4 interface
--! @details   This module generates CPU interrupt emitting write message into
--!            CSR register 'send_ipi' via HostIO bus interface.
-----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library commonlib;
use commonlib.types_common.all;
library rocketlib;
use rocketlib.types_rocket.all;
use rocketlib.types_nasti.all;

entity nasti_irqctrl is
  generic (
    xindex   : integer := 0;
    xaddr    : integer := 0;
    xmask    : integer := 16#fffff#;
    L2_ena   : boolean := false
  );
  port 
 (
    clk    : in std_logic;
    nrst   : in std_logic;
    i_irqs : in std_logic_vector(CFG_IRQ_TOTAL-1 downto 0);
    o_cfg  : out nasti_slave_config_type;
    i_axi  : in nasti_slave_in_type;
    o_axi  : out nasti_slave_out_type;
    i_host : in host_out_type;
    o_host : out host_in_type
  );
end;

architecture nasti_irqctrl_rtl of nasti_irqctrl is

  --! 4-bytes alignment so that all registers implemented as 32-bits
  --! width.
  constant ALIGNMENT_BYTES : integer := 4;
  constant HTIF_DATA_ZERO : std_logic_vector(HTIF_WIDTH-1 downto 0) := (others => '0');

  constant xconfig : nasti_slave_config_type := (
     xindex => xindex,
     xaddr => conv_std_logic_vector(xaddr, CFG_NASTI_CFG_ADDR_BITS),
     xmask => conv_std_logic_vector(xmask, CFG_NASTI_CFG_ADDR_BITS),
     vid => VENDOR_GNSSSENSOR,
     did => GNSSSENSOR_IRQCTRL
  );

  type local_addr_array_type is array (0 to CFG_NASTI_DATA_BYTES/ALIGNMENT_BYTES-1) 
       of integer;

--! data, addr(core=0),  seqno=IDX, words=1, cmd=HTIF_CMD_WRITE_CONTROL_REG
constant CSR_WR1_CSR29 : std_logic_vector(127 downto 0) := 
    X"0000000000000001" & (X"000000050e" & X"02" & X"001" & X"3"); 

type state_type is (idle, busy);

type registers is record
  bank_axi : nasti_slave_bank_type;
  
  host_reset : std_logic_vector(1 downto 0);
  --! Message multiplexer to form 128 request message of writting into CSR
  host_msg : std_logic_vector(127 downto 0);
  seqno    : std_logic_vector(7 downto 0);
  beat_cnt : integer range 0 to 128/HTIF_WIDTH-1;
  state         : state_type;
  --! interrupt signal delay signal to detect interrupt positive edge
  irqs_z        : std_logic_vector(CFG_IRQ_TOTAL-1 downto 0);  
  irqs_zz       : std_logic_vector(CFG_IRQ_TOTAL-1 downto 0);  

  --! mask irq disabled: 1=disabled; 0=enabled
  irqs_mask     : std_logic_vector(CFG_IRQ_TOTAL-1 downto 0);
  --! irq pending bit mask
  irqs_pending  : std_logic_vector(CFG_IRQ_TOTAL-1 downto 0);
  -- interrupt handler address initialized by FW:
  irq_handler   : std_logic_vector(63 downto 0);
end record;

signal r, rin: registers;
begin

  comblogic : process(i_irqs, i_axi, i_host, r)
    variable v : registers;
    variable raddr_reg : local_addr_array_type;
    variable waddr_reg : local_addr_array_type;
    variable rdata : std_logic_vector(CFG_NASTI_DATA_BITS-1 downto 0);
    variable wdata : std_logic_vector(CFG_NASTI_DATA_BITS-1 downto 0);
    variable wstrb : std_logic_vector(CFG_NASTI_DATA_BYTES-1 downto 0);
    variable val : std_logic_vector(8*ALIGNMENT_BYTES-1 downto 0);

    variable wCmd : std_logic_vector(127 downto 0);
    variable w_generate_ipi : std_logic;
  begin
    v := r;
    w_generate_ipi := '0';

    procedureAxi4(i_axi, xconfig, r.bank_axi, v.bank_axi);

    for n in 0 to CFG_NASTI_DATA_BYTES/ALIGNMENT_BYTES-1 loop
       raddr_reg(n) := conv_integer(r.bank_axi.raddr(ALIGNMENT_BYTES*n)(11 downto log2(ALIGNMENT_BYTES)));
       val := (others => '0');
       case raddr_reg(n) is
         when 0      => val(CFG_IRQ_TOTAL-1 downto 0) := r.irqs_mask;     --! [RW]: 1=irq disable; 0=enable
         when 1      => val(CFG_IRQ_TOTAL-1 downto 0) := r.irqs_pending;  --! [RO]: Rised interrupts.
         when 2      => val := (others => '0');                           --! [WO]: Clear interrupts mask.
         when 3      => val := (others => '0');                           --! [WO]: Rise interrupts mask.
         when 4      => val := r.irq_handler(31 downto 0);                --! [RW]: LSB of the function address
         when 5      => val := r.irq_handler(63 downto 32);               --! [RW]: MSB of the function address
         when others => val := X"cafef00d";
       end case;
       rdata(8*ALIGNMENT_BYTES*(n+1)-1 downto 8*ALIGNMENT_BYTES*n) := val;
    end loop;

    if i_axi.w_valid = '1' and 
       r.bank_axi.wstate = wtrans and 
       r.bank_axi.wresp = NASTI_RESP_OKAY then

      wdata := i_axi.w_data;
      wstrb := i_axi.w_strb;
      for n in 0 to CFG_NASTI_DATA_BYTES/ALIGNMENT_BYTES-1 loop
         waddr_reg(n) := conv_integer(r.bank_axi.waddr(ALIGNMENT_BYTES*n)(11 downto 2));

         if conv_integer(wstrb(ALIGNMENT_BYTES*(n+1)-1 downto ALIGNMENT_BYTES*n)) /= 0 then
           val := wdata(8*ALIGNMENT_BYTES*(n+1)-1 downto 8*ALIGNMENT_BYTES*n);
           case waddr_reg(n) is
             when 0 => v.irqs_mask := val(CFG_IRQ_TOTAL-1 downto 0);
             when 1 =>     --! Read only
             when 2 => v.irqs_pending := r.irqs_pending and (not val(CFG_IRQ_TOTAL-1 downto 0));
             when 3 => 
                w_generate_ipi := '1';
                v.irqs_pending := (not r.irqs_mask) and val(CFG_IRQ_TOTAL-1 downto 0);
             when 4 => v.irq_handler(31 downto 0) := val;
             when 5 => v.irq_handler(63 downto 32) := val;
             when others =>
           end case;
         end if;
      end loop;
    end if;

    v.irqs_z := i_irqs;
    v.irqs_zz := r.irqs_z;
    for n in 0 to CFG_IRQ_TOTAL-1 loop
      if r.irqs_z(n) = '1' and r.irqs_zz(n) = '0'  then
         v.irqs_pending(n) := not r.irqs_mask(n);
         w_generate_ipi := w_generate_ipi or (not r.irqs_mask(n));
      end if;
    end loop;

   --! data, addr(core=0),  seqno=IDX, words=1, cmd=HTIF_CMD_WRITE_CONTROL_REG
    wCmd := X"0000000000000001" & (X"000000050e" & r.seqno & X"001" & X"3");

    case r.state is
      when idle =>
        if w_generate_ipi = '1' then
           v.state := busy;
           if L2_ena then
               v.host_msg := wCmd;
               v.seqno := r.seqno + 1;
               v.beat_cnt := 0;
           else
              --! do nothing
           end if;
        end if;
      when busy =>
        if i_host.csr_req_ready = '1' then
          if L2_ena then
              v.host_msg := HTIF_DATA_ZERO & r.host_msg(127 downto HTIF_WIDTH);
              v.beat_cnt := r.beat_cnt + 1;
              if r.beat_cnt = (128/HTIF_WIDTH) - 1 then
                 v.state := idle;
              end if;
          else
              v.state := idle;
          end if;
        end if;
      when others =>
    end case;

    o_axi <= functionAxi4Output(r.bank_axi, rdata);

    if r.state = idle then
      o_host.csr_req_valid     <= '0';
      o_host.csr_req_bits_rw   <= '0';
      o_host.csr_req_bits_addr <= (others => '0');
      o_host.csr_req_bits_data <= (others => '0');
    else
      o_host.csr_req_valid     <= '1';
      o_host.csr_req_bits_rw   <= '1';
      o_host.csr_req_bits_addr <= X"50e";   --! CSR address 'send_ipi'
      if L2_ena then
          o_host.csr_req_bits_data(63 downto HTIF_WIDTH) <= (others => '0');
          o_host.csr_req_bits_data(HTIF_WIDTH-1 downto 0) <= r.host_msg(HTIF_WIDTH-1 downto 0);
      else
          o_host.csr_req_bits_data <= X"0000000000000001";
      end if;
    end if;

    -- delayed reset    
    v.host_reset := r.host_reset(1) & '0';

    rin <= v;
  end process;

  o_cfg  <= xconfig;

  o_host.reset          <= r.host_reset(1);
  o_host.id             <= '0';
  o_host.csr_resp_ready <= '1';
  o_host.ipi_req_ready  <= '1';
  o_host.ipi_rep_valid  <= '0';
  o_host.ipi_rep_bits   <= '0';


  -- registers:
  regs : process(clk, nrst)
  begin 
    if nrst = '0' then 
       r.bank_axi <= NASTI_SLAVE_BANK_RESET;
       r.host_reset <= (others => '1');
       r.state <= idle;
       r.irqs_mask <= (others => '1'); -- all interrupts disabled
       r.irqs_pending <= (others => '0');
       r.irqs_z <= (others => '0');
       r.irqs_zz <= (others => '0');
       r.irq_handler <= (others => '0');
    elsif rising_edge(clk) then 
       r <= rin; 
    end if; 
  end process;
end;
