.syntax unified
.arm
.text
.global FramebufferStride
.hidden FramebufferStride
.type FramebufferStride,%function
FramebufferStride:
    mov r0, #6
    svc 0xc10000
    bx lr
.global PresentFramebuffer
.hidden PresentFramebuffer
.type PresentFramebuffer,%function
PresentFramebuffer:
    mov r0, #1
    svc 0xc10000
    bx lr
