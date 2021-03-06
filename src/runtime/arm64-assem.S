#include "globals.h"
#include "lispregs.h"
#include "sbcl.h"

#include "genesis/closure.h"
#include "genesis/funcallable-instance.h"
#include "genesis/fdefn.h"
#include "genesis/static-symbols.h"
#include "genesis/simple-fun.h"
#include "genesis/symbol.h"
#ifdef LISP_FEATURE_SB_THREAD
#include "genesis/thread.h"

// For LDP/STP to work right
#if THREAD_CONTROL_STACK_POINTER_OFFSET - THREAD_CONTROL_FRAME_POINTER_OFFSET != 8
#error "THREAD_CONTROL_FRAME_POINTER_OFFSET - THREAD_CONTROL_STACK_POINTER_OFFSET not sequential"
#endif

#endif

#define LOAD_STATIC_SYMBOL_VALUE(value,sym) \
        mov reg_TMP,((sym)-NIL+SYMBOL_VALUE_OFFSET) ;\
        ldr value,[reg_NULL, reg_TMP]

#define STORE_STATIC_SYMBOL_VALUE(value,sym) \
        mov reg_TMP,((sym)-NIL+SYMBOL_VALUE_OFFSET) ;\
        str value,[reg_NULL, reg_TMP]
#ifdef LISP_FEATURE_SB_THREAD
        #define ENTER_PA \
        str reg_wNULL,[reg_THREAD,THREAD_PSEUDO_ATOMIC_BITS_OFFSET]
#define LEAVE_PA \
        str wzr,[reg_THREAD,THREAD_PSEUDO_ATOMIC_BITS_OFFSET]       ;\
        ldr reg_wTMP,[reg_THREAD,THREAD_PSEUDO_ATOMIC_BITS_OFFSET+4] ;\
        cbz reg_wTMP,1f                                              ;\
	brk trap_PendingInterrupt                                   ;\
1:
#else
#define ENTER_PA \
        STORE_STATIC_SYMBOL_VALUE(reg_CFP,PSEUDO_ATOMIC_ATOMIC)

#define LEAVE_PA \
        STORE_STATIC_SYMBOL_VALUE(reg_NULL,PSEUDO_ATOMIC_ATOMIC) ;\
        LOAD_STATIC_SYMBOL_VALUE(reg_TMP,PSEUDO_ATOMIC_INTERRUPTED) ;\
        cbz reg_TMP, 1f     ; \
	brk trap_PendingInterrupt         ; \
1:
#endif
#ifdef LISP_FEATURE_SB_SAFEPOINT
/* the CSP page sits right before the thread */
# define THREAD_SAVED_CSP_OFFSET (-N_WORD_BYTES)
#endif
	.align
	.global	call_into_lisp
	.type	call_into_lisp, %function
call_into_lisp:
	// At this point, we have:
	// X0 - function
	// X1 - pointer to args
	// X2 - number of args (unboxed)
	// There will be no more than three args, so we don't need to
	// worry about parameters to be passed on the stack.

	// X19-X28 are callee-saved registers.

        stp     x19,x20, [sp,#-160]!
        stp     x21,x22, [sp,#16]
        stp     x23,x24, [sp,#32]
        stp     x25,x26, [sp,#48]
        stp     x27,x28, [sp,#64]
        stp     x29,x30, [sp,#80] // save the return address in x30 aka LR

        stp     d8,d9, [sp,#96]
        stp     d10,d11, [sp,#112]
        stp     d12,d13, [sp,#128]
        stp     d14,d15, [sp,#144]

	// Start by finding NIL.
	ldr	reg_NULL, =NIL

	// Set up NARGS.
	lsl	reg_NARGS, x2, #N_FIXNUM_TAG_BITS

	// Move args pointer out of the way of the args to be loaded.
	mov	reg_R9, x1

	// Move the function to its passing location.
	mov	reg_LEXENV, x0

#ifdef LISP_FEATURE_SB_THREAD
#ifdef LISP_FEATURE_GCC_TLS
	adrp	x0, :gottprel:current_thread
	ldr	x0, [x0, #:gottprel_lo12:current_thread]
	mrs	reg_THREAD, tpidr_el0
	ldr	reg_THREAD, [reg_THREAD,x0]
#else
        ldr	x0, specials
        bl      pthread_getspecific
        mov     reg_THREAD, x0
#endif
#else
        mov     reg_R10, #0
#endif
	// Clear the boxed registers that don't already have something
	// in them.
        mov     reg_R0, #0
        mov     reg_R1, #0
        mov     reg_R2, #0
        mov     reg_R3, #0
        mov     reg_R4, #0
        mov     reg_R5, #0
        mov     reg_R6, #0
        mov     reg_R7, #0
        mov     reg_R8, #0

        mov     reg_CODE, #0

	// Find the lisp stack and frame pointers.  We're allocating a
	// new lisp stack frame, so load the stack pointer into CFP.
#ifdef LISP_FEATURE_SB_THREAD
	ldp     reg_OCFP,reg_CFP, [reg_THREAD, THREAD_CONTROL_FRAME_POINTER_OFFSET]
#else
	ldr	reg_OCFP, =current_control_frame_pointer
	ldr	reg_CFP, =current_control_stack_pointer
	ldr	reg_OCFP, [reg_OCFP]
	ldr	reg_CFP, [reg_CFP]
#endif
        ENTER_PA


#ifndef LISP_FEATURE_GENCGC
        // Copy the current allocation pointer into the symbol.
        ldr     reg_NL3, =dynamic_space_free_pointer
        ldr     reg_NL3, [reg_NL3]
        STORE_STATIC_SYMBOL_VALUE(reg_NL3, ALLOCATION_POINTER)
#endif

	// Clear FFCA, so the runtime knows that we're "in lisp".
#ifdef LISP_FEATURE_SB_THREAD
        str     xzr,[reg_THREAD, THREAD_FOREIGN_FUNCTION_CALL_ACTIVE_OFFSET]
#else
	ldr     reg_NL3, =foreign_function_call_active
	str     xzr, [reg_NL3]
#endif
	// We need to set up the lisp stack pointer and the basics of
	// our stack frame while we're still in P-A.  Any sooner and
	// our stack frame can be clobbered by a stray interrupt, any
	// later and we can end up with a half-configured stack frame
	// when we catch a stray interrupt.

	// Allocate our frame and set up the Lisp stack pointer
        add     reg_CSP, reg_CFP, #16

	// Set up the "frame link"
	str     reg_OCFP, [reg_CFP]

	// Set up the return address
	ldr	reg_NL3, =.lra
        str     reg_NL3, [reg_CFP, #8]

	LEAVE_PA

	// Load our function args.
	cbz reg_NARGS, no_args
        cmp reg_NARGS, #2
        beq two_args
        bmi one_arg
three_args:
	ldr	reg_R2, [reg_R9, #16]
two_args:
	ldr	reg_R1, [reg_R9, #8]
one_arg:
	ldr	reg_R0, [reg_R9]
no_args:

        // Load the closure-fun (or simple-fun-self), in case we're
	// trying to call a closure.
        ldr     reg_CODE, [reg_LEXENV, #CLOSURE_FUN_OFFSET]

	// And, finally, call into Lisp!
	add	reg_LR, reg_CODE, #SIMPLE_FUN_INSTS_OFFSET
        br      reg_LR

	.align 4
	.equ	.lra, .+OTHER_POINTER_LOWTAG
	.dword	RETURN_PC_WIDETAG

	// Correct stack pointer for return processing.
        csel reg_CSP, reg_OCFP, reg_CSP, eq

        // Return value
        mov     x0, reg_R0

	ENTER_PA

// Save the lisp stack and frame pointers.
#ifdef LISP_FEATURE_SB_THREAD
	stp     reg_CFP,reg_CSP, [reg_THREAD, THREAD_CONTROL_FRAME_POINTER_OFFSET]
        str     reg_CSP, [reg_THREAD, THREAD_FOREIGN_FUNCTION_CALL_ACTIVE_OFFSET]
#else
	ldr	reg_NFP, =current_control_frame_pointer
	str	reg_CFP, [reg_NFP]
	ldr	reg_OCFP, =current_control_stack_pointer
	str	reg_CSP, [reg_OCFP]

	// Set FFCA, so the runtime knows that we're not "in lisp".
	ldr     reg_OCFP, =foreign_function_call_active
	str     reg_OCFP, [reg_OCFP]
#endif

#ifndef LISP_FEATURE_GENCGC
        // Copy the current allocation pointer out from the symbol.
        ldr     reg_OCFP, =dynamic_space_free_pointer
        LOAD_STATIC_SYMBOL_VALUE(reg_NFP, ALLOCATION_POINTER)
        str     reg_NFP, [reg_OCFP]
#endif

        LEAVE_PA

	// Restore saved registers.

        ldp     d14,d15, [sp,#144]
        ldp     d12,d13, [sp,#128]
        ldp     d10,d11, [sp,#112]
        ldp     d8,d9, [sp,#96]


        ldp     x29,x30, [sp,#80]
        ldp     x27,x28, [sp,#64]
        ldp     x25,x26, [sp,#48]
        ldp     x23,x24, [sp,#32]
        ldp     x21,x22, [sp,#16]
        ldp     x19,x20, [sp],#160

	ret
	.size	call_into_lisp, .-call_into_lisp


	.align
	.global	call_into_c
	.type	call_into_c, %function
call_into_c:
	// At this point, we have:
	// R8 -- C function to call.
        // LR -- Return address within the code component.
        // X0-X7 arguments
        // All other C arguments are already stashed on the C stack.

	// We need to convert our return address to a GC-safe format,
	// build a stack frame to count for the "foreign" frame,
	// switch to C mode, move the register arguments to the
        // correct locations, call the C function, move the result to
        // the correct location, switch back to Lisp mode, tear down
        // our stack frame, restore the return address, and return to
        // our caller.

        sub     reg_NARGS, reg_LR, reg_CODE
        add     reg_NFP, reg_NARGS, #OTHER_POINTER_LOWTAG

        // Build a Lisp stack frame.  We need to stash our frame link,
        // the code component, and our return offset.  Frame link goes
	// in slot 0 (OCFP-SAVE-OFFSET), the offset (a FIXNUM) goes in
        // slot 1 (LRA-SAVE-OFFSET), and reg_CODE goes in slot 2.  The
        // debugger knows about this layout (see COMPUTE-CALLING-FRAME
        // in SYS:SRC;CODE;DEBUG-INT.LISP).
        add     reg_CSP, reg_CSP, #4*8
        stp     reg_CFP, reg_NFP, [reg_CSP, #-4*8]
        str     reg_CODE, [reg_CSP, #-2*8]

	ENTER_PA

        // Save the lisp stack and frame pointers.

#ifdef LISP_FEATURE_SB_THREAD
        sub     reg_TMP, reg_CSP, #4*8
        stp     reg_TMP,reg_CSP, [reg_THREAD, THREAD_CONTROL_FRAME_POINTER_OFFSET]
        str     reg_CSP, [reg_THREAD, THREAD_FOREIGN_FUNCTION_CALL_ACTIVE_OFFSET]
#else
	ldr	reg_NFP, =current_control_stack_pointer
	str	reg_CSP, [reg_NFP]
	ldr	reg_NFP, =current_control_frame_pointer
        sub     reg_TMP, reg_CSP, #4*8
	str	reg_TMP, [reg_NFP]

        // Set FFCA, so the runtime knows that we're not "in lisp".
	ldr     reg_OCFP, =foreign_function_call_active
	str     reg_OCFP, [reg_OCFP]
#endif

#ifndef LISP_FEATURE_GENCGC
        // Copy the current allocation pointer out from the symbol.
        ldr     reg_NL9, =dynamic_space_free_pointer
        LOAD_STATIC_SYMBOL_VALUE(reg_NFP, ALLOCATION_POINTER)
        str     reg_NFP, [reg_NL9]
#endif

	LEAVE_PA
#ifdef LISP_FEATURE_SB_SAFEPOINT
	/* OK to run GC without stopping this thread from this point on. */
#  ifdef LISP_FEATURE_SB_THREAD
	str     reg_CSP, [reg_THREAD, THREAD_SAVED_CSP_OFFSET]
#  else
	ldr     reg_NL9, =all_threads
	str     reg_CSP, [reg_NL9, THREAD_SAVED_CSP_OFFSET]
#  endif
#endif

        // And call the C function.
        //
        // R8 is important for undefined_alien_function.
        blr      reg_R8

        // We're back.  Our main tasks are to move the C return value
        // to where Lisp expects it, and to re-establish the Lisp
        // environment.

        // Blank the boxed registers.
        mov     reg_R0, #0
        mov     reg_R1, #0
        mov     reg_R2, #0
        mov     reg_R3, #0
        mov     reg_R4, #0
        mov     reg_R5, #0
        mov     reg_R6, #0
        mov     reg_R7, #0
        mov     reg_R8, #0
        mov     reg_R9, #0
#ifndef LISP_FEATURE_SB_THREAD
        mov     reg_R10, #0
#endif
        mov     reg_LEXENV, #0
        mov     reg_CODE, #0

# ifdef LISP_FEATURE_SB_SAFEPOINT
	/* No longer OK to run GC except at safepoints. */
#  ifdef LISP_FEATURE_SB_THREAD
	str     xzr, [reg_THREAD, THREAD_SAVED_CSP_OFFSET]
#  else
	ldr     reg_NL9, =all_threads
	str     xzr, [reg_NL9, THREAD_SAVED_CSP_OFFSET]
#  endif
# endif

	ENTER_PA

        // Restore the Lisp stack and frame pointers, but store the
        // control frame pointer in reg_NFP (saving a register move
        // later).
#ifdef LISP_FEATURE_SB_THREAD
        str     xzr, [reg_THREAD, THREAD_FOREIGN_FUNCTION_CALL_ACTIVE_OFFSET]

	ldp     reg_NFP,reg_CSP, [reg_THREAD, THREAD_CONTROL_FRAME_POINTER_OFFSET]
#else
	// Clear FFCA, so the runtime knows that we're "in lisp".
	str     xzr, [reg_OCFP]

#ifndef LISP_FEATURE_GENCGC
        // Copy the current allocation pointer into the symbol.
        ldr     reg_NL9, =dynamic_space_free_pointer
        ldr     reg_NL9, [reg_NL9]
        STORE_STATIC_SYMBOL_VALUE(reg_OCFP, ALLOCATION_POINTER)
#endif

        ldr	reg_NFP, =current_control_stack_pointer
	ldr	reg_CSP, [reg_NFP]
	ldr	reg_NFP, =current_control_frame_pointer
	ldr	reg_NFP, [reg_NFP]
#endif
	LEAVE_PA

        // Restore our caller state from our stack frame.
        ldr     reg_CODE, [reg_NFP, #16]
        ldr     reg_CFP, [reg_NFP]
        mov     reg_CSP, reg_NFP

        // Return
        add     reg_LR, reg_NARGS, reg_CODE // reg_NARGS has the offset from reg_CODE
        ret

	.size	call_into_c, .-call_into_c

        // FIXME-ARM: The following is random garbage, to make
        // code/debug-int compile. To get the debugger working, this
        // needs to be implemented.
        .align
        .global fun_end_breakpoint_guts
        .type   fun_end_breakpoint_guts, %object
fun_end_breakpoint_guts:
	.global	fun_end_breakpoint_trap
	.type	fun_end_breakpoint_trap, %function
fun_end_breakpoint_trap:
        b      fun_end_breakpoint_trap
        .global fun_end_breakpoint_end
fun_end_breakpoint_end:
#ifdef LISP_FEATURE_GENCGC
        .align
	.global	do_pending_interrupt
	.type	do_pending_interrupt, %function
do_pending_interrupt:
        brk trap_PendingInterrupt
	ret
#endif
#ifdef __ELF__
// Mark the object as not requiring an executable stack.
.section .note.GNU-stack,"",%progbits
#endif
