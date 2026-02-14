.section .data
    base:     .double 2.0
    exponent: .double 3.0
    fmt:      .string "Result: %f\n" 

.section .text
.globl main

main:
    pushq %rbp
    movq %rsp, %rbp

    # 1. Load arguments for pow(base, exponent)
    movsd base(%rip), %xmm0      
    movsd exponent(%rip), %xmm1  

    # 2. Call pow
    call pow@PLT

    # 3. Prepare to call printf
    lea fmt(%rip), %rdi    # Arg 1: The format string
    movb $1, %al           # IMPORTANT: Tell printf there is 1 float argument in XMM0
    
    call printf@PLT
    
    # Return 0 from main
    movl $0, %eax
    leave
    ret
