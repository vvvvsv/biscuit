// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include "go_asm.h"
#include "go_tls.h"
#include "funcdata.h"
#include "textflag.h"

// _rt0_amd64 is common startup code for most amd64 systems when using
// internal linking. This is the entry point for the program from the
// kernel for an ordinary -buildmode=exe program. The stack holds the
// number of arguments and the C-style argv.
TEXT _rt0_amd64(SB),NOSPLIT,$-8
	MOVQ	0(SP), DI	// argc
	LEAQ	8(SP), SI	// argv
	JMP	runtime·rt0_go(SB)

// main is common startup code for most amd64 systems when using
// external linking. The C startup code will call the symbol "main"
// passing argc and argv in the usual C ABI registers DI and SI.
TEXT main(SB),NOSPLIT,$-8
	JMP	runtime·rt0_go(SB)

// _rt0_amd64_lib is common startup code for most amd64 systems when
// using -buildmode=c-archive or -buildmode=c-shared. The linker will
// arrange to invoke this function as a global constructor (for
// c-archive) or when the shared library is loaded (for c-shared).
// We expect argc and argv to be passed in the usual C ABI registers
// DI and SI.
TEXT _rt0_amd64_lib(SB),NOSPLIT,$0x50
	// Align stack per ELF ABI requirements.
	MOVQ	SP, AX
	ANDQ	$~15, SP
	// Save C ABI callee-saved registers, as caller may need them.
	MOVQ	BX, 0x10(SP)
	MOVQ	BP, 0x18(SP)
	MOVQ	R12, 0x20(SP)
	MOVQ	R13, 0x28(SP)
	MOVQ	R14, 0x30(SP)
	MOVQ	R15, 0x38(SP)
	MOVQ	AX, 0x40(SP)

	MOVQ	DI, _rt0_amd64_lib_argc<>(SB)
	MOVQ	SI, _rt0_amd64_lib_argv<>(SB)

	// Synchronous initialization.
	CALL	runtime·libpreinit(SB)

	// Create a new thread to finish Go runtime initialization.
	MOVQ	_cgo_sys_thread_create(SB), AX
	TESTQ	AX, AX
	JZ	nocgo
	MOVQ	$_rt0_amd64_lib_go(SB), DI
	MOVQ	$0, SI
	CALL	AX
	JMP	restore

nocgo:
	MOVQ	$0x800000, 0(SP)		// stacksize
	MOVQ	$_rt0_amd64_lib_go(SB), AX
	MOVQ	AX, 8(SP)			// fn
	CALL	runtime·newosproc0(SB)

restore:
	MOVQ	0x10(SP), BX
	MOVQ	0x18(SP), BP
	MOVQ	0x20(SP), R12
	MOVQ	0x28(SP), R13
	MOVQ	0x30(SP), R14
	MOVQ	0x38(SP), R15
	MOVQ	0x40(SP), SP
	RET

// _rt0_amd64_lib_go initializes the Go runtime.
// This is started in a separate thread by _rt0_amd64_lib.
TEXT _rt0_amd64_lib_go(SB),NOSPLIT,$0
	MOVQ	_rt0_amd64_lib_argc<>(SB), DI
	MOVQ	_rt0_amd64_lib_argv<>(SB), SI
	JMP	runtime·rt0_go(SB)

DATA _rt0_amd64_lib_argc<>(SB)/8, $0
GLOBL _rt0_amd64_lib_argc<>(SB),NOPTR, $8
DATA _rt0_amd64_lib_argv<>(SB)/8, $0
GLOBL _rt0_amd64_lib_argv<>(SB),NOPTR, $8

TEXT runtime·rt0_go(SB),NOSPLIT,$0
	// copy arguments forward on an even stack
	MOVQ	DI, AX		// argc
	MOVQ	SI, BX		// argv
	SUBQ	$(4*8+7), SP		// 2args 2auto
	ANDQ	$~15, SP
	MOVQ	AX, 16(SP)
	MOVQ	BX, 24(SP)
	
	// create istack out of the given (operating system) stack.
	// _cgo_init may update stackguard.
	MOVQ	$runtime·g0(SB), DI
	LEAQ	(-64*1024+104)(SP), BX
	MOVQ	BX, g_stackguard0(DI)
	MOVQ	BX, g_stackguard1(DI)
	MOVQ	BX, (g_stack+stack_lo)(DI)
	MOVQ	SP, (g_stack+stack_hi)(DI)

	// find out information about the processor we're on
	MOVL	$0, AX
	CPUID
	MOVL	AX, SI
	CMPL	AX, $0
	JE	nocpuinfo

	// Figure out how to serialize RDTSC.
	// On Intel processors LFENCE is enough. AMD requires MFENCE.
	// Don't know about the rest, so let's do MFENCE.
	CMPL	BX, $0x756E6547  // "Genu"
	JNE	notintel
	CMPL	DX, $0x49656E69  // "ineI"
	JNE	notintel
	CMPL	CX, $0x6C65746E  // "ntel"
	JNE	notintel
	MOVB	$1, runtime·isIntel(SB)
	MOVB	$1, runtime·lfenceBeforeRdtsc(SB)
notintel:

	// Load EAX=1 cpuid flags
	MOVL	$1, AX
	CPUID
	MOVL	AX, runtime·processorVersionInfo(SB)

	TESTL	$(1<<26), DX // SSE2
	SETNE	runtime·support_sse2(SB)

	TESTL	$(1<<9), CX // SSSE3
	SETNE	runtime·support_ssse3(SB)

	TESTL	$(1<<19), CX // SSE4.1
	SETNE	runtime·support_sse41(SB)

	TESTL	$(1<<20), CX // SSE4.2
	SETNE	runtime·support_sse42(SB)

	TESTL	$(1<<23), CX // POPCNT
	SETNE	runtime·support_popcnt(SB)

	TESTL	$(1<<25), CX // AES
	SETNE	runtime·support_aes(SB)

	TESTL	$(1<<27), CX // OSXSAVE
	SETNE	runtime·support_osxsave(SB)

	// If OS support for XMM and YMM is not present
	// support_avx will be set back to false later.
	TESTL	$(1<<28), CX // AVX
	SETNE	runtime·support_avx(SB)

eax7:
	// Load EAX=7/ECX=0 cpuid flags
	CMPL	SI, $7
	JLT	osavx
	MOVL	$7, AX
	MOVL	$0, CX
	CPUID

	TESTL	$(1<<3), BX // BMI1
	SETNE	runtime·support_bmi1(SB)

	// If OS support for XMM and YMM is not present
	// support_avx2 will be set back to false later.
	TESTL	$(1<<5), BX
	SETNE	runtime·support_avx2(SB)

	TESTL	$(1<<8), BX // BMI2
	SETNE	runtime·support_bmi2(SB)

	TESTL	$(1<<9), BX // ERMS
	SETNE	runtime·support_erms(SB)

osavx:
	CMPB	runtime·support_osxsave(SB), $1
	JNE	noavx
	MOVL	$0, CX
	// For XGETBV, OSXSAVE bit is required and sufficient
	XGETBV
	ANDL	$6, AX
	CMPL	AX, $6 // Check for OS support of XMM and YMM registers.
	JE nocpuinfo
noavx:
	MOVB $0, runtime·support_avx(SB)
	MOVB $0, runtime·support_avx2(SB)

nocpuinfo:
	// if there is an _cgo_init, call it.
	MOVQ	_cgo_init(SB), AX
	TESTQ	AX, AX
	JZ	needtls
	// g0 already in DI
	MOVQ	DI, CX	// Win64 uses CX for first parameter
	MOVQ	$setg_gcc<>(SB), SI
	CALL	AX

	// update stackguard after _cgo_init
	MOVQ	$runtime·g0(SB), CX
	MOVQ	(g_stack+stack_lo)(CX), AX
	ADDQ	$const__StackGuard, AX
	MOVQ	AX, g_stackguard0(CX)
	MOVQ	AX, g_stackguard1(CX)

#ifndef GOOS_windows
	JMP ok
#endif
needtls:
#ifdef GOOS_plan9
	// skip TLS setup on Plan 9
	JMP ok
#endif
#ifdef GOOS_solaris
	// skip TLS setup on Solaris
	JMP ok
#endif

	LEAQ	runtime·m0+m_tls(SB), DI
	CALL	runtime·settls(SB)

	// store through it, to make sure it works
	get_tls(BX)
	MOVQ	$0x123, g(BX)
	MOVQ	runtime·m0+m_tls(SB), AX
	CMPQ	AX, $0x123
	JEQ 2(PC)
	CALL	runtime·abort(SB)
ok:
	// set the per-goroutine and per-mach "registers"
	get_tls(BX)
	LEAQ	runtime·g0(SB), CX
	MOVQ	CX, g(BX)
	LEAQ	runtime·m0(SB), AX

	// save m->g0 = g0
	MOVQ	CX, m_g0(AX)
	// save m0 to g0->m
	MOVQ	AX, g_m(CX)

	CLD				// convention is D is always left cleared
	CALL	runtime·check(SB)

	MOVL	16(SP), AX		// copy argc
	MOVL	AX, 0(SP)
	MOVQ	24(SP), AX		// copy argv
	MOVQ	AX, 8(SP)
	CALL	runtime·args(SB)
	CALL	runtime·osinit(SB)
	CALL	runtime·schedinit(SB)

	// create a new goroutine to start program
	MOVQ	$runtime·mainPC(SB), AX		// entry
	PUSHQ	AX
	PUSHQ	$0			// arg size
	CALL	runtime·newproc(SB)
	POPQ	AX
	POPQ	AX

	// start this M
	CALL	runtime·mstart(SB)

	CALL	runtime·abort(SB)	// mstart should never return
	RET

DATA	runtime·mainPC+0(SB)/8,$runtime·main(SB)
GLOBL	runtime·mainPC(SB),RODATA,$8

TEXT runtime·breakpoint(SB),NOSPLIT,$0-0
	BYTE	$0xcc
	RET

TEXT runtime·asminit(SB),NOSPLIT,$0-0
	// No per-thread init.
	RET

#define		CODESEG		1
#define		UCSEG		5
#define		UDSEG		6

TEXT fixcs(SB),NOSPLIT,$0
	POPQ	AX
	PUSHQ	$(CODESEG << 3)
	PUSHQ	AX
	// lretq
	BYTE	$0x48
	BYTE	$0xcb
	MOVQ	$1, 0

TEXT runtime·deray(SB),NOSPLIT,$8
	MOVQ	times+0(FP), CX
	SHRQ	$10, CX
	CMPQ	CX, $0
	JEQ	done
back:
	// inb	$0x80, %al
	BYTE	$0xe4
	BYTE	$0x80
	LOOP	back
done:
	RET

// i do it this strange way because if i declare fakeargv in C i get 'missing
// golang type information'. need two 0 entries because go checks for
// environment variables too.
//DATA	fakeargv+0(SB)/8,$·gostr(SB)
//DATA	fakeargv+8(SB)/8,$0
//DATA	fakeargv+16(SB)/8,$0
//GLOBL	fakeargv(SB),RODATA,$24

TEXT runtime·rt0_go_hack(SB),NOSPLIT,$0
	MOVL	DI, ·P_kpmap(SB)
	MOVL	SI, ·pgfirst(SB)
	MOVQ	$1, runtime·hackmode(SB)

	SUBQ	$(4*8+7), SP		// 2args 2auto
	ANDQ	$~15, SP

	CALL	runtime·sc_setup(SB)

	// create istack out of the given (operating system) stack.
	// _cgo_init may update stackguard.
	MOVQ	$runtime·g0(SB), DI
	LEAQ	(-64*1024+104)(SP), BX
	MOVQ	BX, g_stackguard0(DI)
	MOVQ	BX, g_stackguard1(DI)
	MOVQ	BX, (g_stack+stack_lo)(DI)
	MOVQ	SP, (g_stack+stack_hi)(DI)

	// find out information about the processor we're on
	MOVL	$0, AX
	CPUID
	MOVL	AX, SI
	CMPL	AX, $0
	JE	nocpuinfo

	// Figure out how to serialize RDTSC.
	// On Intel processors LFENCE is enough. AMD requires MFENCE.
	// Don't know about the rest, so let's do MFENCE.
	CMPL	BX, $0x756E6547  // "Genu"
	JNE	notintel
	CMPL	DX, $0x49656E69  // "ineI"
	JNE	notintel
	CMPL	CX, $0x6C65746E  // "ntel"
	JNE	notintel
	MOVB	$1, runtime·isIntel(SB)
	MOVB	$1, runtime·lfenceBeforeRdtsc(SB)
notintel:

	// Load EAX=1 cpuid flags
	MOVL	$1, AX
	CPUID
	MOVL	AX, runtime·processorVersionInfo(SB)

	TESTL	$(1<<26), DX // SSE2
	SETNE	runtime·support_sse2(SB)

	TESTL	$(1<<9), CX // SSSE3
	SETNE	runtime·support_ssse3(SB)

	TESTL	$(1<<19), CX // SSE4.1
	SETNE	runtime·support_sse41(SB)

	TESTL	$(1<<20), CX // SSE4.2
	SETNE	runtime·support_sse42(SB)

	TESTL	$(1<<23), CX // POPCNT
	SETNE	runtime·support_popcnt(SB)

	TESTL	$(1<<25), CX // AES
	SETNE	runtime·support_aes(SB)

	TESTL	$(1<<27), CX // OSXSAVE
	SETNE	runtime·support_osxsave(SB)

	// If OS support for XMM and YMM is not present
	// support_avx will be set back to false later.
	TESTL	$(1<<28), CX // AVX
	SETNE	runtime·support_avx(SB)

eax7:
	// Load EAX=7/ECX=0 cpuid flags
	CMPL	SI, $7
	JLT	osavx
	MOVL	$7, AX
	MOVL	$0, CX
	CPUID

	TESTL	$(1<<3), BX // BMI1
	SETNE	runtime·support_bmi1(SB)

	// If OS support for XMM and YMM is not present
	// support_avx2 will be set back to false later.
	TESTL	$(1<<5), BX
	SETNE	runtime·support_avx2(SB)

	TESTL	$(1<<8), BX // BMI2
	SETNE	runtime·support_bmi2(SB)

	TESTL	$(1<<9), BX // ERMS
	SETNE	runtime·support_erms(SB)

osavx:
	CMPB	runtime·support_osxsave(SB), $1
	JNE	noavx
	MOVL	$0, CX
	// For XGETBV, OSXSAVE bit is required and sufficient
	XGETBV
	ANDL	$6, AX
	CMPL	AX, $6 // Check for OS support of XMM and YMM registers.
	JE nocpuinfo
noavx:
	MOVB $0, runtime·support_avx(SB)
	MOVB $0, runtime·support_avx2(SB)

nocpuinfo:
	// if there is an _cgo_init, call it.
	MOVQ	_cgo_init(SB), AX
	TESTQ	AX, AX
	JZ	needtls
	// g0 already in DI
	MOVQ	DI, CX	// Win64 uses CX for first parameter
	MOVQ	$setg_gcc<>(SB), SI
	CALL	AX

	// update stackguard after _cgo_init
	MOVQ	$runtime·g0(SB), CX
	MOVQ	(g_stack+stack_lo)(CX), AX
	ADDQ	$const__StackGuard, AX
	MOVQ	AX, g_stackguard0(CX)
	MOVQ	AX, g_stackguard1(CX)

#ifndef GOOS_windows
	JMP ok
#endif
needtls:
#ifdef GOOS_plan9
	// skip TLS setup on Plan 9
	JMP ok
#endif
#ifdef GOOS_solaris
	// skip TLS setup on Solaris
	JMP ok
#endif
	//LEAQ	runtime·m0+m_tls(SB), DI
	//CALL	runtime·settls(SB)

	// from this point on, SSE regs may be used. allow SSE instructions
	// immediately.
	CALL	·fpuinit0(SB)
	CALL	·seg_setup(SB)
	// i cannot fix CS via far call to a label because i don't know how to
	// call a label with plan9 compiler.
	CALL	fixcs(SB)

	// store through it, to make sure it works
	get_tls(BX)
	MOVQ	$0x123, g(BX)
	MOVQ	runtime·m0+m_tls(SB), AX
	CMPQ	AX, $0x123
	JEQ	ok
	MOVQ	$0x42, (SP)
	CALL	runtime·putch(SB)
	MOVQ	$0x46, (SP)
	CALL	runtime·putch(SB)
	BYTE	$0xeb;
	BYTE	$0xfe;
	CALL	runtime·abort(SB)
ok:
	// set the per-goroutine and per-mach "registers"
	get_tls(BX)
	LEAQ	runtime·g0(SB), CX
	MOVQ	CX, g(BX)
	LEAQ	runtime·m0(SB), AX

	// save m->g0 = g0
	MOVQ	CX, m_g0(AX)
	// save m0 to g0->m
	MOVQ	AX, g_m(CX)

	CALL	·int_setup(SB)
	CALL	·proc_setup(SB)
	STI

	CLD				// convention is D is always left cleared
	CALL	runtime·check(SB)

	//MOVL	16(SP), AX		// copy argc
	//MOVL	AX, 0(SP)
	//MOVQ	24(SP), AX		// copy argv
	//MOVQ	AX, 8(SP)
	//CALL	runtime·args(SB)
	CALL	runtime·osinit(SB)
	CALL	runtime·schedinit(SB)

	// create a new goroutine to start program
	MOVQ	$runtime·mainPC(SB), AX		// entry
	PUSHQ	AX
	PUSHQ	$0			// arg size
	CALL	runtime·newproc(SB)
	POPQ	AX
	POPQ	AX

	// start this M
	CALL	runtime·mstart(SB)

	CALL	runtime·abort(SB)	// mstart should never return
	RET

TEXT runtime·Cpuid(SB), NOSPLIT, $0-24
	XORQ	AX, AX
	XORQ	CX, CX
	MOVL	eax+0(FP), AX
	MOVL	ecx+4(FP), CX
	CPUID
	MOVL	AX, ret+8(FP)
	MOVL	BX, ret+12(FP)
	MOVL	CX, ret+16(FP)
	MOVL	DX, ret+20(FP)
	RET

TEXT ·finit(SB), NOSPLIT, $0-0
	FINIT
	RET

TEXT ·Rcr0(SB), NOSPLIT, $0-8
	MOVQ	CR0, AX
	MOVQ	AX, ret+0(FP)
	RET

TEXT ·Rcr2(SB), NOSPLIT, $0-8
	MOVQ	CR2, AX
	MOVQ	AX, ret+0(FP)
	RET

TEXT ·Rcr4(SB), NOSPLIT, $0-8
	MOVQ	CR4, AX
	MOVQ	AX, ret+0(FP)
	RET

TEXT tlbflush(SB), NOSPLIT, $0-0
	MOVQ	CR3, AX
	MOVQ	AX, CR3
	RET

TEXT ·Lcr3(SB), NOSPLIT, $0-8
	MOVQ	pgtbl+0(FP), AX
	MOVQ	AX, CR3
	RET

TEXT ·Rcr3(SB), NOSPLIT, $0-8
	MOVQ	CR3, AX
	MOVQ	AX, ret+0(FP)
	RET

TEXT runtime·Invlpg(SB), $0-8
	MOVQ	va+0(FP), AX
	INVLPG	(AX)
	RET

TEXT ·invlpg(SB), NOSPLIT, $0-8
	MOVQ	va+0(FP), AX
	INVLPG	(AX)
	RET

// Used to guarantee 32bit writes without the lock prefix
TEXT ·Store32(SB), NOSPLIT, $0-16
	MOVQ	addr+0(FP), AX
	MOVL	v+8(FP), DX
	MOVL	DX, (AX)
	RET

// void lidt(pdesc_t);
TEXT ·lidt(SB), NOSPLIT, $0-16
	// lidtq 8(%rsp)
	BYTE	$0x48
	BYTE	$0x0f
	BYTE	$0x01
	BYTE	$0x5c
	BYTE	$0x24
	BYTE	$0x08
	RET

// void lgdt(pdesc_t);
TEXT ·lgdt(SB), NOSPLIT, $0-16
	// lgdt 8(%rsp)
	BYTE	$0x0f
	BYTE	$0x01
	BYTE	$0x54
	BYTE	$0x24
	BYTE	$0x08
	RET

TEXT ·ltr(SB), NOSPLIT, $0-8
	MOVQ	seg+0(FP), AX
	// ltr	%ax
	BYTE $0x0f
	BYTE $0x00
	BYTE $0xd8
	RET

TEXT ·Lcr0(SB), NOSPLIT, $0-8
	MOVQ	val+0(FP), AX
	MOVQ	AX, CR0
	RET

TEXT ·Lcr4(SB), NOSPLIT, $0-8
	MOVQ	val+0(FP), AX
	MOVQ	AX, CR4
	RET

TEXT ·Rdmsr(SB), NOSPLIT, $0-16
	MOVQ	reg+0(FP), CX
	RDMSR
	MOVL	DX, ret2+12(FP)
	MOVL	AX, ret1+8(FP)
	RET

// void ·Wrmsr(uint64 reg, uint64 val)
TEXT ·Wrmsr(SB), NOSPLIT, $0-16
	MOVQ	reg+0(FP), CX
	MOVL	vlo+8(FP), AX
	MOVL	vhi+12(FP), DX
	WRMSR
	RET

// uint64 Inb(reg uint16)
TEXT ·Inb(SB), NOSPLIT, $0-16
	MOVW	reg+0(FP), DX
	// inb (%dx), %al
	BYTE	$0xec
	// movzbq %al, %rax
	BYTE $0x48
	BYTE $0x0f
	BYTE $0xb6
	BYTE $0xc0
	MOVQ	AX, ret+8(FP)
	RET

// void Outb(reg uint16, val uint8)
TEXT runtime·Outb(SB), NOSPLIT, $0-16
	MOVW	reg+0(FP), DX
	MOVB	val+2(FP), AX
	// outb	%al, (%dx)
	BYTE	$0xee
	RET

TEXT runtime·Outw(SB), NOSPLIT, $0-16
	MOVQ	reg+0(FP), DX
	MOVQ	val+8(FP), AX
	// outw	%ax, (%dx)
	BYTE	$0x66
	BYTE	$0xef
	RET

TEXT runtime·Outl(SB), NOSPLIT, $0-16
	MOVQ	reg+0(FP), DX
	MOVQ	val+8(FP), AX
	// outl	%eax, (%dx)
	BYTE	$0xef
	RET

TEXT runtime·Outsl(SB), NOSPLIT, $0-24
	MOVQ	reg+0(FP), DX
	MOVQ	ptr+8(FP), SI
	MOVQ	len+16(FP), CX
	// repnz outsl (%rsi), (%dx)
	BYTE	$0xf2
	BYTE	$0x6f
	RET

TEXT runtime·Inl(SB), NOSPLIT, $0-16
	MOVQ	reg+0(FP), DX
	// inl	(%dx), %eax
	BYTE	$0xed
	MOVQ	AX, ret+8(FP)
	RET

TEXT runtime·Insl(SB), NOSPLIT, $0-24
	MOVQ	reg+0(FP), DX
	MOVQ	ptr+8(FP), DI
	MOVQ	len+16(FP), CX
	// repnz insl (%dx), (%rdi)
	BYTE	$0xf2
	BYTE	$0x6d
	RET

TEXT ·rflags(SB), NOSPLIT, $0-8
	PUSHFQ
	POPQ	AX
	MOVQ	AX, ret+0(FP)
	RET

TEXT ·Rdtsc(SB), NOSPLIT, $0-8
	// rdtsc
	BYTE	$0x0f
	BYTE	$0x31
	MOVL	AX, ret+0(FP)
	MOVL	DX, ret+4(FP)
	RET

TEXT ·Cli(SB), NOSPLIT, $0-0
	CLI
	RET

TEXT ·Sti(SB), NOSPLIT, $0-0
	STI
	RET

TEXT ·Pushcli(SB), NOSPLIT, $0-8
	PUSHFQ
	POPQ	AX
	MOVQ	AX, ret+0(FP)
	CLI
	RET

TEXT ·Popcli(SB), NOSPLIT, $0-8
	MOVQ	fl+0(FP), AX
	PUSHQ	AX
	POPFQ
	RET

TEXT ·Sgdt(SB), NOSPLIT, $0-8
	MOVQ	ptr+0(FP), AX
	// sgdtl (%rax)
	BYTE	$0x0f
	BYTE	$0x01
	BYTE	$0x00
	RET

TEXT ·Sidt(SB), NOSPLIT, $0-8
	MOVQ	ptr+0(FP), AX
	// sidtl (%rax)
	BYTE	$0x0f
	BYTE	$0x01
	BYTE	$0x08
	RET

TEXT gtr(SB), NOSPLIT, $0-8
	// str	%rax
	BYTE $0x48
	BYTE $0x0f
	BYTE $0x00
	BYTE $0xc8
	MOVQ	AX, ret+0(FP)
	RET

TEXT getret(SB), NOSPLIT, $0-16
	MOVQ	ptr+0(FP), AX
	ADDQ	$-8, AX
	MOVQ	(AX), AX
	MOVQ	AX, ret+8(FP)
	RET

TEXT ·htpause(SB), NOSPLIT, $0-0
	PAUSE
	RET

TEXT ·fxsave(SB), NOSPLIT, $0-8
	MOVQ	dst+0(FP), AX
	// fxsave	(%rax)
	BYTE	$0x0f
	BYTE	$0xae
	BYTE	$0x00
	RET

TEXT ·fxrstor(SB), NOSPLIT, $0-8
	MOVQ	dst+0(FP), AX
	// fxrstor	(%rax)
	BYTE	$0x0f
	BYTE	$0xae
	BYTE	$0x08
	RET

TEXT ·cpu_halt(SB), NOSPLIT, $0-8
	MOVQ	sp+0(FP), SP
	STI
hltagain:
	HLT
	JMP	hltagain

// void ·clone_call(uintptr rip)
TEXT ·clone_call(SB), NOSPLIT, $0-8
	MOVQ	fn+0(FP), AX
	CALL	AX
	RET

#define TRAP_YIELD      $49
#define TRAP_SYSCALL    $64
TEXT hack_yield(SB), NOSPLIT, $0-0
	INT	TRAP_YIELD
	RET

TEXT fut_hack_yield(SB), NOSPLIT, $0-0
	INT	TRAP_YIELD
	RET

TEXT find_hack_yield(SB), NOSPLIT, $0-0
	INT	TRAP_YIELD
	RET

#define IH_NOEC(num, fn)		\
TEXT fn(SB), NOSPLIT, $0-0;		\
	PUSHQ	$0;			\
	PUSHQ	$num;			\
	JMP	alltraps(SB);		\
	BYTE	$0xeb;			\
	BYTE	$0xfe;			\
	POPQ	AX;			\
	POPQ	AX;			\
	RET
// pops are to silence plan9 assembler warnings

#define IH_EC(num, fn)			\
TEXT fn(SB), NOSPLIT, $0-0;		\
	PUSHQ	$num;			\
	JMP	alltraps(SB);		\
	BYTE	$0xeb;			\
	BYTE	$0xfe;			\
	POPQ	AX;			\
	RET

IH_NOEC( 0,·Xdz )
IH_NOEC( 1,·Xrz )
IH_NOEC( 2,·Xnmi )
IH_NOEC( 3,·Xbp )
IH_NOEC( 4,·Xov )
IH_NOEC( 5,·Xbnd )
IH_NOEC( 6,·Xuo )
IH_NOEC( 7,·Xnm )
IH_EC  ( 8,·Xdf )
IH_NOEC( 9,·Xrz2 )
IH_EC  (10,·Xtss )
IH_EC  (11,·Xsnp )
IH_EC  (12,·Xssf )
IH_EC  (13,·Xgp )
IH_EC  (14,·Xpf )
IH_NOEC(15,·Xrz3 )
IH_NOEC(16,·Xmf )
IH_EC  (17,·Xac )
IH_NOEC(18,·Xmc )
IH_NOEC(19,·Xfp )
IH_NOEC(20,·Xve )

// irqs vectors 32-55
IH_NOEC(32,·Xtimer )
IH_NOEC(33,·Xirq1 )
IH_NOEC(34,·Xirq2 )
IH_NOEC(35,·Xirq3 )
IH_NOEC(36,·Xirq4 )
IH_NOEC(37,·Xirq5 )
IH_NOEC(38,·Xirq6 )
IH_NOEC(39,·Xirq7 )
IH_NOEC(40,·Xirq8 )
IH_NOEC(41,·Xirq9 )
IH_NOEC(42,·Xirq10 )
IH_NOEC(43,·Xirq11 )
IH_NOEC(44,·Xirq12 )
IH_NOEC(45,·Xirq13 )
IH_NOEC(46,·Xirq14 )
IH_NOEC(47,·Xirq15 )
IH_NOEC(48,·Xirq16 )
IH_NOEC(49,·Xirq17 )
IH_NOEC(50,·Xirq18 )
IH_NOEC(51,·Xirq19 )
IH_NOEC(52,·Xirq20 )
IH_NOEC(53,·Xirq21 )
IH_NOEC(54,·Xirq22 )
IH_NOEC(55,·Xirq23 )

// MSI interrupts 56-63
IH_NOEC(56,·Xmsi0 )
IH_NOEC(57,·Xmsi1 )
IH_NOEC(58,·Xmsi2 )
IH_NOEC(59,·Xmsi3 )
IH_NOEC(60,·Xmsi4 )
IH_NOEC(61,·Xmsi5 )
IH_NOEC(62,·Xmsi6 )
IH_NOEC(63,·Xmsi7 )

IH_NOEC(64,·Xspur )
IH_NOEC(70,·Xtlbshoot )
IH_NOEC(72,·Xperfmask )

#define IA32_FS_BASE		$0xc0000100
#define IA32_GS_BASE		$0xc0000101
#define IA32_SYSENTER_EIP	$0x176

TEXT wrfsb(SB), NOSPLIT, $0-8
	get_tls(BX)
	MOVQ	val+0(FP), AX
	MOVQ	AX, g(BX)
	RET

TEXT rdfsb(SB), NOSPLIT, $0-8
	get_tls(BX)
	MOVQ	g(BX), AX
	MOVQ	AX, ret+0(FP)
	RET

TEXT alltraps(SB), NOSPLIT, $0-0
	// tf[15] = trapno
	// 15 + 1 pushes
	// pusha is not valid in 64bit mode!
	PUSHQ	AX

	PUSHQ	BX
	PUSHQ	CX
	PUSHQ	DX
	PUSHQ	DI
	PUSHQ	SI
	PUSHQ	BP
	PUSHQ	R8
	PUSHQ	R9
	PUSHQ	R10
	PUSHQ	R11
	PUSHQ	R12
	PUSHQ	R13
	PUSHQ	R14
	PUSHQ	R15

	// save fsbase
	MOVQ	IA32_FS_BASE, CX
	RDMSR
	SHLQ	$32, DX
	ORQ	DX, AX
	PUSHQ	AX

	// save gsbase
	MOVQ	IA32_GS_BASE, CX
	RDMSR
	SHLQ	$32, DX
	ORQ	DX, AX
	PUSHQ	AX

	MOVQ	SP, AX
	PUSHQ	AX

	CALL	·trap(SB)
	// jmp self
	BYTE	$0xeb
	BYTE	$0xfe

// void ·trapret(tf *uintptr, p_pmap uintptr)
TEXT ·trapret(SB), NOSPLIT, $0-16
	MOVQ	pmap+8(FP), BX
	MOVQ	BX, CR3

	JMP	·_trapret(SB)
	INT	$3

TEXT ·_trapret(SB), NOSPLIT, $0-8
	MOVQ	tf+0(FP), AX	// tf is not on the callers stack frame, but in
				// threads[]
	MOVQ	AX, SP

	// restore gsbase
	MOVQ	IA32_GS_BASE, CX
	POPQ	AX
	MOVQ	AX, DX
	SHRQ	$32, DX
	WRMSR

	// skip fsbase
	POPQ	CX

	POPQ	R15
	POPQ	R14
	POPQ	R13
	POPQ	R12
	POPQ	R11
	POPQ	R10
	POPQ	R9
	POPQ	R8
	POPQ	BP
	POPQ	SI
	POPQ	DI
	POPQ	DX
	POPQ	CX
	POPQ	BX
	POPQ	AX
	// skip trapno and error code
	ADDQ	$16, SP

	// iretq
	BYTE	$0x48
	BYTE	$0xcf

// identical to _trapret, but doesn't load gsbase from the trapframe
TEXT ·_userret(SB), NOSPLIT, $0-8
	MOVQ	tf+0(FP), AX	// tf is not on the callers stack frame, but in
				// threads[]
	MOVQ	AX, SP

	// skip gsbase
	POPQ	AX

	// skip fsbase
	POPQ	CX

	POPQ	R15
	POPQ	R14
	POPQ	R13
	POPQ	R12
	POPQ	R11
	POPQ	R10
	POPQ	R9
	POPQ	R8
	POPQ	BP
	POPQ	SI
	POPQ	DI
	POPQ	DX
	POPQ	CX
	POPQ	BX
	POPQ	AX
	// skip trapno and error code
	ADDQ	$16, SP

	// iretq
	BYTE	$0x48
	BYTE	$0xcf

// void ·mktrap(uint64 intn)
TEXT ·mktrap(SB), NOSPLIT, $0-8
	PUSHQ	AX
	PUSHQ	DX
	PUSHFQ
	POPQ	AX

	CLI

	// do hardware trap frame; get CPU's interrupt stack
	SWAPGS
	MOVQ	0(GS), DX
	SWAPGS
	MOVQ	16(DX), DX

	// save rflags first
	MOVQ	AX, -24(DX)

	XORQ	AX, AX
	// mov %ss, %ax
	BYTE	$0x66
	BYTE	$0x8c
	BYTE	$0xd0
	MOVQ	AX, -8(DX)

	MOVQ	SP, AX
	// get rid of our pushes and ret addr, return there directly
	ADDQ	$24, AX
	MOVQ	AX, -16(DX)

	XORQ	AX, AX
	// mov %cs, %ax
	BYTE	$0x66
	BYTE	$0x8c
	BYTE	$0xc8
	MOVQ	AX, -32(DX)

	// ret addr
	MOVQ	ret+-8(FP), AX
	MOVQ	AX, -40(DX)

	// dummy error code
	MOVQ	$0, -48(DX)

	// interrupt number
	MOVQ	intn+0(FP), AX
	MOVQ	AX, -56(DX)

	// and finally, restore rax and rdx
	POPQ	AX
	MOVQ	AX, -64(DX)

	POPQ	AX
	MOVQ	AX, -72(DX)

	LEAQ	-72(DX), SP

	POPQ	AX
	POPQ	DX

	JMP	alltraps(SB)

#define TFREGS		17
#define TF_R15		(8*2)
#define TF_R14		(8*3)
#define TF_R13		(8*4)
#define TF_R12		(8*5)
#define TF_R8		(8*9)
#define TF_RBP		(8*10)
#define TF_RSI		(8*11)
#define TF_RDI		(8*12)
#define TF_RDX		(8*13)
#define TF_RCX		(8*14)
#define TF_RBX		(8*15)
#define TF_RAX		(8*16)
#define TF_RIP		(8*(TFREGS + 2))
#define TF_RSP		(8*(TFREGS + 5))

#define ARG1(x)		0x8(x)
#define ARG2(x)		0x10(x)
#define ARG3(x)		0x18(x)
#define RET1(x)		0x20(x)
#define RET2(x)		0x28(x)

//func Userrun_slow(tf *[TFSIZE]uintptr, fxbuf *[FXREGS]uintptr,
//    p_pmap uintptr, fastret bool, pmap_ref *int32) (int, int, uintptr, bool)
TEXT ·Userrun(SB), $0-0
	CLI

	SWAPGS
	MOVQ	0(GS), R9
	SWAPGS
	//LEAQ	·cpus(SB), R9

	MOVQ	0x18(SP), AX
	CMPQ	0x28(R9), AX
	JNE	out

	MOVQ	0x8(SP), AX
	MOVQ	0x8(AX), AX
	CMPQ	0x30(R9), AX
	JNE	out

	MOVQ	0x8(SP), AX
	CMPQ	0x38(R9), AX
	JNE	out

	MOVB	0x20(SP), AX
	TESTB	AX, AX
	JZ	out

	MOVQ	ARG1(SP), BX
	SUBQ	$5*8, SP
	MOVQ	R9, 0x10(SP)
	MOVB	AX, 0x8(SP)
	MOVQ	BX, 0x0(SP)
	CALL	·_Userrun(SB)
	MOVQ	0x18(SP), AX
	MOVQ	0x20(SP), BX

	ADDQ	$5*8, SP
	MOVQ	AX, 0x30(SP)
	MOVQ	BX, 0x38(SP)
	MOVQ	$0, 0x40(SP)
	MOVQ	$0, 0x48(SP)
	STI
	RET
out:
	ADDQ	$8, SP
	JMP	runtime·Userrun_slow(SB)

// if you change the number of arguments, you must adjust the stack offsets in
// _sysentry and ·_userint.
// func _Userrun(tf *[24]int, fastret bool, cpu *cpu_t) (int, int)
TEXT ·_Userrun(SB), NOSPLIT, $0-0
dur:
	MOVQ	ARG1(SP), R9
	MOVQ	ARG3(SP), AX

	MOVQ	SP, 0x20(AX)

	// fastret or iret?
	// ax = fastret
	MOVB	ARG2(SP), AX
	CMPB	AX, $0
	JE	slowret
syscallreturn:
	MOVQ	TF_RAX(R9), AX
	MOVQ	TF_RSP(R9), CX
	MOVQ	TF_RIP(R9), DX
	MOVQ	TF_RBP(R9), BP
	MOVQ	TF_RBX(R9), BX

	//MOVQ	TF_R15(R9), R15
	//MOVQ	TF_R14(R9), R14
	//MOVQ	TF_R13(R9), R13
	//MOVQ	TF_R12(R9), R12

	// rcx contains rsp
	// rdx contains rip
	STI
	// rex64 sysexit
	BYTE	$0x48
	BYTE	$0x0f
	BYTE	$0x35
	INT	$3
slowret:
	// do full state restore
	PUSHQ	R9
	//CALL	·_userret(SB)
	PUSHQ	$0
	JMP	·_userret(SB)

	MOVL	$0x5cc, DX
	TESTL	AX, AX
	MOVL	DX, CX
	ORL	$0x20, DX
	DIVL	0x58(CX)
	ANDL	$0x1f, DX
	MOVQ	CR4, AX
	MOVL	$0x16, AX
	MOVL	0x104(CX), SI
	MOVL	DI, 8(SP)
	MOVB	$1, 3(DX)

// this should be a label since it is the bottom half of the Userrun_ function,
// but i can't figure out how to get the plan9 assembler to let me use lea on a
// label. thus the function epilogue and offset to get the tf arg from Userrun_
// are hand-coded.
//_sysentry:
TEXT ·_sysentry(SB), NOSPLIT, $0-0
	SWAPGS
	MOVQ	0(GS), SP
	SWAPGS
	//LEAQ	·cpus(SB), SP

	MOVQ	0x20(SP), SP

	// save user state in fake trapframe
	MOVQ	ARG1(SP), R9
	MOVQ	R10, TF_RSP(R9)
	MOVQ	R11, TF_RIP(R9)
	// syscall args
	MOVQ	AX,  TF_RAX(R9)
	MOVQ	DI,  TF_RDI(R9)
	MOVQ	SI,  TF_RSI(R9)
	MOVQ	DX,  TF_RDX(R9)
	MOVQ	CX,  TF_RCX(R9)
	MOVQ	R8,  TF_R8(R9)
	// kernel preserves rbp and rbx
	MOVQ	BP,  TF_RBP(R9)
	MOVQ	BX,  TF_RBX(R9)

	//MOVQ	R15, TF_R15(R9)
	//MOVQ	R14, TF_R14(R9)
	//MOVQ	R13, TF_R13(R9)
	//MOVQ	R12, TF_R12(R9)

	// return val 1
	MOVQ	TRAP_SYSCALL, RET1(SP)
	// return val 2
	MOVQ	$0, RET2(SP)

// return direct to userspace testing
//	MOVQ	TF_RAX(R9), CX
//	CMPQ	CX, $40
//	JNE	slowsys
//
//	STI
//	SUBQ	$3*8, SP
//	get_tls(AX)
//	MOVQ	g(AX), AX
//	MOVQ	g_current(AX), AX
//	MOVQ	(AX), AX
//	MOVQ	AX, (SP)
//	MOVQ	·DUR(SB), AX
//	CALL	AX
//	MOVQ	0x10(SP), BX
//	MOVQ	(3*8 + 0x8)(SP), AX
//	MOVQ	BX, TF_RAX(AX)
//	ADDQ	$3*8, SP
//	CLI
//
//	MOVQ	ARG1(SP), R9
//	MOVQ	TF_RAX(R9), AX
//	MOVQ	TF_RSP(R9), CX
//	MOVQ	TF_RIP(R9), DX
//	MOVQ	TF_RBP(R9), BP
//	MOVQ	TF_RBX(R9), BX
//
//	MOVQ	TF_R15(R9), R15
//	MOVQ	TF_R14(R9), R14
//	MOVQ	TF_R13(R9), R13
//	MOVQ	TF_R12(R9), R12
//	// rcx contains rsp
//	// rdx contains rip
//	STI
//	// rex64 sysexit
//	BYTE	$0x48
//	BYTE	$0x0f
//	BYTE	$0x35
//
//slowsys:
	RET

// this is the bottom half of _userrun() that is executed if a timer int or CPU
// exception is generated during user program execution.
TEXT ·_userint(SB), NOSPLIT, $0-0
	CLI
	// user state is already saved by trap handler.
	// AX holds the interrupt number, BX holds aux (cr2 for page fault)
	MOVQ	AX, RET1(SP)
	MOVQ	BX, RET2(SP)
	//ADDQ	$0x10, SP
	RET

TEXT ·gs_null(SB), NOSPLIT, $8-0
	XORQ	AX, AX
	PUSHQ	AX
	POPQ	GS
	RET

// called exactly once by each CPU
TEXT ·gs_set(SB), NOSPLIT, $0-16
	SWAPGS
	MOVQ	IA32_GS_BASE, CX
	MOVQ	cpu+0(FP), AX
	MOVQ	AX, DX
	ANDQ	$((1 << 32) - 1), AX
	SHRQ	$32, DX
	WRMSR
	SWAPGS
	RET

TEXT ·fs_null(SB), NOSPLIT, $8-0
	XORQ	AX, AX
	PUSHQ	AX
	POPQ	FS
	RET

TEXT ·_Gscpu(SB), NOSPLIT, $0-8
	SWAPGS
	MOVQ	0(GS), AX
	MOVQ	AX, ret+0(FP)
	SWAPGS
	RET

// void backtracetramp(uintptr newsp, uintptr *tf, g *gp)
TEXT ·backtracetramp(SB), NOSPLIT, $0-0x18
	MOVQ	SP, AX
	MOVQ	tf+0x8(FP), DX
	MOVQ	gp+0x10(FP), CX
	MOVQ	newsp+0(FP), SP
	PUSHQ	AX
	PUSHQ	CX
	PUSHQ	DX
	CALL	·nmibacktrace1(SB)
	POPQ	DX
	POPQ	DX
	POPQ	SP
	RET

/*
 *  go-routine
 */

// void gosave(Gobuf*)
// save state in Gobuf; setjmp
TEXT runtime·gosave(SB), NOSPLIT, $0-8
	MOVQ	buf+0(FP), AX		// gobuf
	LEAQ	buf+0(FP), BX		// caller's SP
	MOVQ	BX, gobuf_sp(AX)
	MOVQ	0(SP), BX		// caller's PC
	MOVQ	BX, gobuf_pc(AX)
	MOVQ	$0, gobuf_ret(AX)
	MOVQ	BP, gobuf_bp(AX)
	// Assert ctxt is zero. See func save.
	MOVQ	gobuf_ctxt(AX), BX
	TESTQ	BX, BX
	JZ	2(PC)
	CALL	runtime·badctxt(SB)
	get_tls(CX)
	MOVQ	g(CX), BX
	MOVQ	BX, gobuf_g(AX)
	RET

// void gogo(Gobuf*)
// restore state from Gobuf; longjmp
TEXT runtime·gogo(SB), NOSPLIT, $16-8
	MOVQ	buf+0(FP), BX		// gobuf
	MOVQ	gobuf_g(BX), DX
	MOVQ	0(DX), CX		// make sure g != nil
	get_tls(CX)
	MOVQ	DX, g(CX)
	MOVQ	gobuf_sp(BX), SP	// restore SP
	MOVQ	gobuf_ret(BX), AX
	MOVQ	gobuf_ctxt(BX), DX
	MOVQ	gobuf_bp(BX), BP
	MOVQ	$0, gobuf_sp(BX)	// clear to help garbage collector
	MOVQ	$0, gobuf_ret(BX)
	MOVQ	$0, gobuf_ctxt(BX)
	MOVQ	$0, gobuf_bp(BX)
	MOVQ	gobuf_pc(BX), BX
	JMP	BX

// func mcall(fn func(*g))
// Switch to m->g0's stack, call fn(g).
// Fn must never return. It should gogo(&g->sched)
// to keep running g.
TEXT runtime·mcall(SB), NOSPLIT, $0-8
	MOVQ	fn+0(FP), DI
	
	get_tls(CX)
	MOVQ	g(CX), AX	// save state in g->sched
	MOVQ	0(SP), BX	// caller's PC
	MOVQ	BX, (g_sched+gobuf_pc)(AX)
	LEAQ	fn+0(FP), BX	// caller's SP
	MOVQ	BX, (g_sched+gobuf_sp)(AX)
	MOVQ	AX, (g_sched+gobuf_g)(AX)
	MOVQ	BP, (g_sched+gobuf_bp)(AX)

	// switch to m->g0 & its stack, call fn
	MOVQ	g(CX), BX
	MOVQ	g_m(BX), BX
	MOVQ	m_g0(BX), SI
	CMPQ	SI, AX	// if g == m->g0 call badmcall
	JNE	3(PC)
	MOVQ	$runtime·badmcall(SB), AX
	JMP	AX
	MOVQ	SI, g(CX)	// g = m->g0
	MOVQ	(g_sched+gobuf_sp)(SI), SP	// sp = m->g0->sched.sp
	PUSHQ	AX
	MOVQ	DI, DX
	MOVQ	0(DI), DI
	CALL	DI
	POPQ	AX
	MOVQ	$runtime·badmcall2(SB), AX
	JMP	AX
	RET

// systemstack_switch is a dummy routine that systemstack leaves at the bottom
// of the G stack. We need to distinguish the routine that
// lives at the bottom of the G stack from the one that lives
// at the top of the system stack because the one at the top of
// the system stack terminates the stack walk (see topofstack()).
TEXT runtime·systemstack_switch(SB), NOSPLIT, $0-0
	RET

// func systemstack(fn func())
TEXT runtime·systemstack(SB), NOSPLIT, $0-8
	MOVQ	fn+0(FP), DI	// DI = fn
	get_tls(CX)
	MOVQ	g(CX), AX	// AX = g
	MOVQ	g_m(AX), BX	// BX = m

	CMPQ	AX, m_gsignal(BX)
	JEQ	noswitch

	MOVQ	m_g0(BX), DX	// DX = g0
	CMPQ	AX, DX
	JEQ	noswitch

	CMPQ	AX, m_curg(BX)
	JNE	bad

	// switch stacks
	// save our state in g->sched. Pretend to
	// be systemstack_switch if the G stack is scanned.
	MOVQ	$runtime·systemstack_switch(SB), SI
	MOVQ	SI, (g_sched+gobuf_pc)(AX)
	MOVQ	SP, (g_sched+gobuf_sp)(AX)
	MOVQ	AX, (g_sched+gobuf_g)(AX)
	MOVQ	BP, (g_sched+gobuf_bp)(AX)

	// switch to g0
	MOVQ	DX, g(CX)
	MOVQ	(g_sched+gobuf_sp)(DX), BX
	// make it look like mstart called systemstack on g0, to stop traceback
	SUBQ	$8, BX
	MOVQ	$runtime·mstart(SB), DX
	MOVQ	DX, 0(BX)
	MOVQ	BX, SP

	// call target function
	MOVQ	DI, DX
	MOVQ	0(DI), DI
	CALL	DI

	// switch back to g
	get_tls(CX)
	MOVQ	g(CX), AX
	MOVQ	g_m(AX), BX
	MOVQ	m_curg(BX), AX
	MOVQ	AX, g(CX)
	MOVQ	(g_sched+gobuf_sp)(AX), SP
	MOVQ	$0, (g_sched+gobuf_sp)(AX)
	RET

noswitch:
	// already on m stack; tail call the function
	// Using a tail call here cleans up tracebacks since we won't stop
	// at an intermediate systemstack.
	MOVQ	DI, DX
	MOVQ	0(DI), DI
	JMP	DI

bad:
	// Bad: g is not gsignal, not g0, not curg. What is it?
	MOVQ	$runtime·badsystemstack(SB), AX
	CALL	AX
	INT	$3


/*
 * support for morestack
 */

// Called during function prolog when more stack is needed.
//
// The traceback routines see morestack on a g0 as being
// the top of a stack (for example, morestack calling newstack
// calling the scheduler calling newm calling gc), so we must
// record an argument size. For that purpose, it has no arguments.
TEXT runtime·morestack(SB),NOSPLIT,$0-0
	// Cannot grow scheduler stack (m->g0).
	get_tls(CX)
	MOVQ	g(CX), BX
	MOVQ	g_m(BX), BX
	MOVQ	m_g0(BX), SI
	CMPQ	g(CX), SI
	JNE	3(PC)
	CALL	runtime·badmorestackg0(SB)
	CALL	runtime·abort(SB)

	// Cannot grow signal stack (m->gsignal).
	MOVQ	m_gsignal(BX), SI
	CMPQ	g(CX), SI
	JNE	3(PC)
	CALL	runtime·badmorestackgsignal(SB)
	CALL	runtime·abort(SB)

	// Called from f.
	// Set m->morebuf to f's caller.
	MOVQ	8(SP), AX	// f's caller's PC
	MOVQ	AX, (m_morebuf+gobuf_pc)(BX)
	LEAQ	16(SP), AX	// f's caller's SP
	MOVQ	AX, (m_morebuf+gobuf_sp)(BX)
	get_tls(CX)
	MOVQ	g(CX), SI
	MOVQ	SI, (m_morebuf+gobuf_g)(BX)

	// Set g->sched to context in f.
	MOVQ	0(SP), AX // f's PC
	MOVQ	AX, (g_sched+gobuf_pc)(SI)
	MOVQ	SI, (g_sched+gobuf_g)(SI)
	LEAQ	8(SP), AX // f's SP
	MOVQ	AX, (g_sched+gobuf_sp)(SI)
	MOVQ	BP, (g_sched+gobuf_bp)(SI)
	MOVQ	DX, (g_sched+gobuf_ctxt)(SI)

	// Call newstack on m->g0's stack.
	MOVQ	m_g0(BX), BX
	MOVQ	BX, g(CX)
	MOVQ	(g_sched+gobuf_sp)(BX), SP
	CALL	runtime·newstack(SB)
	CALL	runtime·abort(SB)	// crash if newstack returns
	RET

// morestack but not preserving ctxt.
TEXT runtime·morestack_noctxt(SB),NOSPLIT,$0
	MOVL	$0, DX
	JMP	runtime·morestack(SB)

// reflectcall: call a function with the given argument list
// func call(argtype *_type, f *FuncVal, arg *byte, argsize, retoffset uint32).
// we don't have variable-sized frames, so we use a small number
// of constant-sized-frame functions to encode a few bits of size in the pc.
// Caution: ugly multiline assembly macros in your future!

#define DISPATCH(NAME,MAXSIZE)		\
	CMPQ	CX, $MAXSIZE;		\
	JA	3(PC);			\
	MOVQ	$NAME(SB), AX;		\
	JMP	AX
// Note: can't just "JMP NAME(SB)" - bad inlining results.

TEXT reflect·call(SB), NOSPLIT, $0-0
	JMP	·reflectcall(SB)

TEXT ·reflectcall(SB), NOSPLIT, $0-32
	MOVLQZX argsize+24(FP), CX
	DISPATCH(runtime·call32, 32)
	DISPATCH(runtime·call64, 64)
	DISPATCH(runtime·call128, 128)
	DISPATCH(runtime·call256, 256)
	DISPATCH(runtime·call512, 512)
	DISPATCH(runtime·call1024, 1024)
	DISPATCH(runtime·call2048, 2048)
	DISPATCH(runtime·call4096, 4096)
	DISPATCH(runtime·call8192, 8192)
	DISPATCH(runtime·call16384, 16384)
	DISPATCH(runtime·call32768, 32768)
	DISPATCH(runtime·call65536, 65536)
	DISPATCH(runtime·call131072, 131072)
	DISPATCH(runtime·call262144, 262144)
	DISPATCH(runtime·call524288, 524288)
	DISPATCH(runtime·call1048576, 1048576)
	DISPATCH(runtime·call2097152, 2097152)
	DISPATCH(runtime·call4194304, 4194304)
	DISPATCH(runtime·call8388608, 8388608)
	DISPATCH(runtime·call16777216, 16777216)
	DISPATCH(runtime·call33554432, 33554432)
	DISPATCH(runtime·call67108864, 67108864)
	DISPATCH(runtime·call134217728, 134217728)
	DISPATCH(runtime·call268435456, 268435456)
	DISPATCH(runtime·call536870912, 536870912)
	DISPATCH(runtime·call1073741824, 1073741824)
	MOVQ	$runtime·badreflectcall(SB), AX
	JMP	AX

#define CALLFN(NAME,MAXSIZE)			\
TEXT NAME(SB), WRAPPER, $MAXSIZE-32;		\
	NO_LOCAL_POINTERS;			\
	/* copy arguments to stack */		\
	MOVQ	argptr+16(FP), SI;		\
	MOVLQZX argsize+24(FP), CX;		\
	MOVQ	SP, DI;				\
	REP;MOVSB;				\
	/* call function */			\
	MOVQ	f+8(FP), DX;			\
	PCDATA  $PCDATA_StackMapIndex, $0;	\
	CALL	(DX);				\
	/* copy return values back */		\
	MOVQ	argtype+0(FP), DX;		\
	MOVQ	argptr+16(FP), DI;		\
	MOVLQZX	argsize+24(FP), CX;		\
	MOVLQZX	retoffset+28(FP), BX;		\
	MOVQ	SP, SI;				\
	ADDQ	BX, DI;				\
	ADDQ	BX, SI;				\
	SUBQ	BX, CX;				\
	CALL	callRet<>(SB);			\
	RET

// callRet copies return values back at the end of call*. This is a
// separate function so it can allocate stack space for the arguments
// to reflectcallmove. It does not follow the Go ABI; it expects its
// arguments in registers.
TEXT callRet<>(SB), NOSPLIT, $32-0
	NO_LOCAL_POINTERS
	MOVQ	DX, 0(SP)
	MOVQ	DI, 8(SP)
	MOVQ	SI, 16(SP)
	MOVQ	CX, 24(SP)
	CALL	runtime·reflectcallmove(SB)
	RET

CALLFN(·call32, 32)
CALLFN(·call64, 64)
CALLFN(·call128, 128)
CALLFN(·call256, 256)
CALLFN(·call512, 512)
CALLFN(·call1024, 1024)
CALLFN(·call2048, 2048)
CALLFN(·call4096, 4096)
CALLFN(·call8192, 8192)
CALLFN(·call16384, 16384)
CALLFN(·call32768, 32768)
CALLFN(·call65536, 65536)
CALLFN(·call131072, 131072)
CALLFN(·call262144, 262144)
CALLFN(·call524288, 524288)
CALLFN(·call1048576, 1048576)
CALLFN(·call2097152, 2097152)
CALLFN(·call4194304, 4194304)
CALLFN(·call8388608, 8388608)
CALLFN(·call16777216, 16777216)
CALLFN(·call33554432, 33554432)
CALLFN(·call67108864, 67108864)
CALLFN(·call134217728, 134217728)
CALLFN(·call268435456, 268435456)
CALLFN(·call536870912, 536870912)
CALLFN(·call1073741824, 1073741824)

TEXT runtime·procyield(SB),NOSPLIT,$0-0
	MOVL	cycles+0(FP), AX
again:
	PAUSE
	SUBL	$1, AX
	JNZ	again
	RET


TEXT ·publicationBarrier(SB),NOSPLIT,$0-0
	// Stores are already ordered on x86, so this is just a
	// compile barrier.
	RET

// void jmpdefer(fn, sp);
// called from deferreturn.
// 1. pop the caller
// 2. sub 5 bytes from the callers return
// 3. jmp to the argument
TEXT runtime·jmpdefer(SB), NOSPLIT, $0-16
	MOVQ	fv+0(FP), DX	// fn
	MOVQ	argp+8(FP), BX	// caller sp
	LEAQ	-8(BX), SP	// caller sp after CALL
	MOVQ	-8(SP), BP	// restore BP as if deferreturn returned (harmless if framepointers not in use)
	SUBQ	$5, (SP)	// return to CALL again
	MOVQ	0(DX), BX
	JMP	BX	// but first run the deferred function

// Save state of caller into g->sched. Smashes R8, R9.
TEXT gosave<>(SB),NOSPLIT,$0
	get_tls(R8)
	MOVQ	g(R8), R8
	MOVQ	0(SP), R9
	MOVQ	R9, (g_sched+gobuf_pc)(R8)
	LEAQ	8(SP), R9
	MOVQ	R9, (g_sched+gobuf_sp)(R8)
	MOVQ	$0, (g_sched+gobuf_ret)(R8)
	MOVQ	BP, (g_sched+gobuf_bp)(R8)
	// Assert ctxt is zero. See func save.
	MOVQ	(g_sched+gobuf_ctxt)(R8), R9
	TESTQ	R9, R9
	JZ	2(PC)
	CALL	runtime·badctxt(SB)
	RET

// func asmcgocall(fn, arg unsafe.Pointer) int32
// Call fn(arg) on the scheduler stack,
// aligned appropriately for the gcc ABI.
// See cgocall.go for more details.
TEXT ·asmcgocall(SB),NOSPLIT,$0-20
	MOVQ	fn+0(FP), AX
	MOVQ	arg+8(FP), BX

	MOVQ	SP, DX

	// Figure out if we need to switch to m->g0 stack.
	// We get called to create new OS threads too, and those
	// come in on the m->g0 stack already.
	get_tls(CX)
	MOVQ	g(CX), R8
	CMPQ	R8, $0
	JEQ	nosave
	MOVQ	g_m(R8), R8
	MOVQ	m_g0(R8), SI
	MOVQ	g(CX), DI
	CMPQ	SI, DI
	JEQ	nosave
	MOVQ	m_gsignal(R8), SI
	CMPQ	SI, DI
	JEQ	nosave
	
	// Switch to system stack.
	MOVQ	m_g0(R8), SI
	CALL	gosave<>(SB)
	MOVQ	SI, g(CX)
	MOVQ	(g_sched+gobuf_sp)(SI), SP

	// Now on a scheduling stack (a pthread-created stack).
	// Make sure we have enough room for 4 stack-backed fast-call
	// registers as per windows amd64 calling convention.
	SUBQ	$64, SP
	ANDQ	$~15, SP	// alignment for gcc ABI
	MOVQ	DI, 48(SP)	// save g
	MOVQ	(g_stack+stack_hi)(DI), DI
	SUBQ	DX, DI
	MOVQ	DI, 40(SP)	// save depth in stack (can't just save SP, as stack might be copied during a callback)
	MOVQ	BX, DI		// DI = first argument in AMD64 ABI
	MOVQ	BX, CX		// CX = first argument in Win64
	CALL	AX

	// Restore registers, g, stack pointer.
	get_tls(CX)
	MOVQ	48(SP), DI
	MOVQ	(g_stack+stack_hi)(DI), SI
	SUBQ	40(SP), SI
	MOVQ	DI, g(CX)
	MOVQ	SI, SP

	MOVL	AX, ret+16(FP)
	RET

nosave:
	// Running on a system stack, perhaps even without a g.
	// Having no g can happen during thread creation or thread teardown
	// (see needm/dropm on Solaris, for example).
	// This code is like the above sequence but without saving/restoring g
	// and without worrying about the stack moving out from under us
	// (because we're on a system stack, not a goroutine stack).
	// The above code could be used directly if already on a system stack,
	// but then the only path through this code would be a rare case on Solaris.
	// Using this code for all "already on system stack" calls exercises it more,
	// which should help keep it correct.
	SUBQ	$64, SP
	ANDQ	$~15, SP
	MOVQ	$0, 48(SP)		// where above code stores g, in case someone looks during debugging
	MOVQ	DX, 40(SP)	// save original stack pointer
	MOVQ	BX, DI		// DI = first argument in AMD64 ABI
	MOVQ	BX, CX		// CX = first argument in Win64
	CALL	AX
	MOVQ	40(SP), SI	// restore original stack pointer
	MOVQ	SI, SP
	MOVL	AX, ret+16(FP)
	RET

// cgocallback(void (*fn)(void*), void *frame, uintptr framesize, uintptr ctxt)
// Turn the fn into a Go func (by taking its address) and call
// cgocallback_gofunc.
TEXT runtime·cgocallback(SB),NOSPLIT,$32-32
	LEAQ	fn+0(FP), AX
	MOVQ	AX, 0(SP)
	MOVQ	frame+8(FP), AX
	MOVQ	AX, 8(SP)
	MOVQ	framesize+16(FP), AX
	MOVQ	AX, 16(SP)
	MOVQ	ctxt+24(FP), AX
	MOVQ	AX, 24(SP)
	MOVQ	$runtime·cgocallback_gofunc(SB), AX
	CALL	AX
	RET

// cgocallback_gofunc(FuncVal*, void *frame, uintptr framesize, uintptr ctxt)
// See cgocall.go for more details.
TEXT ·cgocallback_gofunc(SB),NOSPLIT,$16-32
	NO_LOCAL_POINTERS

	// If g is nil, Go did not create the current thread.
	// Call needm to obtain one m for temporary use.
	// In this case, we're running on the thread stack, so there's
	// lots of space, but the linker doesn't know. Hide the call from
	// the linker analysis by using an indirect call through AX.
	get_tls(CX)
#ifdef GOOS_windows
	MOVL	$0, BX
	CMPQ	CX, $0
	JEQ	2(PC)
#endif
	MOVQ	g(CX), BX
	CMPQ	BX, $0
	JEQ	needm
	MOVQ	g_m(BX), BX
	MOVQ	BX, R8 // holds oldm until end of function
	JMP	havem
needm:
	MOVQ	$0, 0(SP)
	MOVQ	$runtime·needm(SB), AX
	CALL	AX
	MOVQ	0(SP), R8
	get_tls(CX)
	MOVQ	g(CX), BX
	MOVQ	g_m(BX), BX
	
	// Set m->sched.sp = SP, so that if a panic happens
	// during the function we are about to execute, it will
	// have a valid SP to run on the g0 stack.
	// The next few lines (after the havem label)
	// will save this SP onto the stack and then write
	// the same SP back to m->sched.sp. That seems redundant,
	// but if an unrecovered panic happens, unwindm will
	// restore the g->sched.sp from the stack location
	// and then systemstack will try to use it. If we don't set it here,
	// that restored SP will be uninitialized (typically 0) and
	// will not be usable.
	MOVQ	m_g0(BX), SI
	MOVQ	SP, (g_sched+gobuf_sp)(SI)

havem:
	// Now there's a valid m, and we're running on its m->g0.
	// Save current m->g0->sched.sp on stack and then set it to SP.
	// Save current sp in m->g0->sched.sp in preparation for
	// switch back to m->curg stack.
	// NOTE: unwindm knows that the saved g->sched.sp is at 0(SP).
	MOVQ	m_g0(BX), SI
	MOVQ	(g_sched+gobuf_sp)(SI), AX
	MOVQ	AX, 0(SP)
	MOVQ	SP, (g_sched+gobuf_sp)(SI)

	// Switch to m->curg stack and call runtime.cgocallbackg.
	// Because we are taking over the execution of m->curg
	// but *not* resuming what had been running, we need to
	// save that information (m->curg->sched) so we can restore it.
	// We can restore m->curg->sched.sp easily, because calling
	// runtime.cgocallbackg leaves SP unchanged upon return.
	// To save m->curg->sched.pc, we push it onto the stack.
	// This has the added benefit that it looks to the traceback
	// routine like cgocallbackg is going to return to that
	// PC (because the frame we allocate below has the same
	// size as cgocallback_gofunc's frame declared above)
	// so that the traceback will seamlessly trace back into
	// the earlier calls.
	//
	// In the new goroutine, 8(SP) holds the saved R8.
	MOVQ	m_curg(BX), SI
	MOVQ	SI, g(CX)
	MOVQ	(g_sched+gobuf_sp)(SI), DI  // prepare stack as DI
	MOVQ	(g_sched+gobuf_pc)(SI), BX
	MOVQ	BX, -8(DI)
	// Compute the size of the frame, including return PC and, if
	// GOEXPERIMENT=framepointer, the saved base pointer
	MOVQ	ctxt+24(FP), BX
	LEAQ	fv+0(FP), AX
	SUBQ	SP, AX
	SUBQ	AX, DI
	MOVQ	DI, SP

	MOVQ	R8, 8(SP)
	MOVQ	BX, 0(SP)
	CALL	runtime·cgocallbackg(SB)
	MOVQ	8(SP), R8

	// Compute the size of the frame again. FP and SP have
	// completely different values here than they did above,
	// but only their difference matters.
	LEAQ	fv+0(FP), AX
	SUBQ	SP, AX

	// Restore g->sched (== m->curg->sched) from saved values.
	get_tls(CX)
	MOVQ	g(CX), SI
	MOVQ	SP, DI
	ADDQ	AX, DI
	MOVQ	-8(DI), BX
	MOVQ	BX, (g_sched+gobuf_pc)(SI)
	MOVQ	DI, (g_sched+gobuf_sp)(SI)

	// Switch back to m->g0's stack and restore m->g0->sched.sp.
	// (Unlike m->curg, the g0 goroutine never uses sched.pc,
	// so we do not have to restore it.)
	MOVQ	g(CX), BX
	MOVQ	g_m(BX), BX
	MOVQ	m_g0(BX), SI
	MOVQ	SI, g(CX)
	MOVQ	(g_sched+gobuf_sp)(SI), SP
	MOVQ	0(SP), AX
	MOVQ	AX, (g_sched+gobuf_sp)(SI)
	
	// If the m on entry was nil, we called needm above to borrow an m
	// for the duration of the call. Since the call is over, return it with dropm.
	CMPQ	R8, $0
	JNE 3(PC)
	MOVQ	$runtime·dropm(SB), AX
	CALL	AX

	// Done!
	RET

// void setg(G*); set g. for use by needm.
TEXT runtime·setg(SB), NOSPLIT, $0-8
	MOVQ	gg+0(FP), BX
#ifdef GOOS_windows
	CMPQ	BX, $0
	JNE	settls
	MOVQ	$0, 0x28(GS)
	RET
settls:
	MOVQ	g_m(BX), AX
	LEAQ	m_tls(AX), AX
	MOVQ	AX, 0x28(GS)
#endif
	get_tls(CX)
	MOVQ	BX, g(CX)
	RET

// void setg_gcc(G*); set g called from gcc.
TEXT setg_gcc<>(SB),NOSPLIT,$0
	get_tls(AX)
	MOVQ	DI, g(AX)
	RET

TEXT runtime·abort(SB),NOSPLIT,$0-0
	INT	$3
loop:
	JMP	loop

// check that SP is in range [g->stack.lo, g->stack.hi)
TEXT runtime·stackcheck(SB), NOSPLIT, $0-0
	get_tls(CX)
	MOVQ	g(CX), AX
	CMPQ	(g_stack+stack_hi)(AX), SP
	JHI	2(PC)
	CALL	runtime·abort(SB)
	CMPQ	SP, (g_stack+stack_lo)(AX)
	JHI	2(PC)
	CALL	runtime·abort(SB)
	RET

// func cputicks() int64
TEXT runtime·cputicks(SB),NOSPLIT,$0-0
	CMPB	runtime·lfenceBeforeRdtsc(SB), $1
	JNE	mfence
	LFENCE
	JMP	done
mfence:
	MFENCE
done:
	RDTSC
	SHLQ	$32, DX
	ADDQ	DX, AX
	MOVQ	AX, ret+0(FP)
	RET

// hash function using AES hardware instructions
TEXT runtime·aeshash(SB),NOSPLIT,$0-32
	MOVQ	p+0(FP), AX	// ptr to data
	MOVQ	s+16(FP), CX	// size
	LEAQ	ret+24(FP), DX
	JMP	runtime·aeshashbody(SB)

TEXT runtime·aeshashstr(SB),NOSPLIT,$0-24
	MOVQ	p+0(FP), AX	// ptr to string struct
	MOVQ	8(AX), CX	// length of string
	MOVQ	(AX), AX	// string data
	LEAQ	ret+16(FP), DX
	JMP	runtime·aeshashbody(SB)

// AX: data
// CX: length
// DX: address to put return value
TEXT runtime·aeshashbody(SB),NOSPLIT,$0-0
	// Fill an SSE register with our seeds.
	MOVQ	h+8(FP), X0			// 64 bits of per-table hash seed
	PINSRW	$4, CX, X0			// 16 bits of length
	PSHUFHW $0, X0, X0			// repeat length 4 times total
	MOVO	X0, X1				// save unscrambled seed
	PXOR	runtime·aeskeysched(SB), X0	// xor in per-process seed
	AESENC	X0, X0				// scramble seed

	CMPQ	CX, $16
	JB	aes0to15
	JE	aes16
	CMPQ	CX, $32
	JBE	aes17to32
	CMPQ	CX, $64
	JBE	aes33to64
	CMPQ	CX, $128
	JBE	aes65to128
	JMP	aes129plus

aes0to15:
	TESTQ	CX, CX
	JE	aes0

	ADDQ	$16, AX
	TESTW	$0xff0, AX
	JE	endofpage

	// 16 bytes loaded at this address won't cross
	// a page boundary, so we can load it directly.
	MOVOU	-16(AX), X1
	ADDQ	CX, CX
	MOVQ	$masks<>(SB), AX
	PAND	(AX)(CX*8), X1
final1:
	PXOR	X0, X1	// xor data with seed
	AESENC	X1, X1	// scramble combo 3 times
	AESENC	X1, X1
	AESENC	X1, X1
	MOVQ	X1, (DX)
	RET

endofpage:
	// address ends in 1111xxxx. Might be up against
	// a page boundary, so load ending at last byte.
	// Then shift bytes down using pshufb.
	MOVOU	-32(AX)(CX*1), X1
	ADDQ	CX, CX
	MOVQ	$shifts<>(SB), AX
	PSHUFB	(AX)(CX*8), X1
	JMP	final1

aes0:
	// Return scrambled input seed
	AESENC	X0, X0
	MOVQ	X0, (DX)
	RET

aes16:
	MOVOU	(AX), X1
	JMP	final1

aes17to32:
	// make second starting seed
	PXOR	runtime·aeskeysched+16(SB), X1
	AESENC	X1, X1
	
	// load data to be hashed
	MOVOU	(AX), X2
	MOVOU	-16(AX)(CX*1), X3

	// xor with seed
	PXOR	X0, X2
	PXOR	X1, X3

	// scramble 3 times
	AESENC	X2, X2
	AESENC	X3, X3
	AESENC	X2, X2
	AESENC	X3, X3
	AESENC	X2, X2
	AESENC	X3, X3

	// combine results
	PXOR	X3, X2
	MOVQ	X2, (DX)
	RET

aes33to64:
	// make 3 more starting seeds
	MOVO	X1, X2
	MOVO	X1, X3
	PXOR	runtime·aeskeysched+16(SB), X1
	PXOR	runtime·aeskeysched+32(SB), X2
	PXOR	runtime·aeskeysched+48(SB), X3
	AESENC	X1, X1
	AESENC	X2, X2
	AESENC	X3, X3
	
	MOVOU	(AX), X4
	MOVOU	16(AX), X5
	MOVOU	-32(AX)(CX*1), X6
	MOVOU	-16(AX)(CX*1), X7

	PXOR	X0, X4
	PXOR	X1, X5
	PXOR	X2, X6
	PXOR	X3, X7
	
	AESENC	X4, X4
	AESENC	X5, X5
	AESENC	X6, X6
	AESENC	X7, X7
	
	AESENC	X4, X4
	AESENC	X5, X5
	AESENC	X6, X6
	AESENC	X7, X7
	
	AESENC	X4, X4
	AESENC	X5, X5
	AESENC	X6, X6
	AESENC	X7, X7

	PXOR	X6, X4
	PXOR	X7, X5
	PXOR	X5, X4
	MOVQ	X4, (DX)
	RET

aes65to128:
	// make 7 more starting seeds
	MOVO	X1, X2
	MOVO	X1, X3
	MOVO	X1, X4
	MOVO	X1, X5
	MOVO	X1, X6
	MOVO	X1, X7
	PXOR	runtime·aeskeysched+16(SB), X1
	PXOR	runtime·aeskeysched+32(SB), X2
	PXOR	runtime·aeskeysched+48(SB), X3
	PXOR	runtime·aeskeysched+64(SB), X4
	PXOR	runtime·aeskeysched+80(SB), X5
	PXOR	runtime·aeskeysched+96(SB), X6
	PXOR	runtime·aeskeysched+112(SB), X7
	AESENC	X1, X1
	AESENC	X2, X2
	AESENC	X3, X3
	AESENC	X4, X4
	AESENC	X5, X5
	AESENC	X6, X6
	AESENC	X7, X7

	// load data
	MOVOU	(AX), X8
	MOVOU	16(AX), X9
	MOVOU	32(AX), X10
	MOVOU	48(AX), X11
	MOVOU	-64(AX)(CX*1), X12
	MOVOU	-48(AX)(CX*1), X13
	MOVOU	-32(AX)(CX*1), X14
	MOVOU	-16(AX)(CX*1), X15

	// xor with seed
	PXOR	X0, X8
	PXOR	X1, X9
	PXOR	X2, X10
	PXOR	X3, X11
	PXOR	X4, X12
	PXOR	X5, X13
	PXOR	X6, X14
	PXOR	X7, X15

	// scramble 3 times
	AESENC	X8, X8
	AESENC	X9, X9
	AESENC	X10, X10
	AESENC	X11, X11
	AESENC	X12, X12
	AESENC	X13, X13
	AESENC	X14, X14
	AESENC	X15, X15

	AESENC	X8, X8
	AESENC	X9, X9
	AESENC	X10, X10
	AESENC	X11, X11
	AESENC	X12, X12
	AESENC	X13, X13
	AESENC	X14, X14
	AESENC	X15, X15

	AESENC	X8, X8
	AESENC	X9, X9
	AESENC	X10, X10
	AESENC	X11, X11
	AESENC	X12, X12
	AESENC	X13, X13
	AESENC	X14, X14
	AESENC	X15, X15

	// combine results
	PXOR	X12, X8
	PXOR	X13, X9
	PXOR	X14, X10
	PXOR	X15, X11
	PXOR	X10, X8
	PXOR	X11, X9
	PXOR	X9, X8
	MOVQ	X8, (DX)
	RET

aes129plus:
	// make 7 more starting seeds
	MOVO	X1, X2
	MOVO	X1, X3
	MOVO	X1, X4
	MOVO	X1, X5
	MOVO	X1, X6
	MOVO	X1, X7
	PXOR	runtime·aeskeysched+16(SB), X1
	PXOR	runtime·aeskeysched+32(SB), X2
	PXOR	runtime·aeskeysched+48(SB), X3
	PXOR	runtime·aeskeysched+64(SB), X4
	PXOR	runtime·aeskeysched+80(SB), X5
	PXOR	runtime·aeskeysched+96(SB), X6
	PXOR	runtime·aeskeysched+112(SB), X7
	AESENC	X1, X1
	AESENC	X2, X2
	AESENC	X3, X3
	AESENC	X4, X4
	AESENC	X5, X5
	AESENC	X6, X6
	AESENC	X7, X7
	
	// start with last (possibly overlapping) block
	MOVOU	-128(AX)(CX*1), X8
	MOVOU	-112(AX)(CX*1), X9
	MOVOU	-96(AX)(CX*1), X10
	MOVOU	-80(AX)(CX*1), X11
	MOVOU	-64(AX)(CX*1), X12
	MOVOU	-48(AX)(CX*1), X13
	MOVOU	-32(AX)(CX*1), X14
	MOVOU	-16(AX)(CX*1), X15

	// xor in seed
	PXOR	X0, X8
	PXOR	X1, X9
	PXOR	X2, X10
	PXOR	X3, X11
	PXOR	X4, X12
	PXOR	X5, X13
	PXOR	X6, X14
	PXOR	X7, X15
	
	// compute number of remaining 128-byte blocks
	DECQ	CX
	SHRQ	$7, CX
	
aesloop:
	// scramble state
	AESENC	X8, X8
	AESENC	X9, X9
	AESENC	X10, X10
	AESENC	X11, X11
	AESENC	X12, X12
	AESENC	X13, X13
	AESENC	X14, X14
	AESENC	X15, X15

	// scramble state, xor in a block
	MOVOU	(AX), X0
	MOVOU	16(AX), X1
	MOVOU	32(AX), X2
	MOVOU	48(AX), X3
	AESENC	X0, X8
	AESENC	X1, X9
	AESENC	X2, X10
	AESENC	X3, X11
	MOVOU	64(AX), X4
	MOVOU	80(AX), X5
	MOVOU	96(AX), X6
	MOVOU	112(AX), X7
	AESENC	X4, X12
	AESENC	X5, X13
	AESENC	X6, X14
	AESENC	X7, X15

	ADDQ	$128, AX
	DECQ	CX
	JNE	aesloop

	// 3 more scrambles to finish
	AESENC	X8, X8
	AESENC	X9, X9
	AESENC	X10, X10
	AESENC	X11, X11
	AESENC	X12, X12
	AESENC	X13, X13
	AESENC	X14, X14
	AESENC	X15, X15
	AESENC	X8, X8
	AESENC	X9, X9
	AESENC	X10, X10
	AESENC	X11, X11
	AESENC	X12, X12
	AESENC	X13, X13
	AESENC	X14, X14
	AESENC	X15, X15
	AESENC	X8, X8
	AESENC	X9, X9
	AESENC	X10, X10
	AESENC	X11, X11
	AESENC	X12, X12
	AESENC	X13, X13
	AESENC	X14, X14
	AESENC	X15, X15

	PXOR	X12, X8
	PXOR	X13, X9
	PXOR	X14, X10
	PXOR	X15, X11
	PXOR	X10, X8
	PXOR	X11, X9
	PXOR	X9, X8
	MOVQ	X8, (DX)
	RET
	
TEXT runtime·aeshash32(SB),NOSPLIT,$0-24
	MOVQ	p+0(FP), AX	// ptr to data
	MOVQ	h+8(FP), X0	// seed
	PINSRD	$2, (AX), X0	// data
	AESENC	runtime·aeskeysched+0(SB), X0
	AESENC	runtime·aeskeysched+16(SB), X0
	AESENC	runtime·aeskeysched+32(SB), X0
	MOVQ	X0, ret+16(FP)
	RET

TEXT runtime·aeshash64(SB),NOSPLIT,$0-24
	MOVQ	p+0(FP), AX	// ptr to data
	MOVQ	h+8(FP), X0	// seed
	PINSRQ	$1, (AX), X0	// data
	AESENC	runtime·aeskeysched+0(SB), X0
	AESENC	runtime·aeskeysched+16(SB), X0
	AESENC	runtime·aeskeysched+32(SB), X0
	MOVQ	X0, ret+16(FP)
	RET

// simple mask to get rid of data in the high part of the register.
DATA masks<>+0x00(SB)/8, $0x0000000000000000
DATA masks<>+0x08(SB)/8, $0x0000000000000000
DATA masks<>+0x10(SB)/8, $0x00000000000000ff
DATA masks<>+0x18(SB)/8, $0x0000000000000000
DATA masks<>+0x20(SB)/8, $0x000000000000ffff
DATA masks<>+0x28(SB)/8, $0x0000000000000000
DATA masks<>+0x30(SB)/8, $0x0000000000ffffff
DATA masks<>+0x38(SB)/8, $0x0000000000000000
DATA masks<>+0x40(SB)/8, $0x00000000ffffffff
DATA masks<>+0x48(SB)/8, $0x0000000000000000
DATA masks<>+0x50(SB)/8, $0x000000ffffffffff
DATA masks<>+0x58(SB)/8, $0x0000000000000000
DATA masks<>+0x60(SB)/8, $0x0000ffffffffffff
DATA masks<>+0x68(SB)/8, $0x0000000000000000
DATA masks<>+0x70(SB)/8, $0x00ffffffffffffff
DATA masks<>+0x78(SB)/8, $0x0000000000000000
DATA masks<>+0x80(SB)/8, $0xffffffffffffffff
DATA masks<>+0x88(SB)/8, $0x0000000000000000
DATA masks<>+0x90(SB)/8, $0xffffffffffffffff
DATA masks<>+0x98(SB)/8, $0x00000000000000ff
DATA masks<>+0xa0(SB)/8, $0xffffffffffffffff
DATA masks<>+0xa8(SB)/8, $0x000000000000ffff
DATA masks<>+0xb0(SB)/8, $0xffffffffffffffff
DATA masks<>+0xb8(SB)/8, $0x0000000000ffffff
DATA masks<>+0xc0(SB)/8, $0xffffffffffffffff
DATA masks<>+0xc8(SB)/8, $0x00000000ffffffff
DATA masks<>+0xd0(SB)/8, $0xffffffffffffffff
DATA masks<>+0xd8(SB)/8, $0x000000ffffffffff
DATA masks<>+0xe0(SB)/8, $0xffffffffffffffff
DATA masks<>+0xe8(SB)/8, $0x0000ffffffffffff
DATA masks<>+0xf0(SB)/8, $0xffffffffffffffff
DATA masks<>+0xf8(SB)/8, $0x00ffffffffffffff
GLOBL masks<>(SB),RODATA,$256

TEXT ·checkASM(SB),NOSPLIT,$0-1
	// check that masks<>(SB) and shifts<>(SB) are aligned to 16-byte
	MOVQ	$masks<>(SB), AX
	MOVQ	$shifts<>(SB), BX
	ORQ	BX, AX
	TESTQ	$15, AX
	SETEQ	ret+0(FP)
	RET

// these are arguments to pshufb. They move data down from
// the high bytes of the register to the low bytes of the register.
// index is how many bytes to move.
DATA shifts<>+0x00(SB)/8, $0x0000000000000000
DATA shifts<>+0x08(SB)/8, $0x0000000000000000
DATA shifts<>+0x10(SB)/8, $0xffffffffffffff0f
DATA shifts<>+0x18(SB)/8, $0xffffffffffffffff
DATA shifts<>+0x20(SB)/8, $0xffffffffffff0f0e
DATA shifts<>+0x28(SB)/8, $0xffffffffffffffff
DATA shifts<>+0x30(SB)/8, $0xffffffffff0f0e0d
DATA shifts<>+0x38(SB)/8, $0xffffffffffffffff
DATA shifts<>+0x40(SB)/8, $0xffffffff0f0e0d0c
DATA shifts<>+0x48(SB)/8, $0xffffffffffffffff
DATA shifts<>+0x50(SB)/8, $0xffffff0f0e0d0c0b
DATA shifts<>+0x58(SB)/8, $0xffffffffffffffff
DATA shifts<>+0x60(SB)/8, $0xffff0f0e0d0c0b0a
DATA shifts<>+0x68(SB)/8, $0xffffffffffffffff
DATA shifts<>+0x70(SB)/8, $0xff0f0e0d0c0b0a09
DATA shifts<>+0x78(SB)/8, $0xffffffffffffffff
DATA shifts<>+0x80(SB)/8, $0x0f0e0d0c0b0a0908
DATA shifts<>+0x88(SB)/8, $0xffffffffffffffff
DATA shifts<>+0x90(SB)/8, $0x0e0d0c0b0a090807
DATA shifts<>+0x98(SB)/8, $0xffffffffffffff0f
DATA shifts<>+0xa0(SB)/8, $0x0d0c0b0a09080706
DATA shifts<>+0xa8(SB)/8, $0xffffffffffff0f0e
DATA shifts<>+0xb0(SB)/8, $0x0c0b0a0908070605
DATA shifts<>+0xb8(SB)/8, $0xffffffffff0f0e0d
DATA shifts<>+0xc0(SB)/8, $0x0b0a090807060504
DATA shifts<>+0xc8(SB)/8, $0xffffffff0f0e0d0c
DATA shifts<>+0xd0(SB)/8, $0x0a09080706050403
DATA shifts<>+0xd8(SB)/8, $0xffffff0f0e0d0c0b
DATA shifts<>+0xe0(SB)/8, $0x0908070605040302
DATA shifts<>+0xe8(SB)/8, $0xffff0f0e0d0c0b0a
DATA shifts<>+0xf0(SB)/8, $0x0807060504030201
DATA shifts<>+0xf8(SB)/8, $0xff0f0e0d0c0b0a09
GLOBL shifts<>(SB),RODATA,$256

TEXT runtime·return0(SB), NOSPLIT, $0
	MOVL	$0, AX
	RET


// Called from cgo wrappers, this function returns g->m->curg.stack.hi.
// Must obey the gcc calling convention.
TEXT _cgo_topofstack(SB),NOSPLIT,$0
	get_tls(CX)
	MOVQ	g(CX), AX
	MOVQ	g_m(AX), AX
	MOVQ	m_curg(AX), AX
	MOVQ	(g_stack+stack_hi)(AX), AX
	RET

// The top-most function running on a goroutine
// returns to goexit+PCQuantum.
TEXT runtime·goexit(SB),NOSPLIT,$0-0
	BYTE	$0x90	// NOP
	CALL	runtime·goexit1(SB)	// does not return
	// traceback from goexit1 must hit code range of goexit
	BYTE	$0x90	// NOP

// This is called from .init_array and follows the platform, not Go, ABI.
TEXT runtime·addmoduledata(SB),NOSPLIT,$0-0
	PUSHQ	R15 // The access to global variables below implicitly uses R15, which is callee-save
	MOVQ	runtime·lastmoduledatap(SB), AX
	MOVQ	DI, moduledata_next(AX)
	MOVQ	DI, runtime·lastmoduledatap(SB)
	POPQ	R15
	RET

// gcWriteBarrier performs a heap pointer write and informs the GC.
//
// gcWriteBarrier does NOT follow the Go ABI. It takes two arguments:
// - DI is the destination of the write
// - AX is the value being written at DI
// It clobbers FLAGS. It does not clobber any general-purpose registers,
// but may clobber others (e.g., SSE registers).
TEXT runtime·gcWriteBarrier(SB),NOSPLIT,$120
	// Save the registers clobbered by the fast path. This is slightly
	// faster than having the caller spill these.
	MOVQ	R14, 104(SP)
	MOVQ	R13, 112(SP)
	// TODO: Consider passing g.m.p in as an argument so they can be shared
	// across a sequence of write barriers.
	get_tls(R13)
	MOVQ	g(R13), R13
	MOVQ	g_m(R13), R13
	MOVQ	m_p(R13), R13
	MOVQ	(p_wbBuf+wbBuf_next)(R13), R14
	// Increment wbBuf.next position.
	LEAQ	16(R14), R14
	MOVQ	R14, (p_wbBuf+wbBuf_next)(R13)
	CMPQ	R14, (p_wbBuf+wbBuf_end)(R13)
	// Record the write.
	MOVQ	AX, -16(R14)	// Record value
	// Note: This turns bad pointer writes into bad
	// pointer reads, which could be confusing. We could avoid
	// reading from obviously bad pointers, which would
	// take care of the vast majority of these. We could
	// patch this up in the signal handler, or use XCHG to
	// combine the read and the write.
	MOVQ	(DI), R13
	MOVQ	R13, -8(R14)	// Record *slot
	// Is the buffer full? (flags set in CMPQ above)
	JEQ	flush
ret:
	MOVQ	104(SP), R14
	MOVQ	112(SP), R13
	// Do the write.
	MOVQ	AX, (DI)
	RET

flush:
	// Save all general purpose registers since these could be
	// clobbered by wbBufFlush and were not saved by the caller.
	// It is possible for wbBufFlush to clobber other registers
	// (e.g., SSE registers), but the compiler takes care of saving
	// those in the caller if necessary. This strikes a balance
	// with registers that are likely to be used.
	//
	// We don't have type information for these, but all code under
	// here is NOSPLIT, so nothing will observe these.
	//
	// TODO: We could strike a different balance; e.g., saving X0
	// and not saving GP registers that are less likely to be used.
	MOVQ	DI, 0(SP)	// Also first argument to wbBufFlush
	MOVQ	AX, 8(SP)	// Also second argument to wbBufFlush
	MOVQ	BX, 16(SP)
	MOVQ	CX, 24(SP)
	MOVQ	DX, 32(SP)
	// DI already saved
	MOVQ	SI, 40(SP)
	MOVQ	BP, 48(SP)
	MOVQ	R8, 56(SP)
	MOVQ	R9, 64(SP)
	MOVQ	R10, 72(SP)
	MOVQ	R11, 80(SP)
	MOVQ	R12, 88(SP)
	// R13 already saved
	// R14 already saved
	MOVQ	R15, 96(SP)

	// This takes arguments DI and AX
	CALL	runtime·wbBufFlush(SB)

	MOVQ	0(SP), DI
	MOVQ	8(SP), AX
	MOVQ	16(SP), BX
	MOVQ	24(SP), CX
	MOVQ	32(SP), DX
	MOVQ	40(SP), SI
	MOVQ	48(SP), BP
	MOVQ	56(SP), R8
	MOVQ	64(SP), R9
	MOVQ	72(SP), R10
	MOVQ	80(SP), R11
	MOVQ	88(SP), R12
	MOVQ	96(SP), R15
	JMP	ret
