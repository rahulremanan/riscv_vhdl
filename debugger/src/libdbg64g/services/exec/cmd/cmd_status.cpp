/**
 * @file
 * @copyright  Copyright 2017 GNSS Sensor Ltd. All right reserved.
 * @author     Sergey Khabarov - sergeykhbr@gmail.com
 * @brief      Read target's status register.
 */

#include "cmd_status.h"

namespace debugger {

CmdStatus::CmdStatus(ITap *tap, ISocInfo *info) 
    : ICommand ("status", tap, info) {

    briefDescr_.make_string("Read target's status register");
    detailedDescr_.make_string(
        "Description:\n"
        "    Read target's status register as a uint64_t value.\n"
        "    Status register bits:\n"
        "        [0]     - Halt bit. 0 = running; 1 = is halted.\n"
        "        [1]     - Stepping mode enable bit.\n"
        "        [2]     - Breakpoint hit signaling bit.\n"
        "        [19:4]  - Core ID hardwired value.\n"
        "Example:\n"
        "    status\n");
}

bool CmdStatus::isValid(AttributeType *args) {
    if ((*args)[0u].is_equal(cmdName_.to_string()) && args->size() == 1) {
        return CMD_VALID;
    }
    return CMD_INVALID;
}

void CmdStatus::exec(AttributeType *args, AttributeType *res) {
    if (!isValid(args)) {
        generateError(res, "Wrong argument list");
        return;
    }
    res->make_nil();

    Reg64Type t1;
    DsuMapType *pdsu = info_->getpDsu();
    uint64_t addr = reinterpret_cast<uint64_t>(&pdsu->udbg.v.control);
    if (tap_->read(addr, 8, t1.buf) == TAP_ERROR) {
        return;
    }
    res->make_uint64(t1.val);

#if 0
    // Instr trace info
    addr = reinterpret_cast<uint64_t>(pdsu->ureg.v.instr_buf);
    AttributeType t2;
    t2.make_data(4*8);
    if (tap_->read(addr, 4*8, t2.data()) == TAP_ERROR) {
        return;
    }
    Reg64Type *instr = reinterpret_cast<Reg64Type *>(t2.data());
    RISCV_printf(0, 0, "    3. [%08x] %08x", instr[3].buf32[1], instr[3].buf32[0]);
    RISCV_printf(0, 0, "    2. [%08x] %08x", instr[2].buf32[1], instr[2].buf32[0]);
    RISCV_printf(0, 0, "    1. [%08x] %08x", instr[1].buf32[1], instr[1].buf32[0]);
    RISCV_printf(0, 0, "    0. [%08x] %08x", instr[0].buf32[1], instr[0].buf32[0]);
#endif
}

}  // namespace debugger
