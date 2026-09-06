import Foundation

/// Direct port of Communication/J2534/Uds/Sa2SeedKeyVm.cs, which itself is
/// ported from the `sa2-seed-key` PyPI package VW_Flash depends on for the
/// VW "SA2" Seed/Key Security Access algorithm. A tiny bytecode VM: the "SA2
/// script" (a per-ECU byte sequence baked into Simos18ModuleInfo /
/// Simos1810ModuleInfo) is a program for a single 32-bit register machine
/// with add/sub/xor/rotate/for-loop/branch instructions. Feed it the ECU's
/// seed as the initial register value, run it to completion, and the final
/// register value is the key.
final class Sa2SeedKeyVm {
    enum VmError: Error, LocalizedError {
        case unknownOpcode(UInt8, Int)
        var errorDescription: String? {
            switch self {
            case .unknownOpcode(let op, let offset):
                return String(format: "Unknown SA2 script opcode 0x%02X at offset %d.", op, offset)
            }
        }
    }

    private let instructionTape: [UInt8]
    private var register: UInt32
    private var carryFlag: UInt32 = 0
    private var instructionPointer = 0

    private var forPointers: [Int] = []
    private var forIterations: [Int] = []

    init(instructionTape: [UInt8], seed: UInt32) {
        self.instructionTape = instructionTape
        self.register = seed
    }

    private func rsl() { // rotate-shift-left, opcode 0x81
        carryFlag = register & 0x80000000
        register = register << 1
        if carryFlag != 0 { register |= 0x1 }
        instructionPointer += 1
    }

    private func rsr() { // rotate-shift-right, opcode 0x82
        carryFlag = register & 0x1
        register = register >> 1
        if carryFlag != 0 { register |= 0x80000000 }
        instructionPointer += 1
    }

    private func add() { // opcode 0x93
        carryFlag = 0
        let addInt = readOperandU32(instructionPointer + 1)
        let result = UInt64(register) + UInt64(addInt)
        if result > 0xFFFFFFFF { carryFlag = 1 }
        register = UInt32(result & 0xFFFFFFFF)
        instructionPointer += 5
    }

    private func sub() { // opcode 0x84
        carryFlag = 0
        let subInt = readOperandU32(instructionPointer + 1)
        let result = Int64(register) - Int64(subInt)
        if result < 0 { carryFlag = 1 }
        register = UInt32(bitPattern: Int32(truncatingIfNeeded: result))
        instructionPointer += 5
    }

    private func eor() { // xor, opcode 0x87
        let xorInt = readOperandU32(instructionPointer + 1)
        register ^= xorInt
        instructionPointer += 5
    }

    private func forLoop() { // opcode 0x68
        let iterationCount = instructionTape[instructionPointer + 1]
        forIterations.append(Int(iterationCount) - 1)
        instructionPointer += 2
        forPointers.append(instructionPointer)
    }

    private func nextLoop() { // opcode 0x49
        if let top = forIterations.last, top > 0 {
            forIterations[forIterations.count - 1] = top - 1
            instructionPointer = forPointers.last!
        } else {
            forIterations.removeLast()
            forPointers.removeLast()
            instructionPointer += 1
        }
    }

    private func bcc() { // branch-if-carry-clear, opcode 0x4A
        let operand = instructionTape[instructionPointer + 1]
        let skipCount = Int(operand) + 2
        instructionPointer += (carryFlag == 0) ? skipCount : 2
    }

    private func bra() { // branch unconditional, opcode 0x6B
        let operand = instructionTape[instructionPointer + 1]
        instructionPointer += Int(operand) + 2
    }

    private func finish() { // opcode 0x4C
        instructionPointer += 1
    }

    private func readOperandU32(_ offset: Int) -> UInt32 {
        (UInt32(instructionTape[offset]) << 24)
            | (UInt32(instructionTape[offset + 1]) << 16)
            | (UInt32(instructionTape[offset + 2]) << 8)
            | UInt32(instructionTape[offset + 3])
    }

    /// Runs the script to completion and returns the final register value (the key).
    func execute() throws -> UInt32 {
        while instructionPointer < instructionTape.count {
            let opcode = instructionTape[instructionPointer]
            switch opcode {
            case 0x81: rsl()
            case 0x82: rsr()
            case 0x93: add()
            case 0x84: sub()
            case 0x87: eor()
            case 0x68: forLoop()
            case 0x49: nextLoop()
            case 0x4A: bcc()
            case 0x6B: bra()
            case 0x4C: finish()
            default:
                throw VmError.unknownOpcode(opcode, instructionPointer)
            }
        }
        return register
    }
}
