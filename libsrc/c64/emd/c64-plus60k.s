;
; Extended memory driver for the +60K memory expansion
; Marco van den Heuvel, 2015-12-03
;

        .include        "zeropage.inc"

        .include        "em-kernel.inc"
        .include        "em-error.inc"


        .macpack        generic
        .macpack        module


; ------------------------------------------------------------------------
; Header. Includes jump table

        module_header   _c64_plus60k_emd

; Driver signature

        .byte   $65, $6d, $64           ; "emd"
        .byte   EMD_API_VERSION         ; EM API version number

; Library reference

        .addr   $0000

; Jump table

        .addr   INSTALL
        .addr   UNINSTALL
        .addr   PAGECOUNT
        .addr   MAP
        .addr   USE
        .addr   COMMIT
        .addr   COPYFROM
        .addr   COPYTO

; ------------------------------------------------------------------------
; Constants

BASE                    = $1000
PAGES                   = 240
TARGETLOC               = $200          ; Target location for copy/check code
SWPLUS60K               = $D120

; ------------------------------------------------------------------------
; Data.

.data


; This function is used to copy code from and to the extended memory
.proc   copy
template:
.org    ::TARGETLOC             ; Assemble for target location
entry:
        pha
        dec     SWPLUS60K       ; switch to bank 1
        ldx     $01             ; Remember c64 control port
        txa
        and     #$F8            ; Bank out ROMs, I/O
        sta     $01
        pla
stashop         = $91           ; 'sta' opcode
operation       := *            ; Location and opcode is patched at runtime
address         := *+1
        lda     ($00),y
        stx     $01
        inc     SWPLUS60K       ; switch to bank 0
        rts
.reloc
.endproc

; This function is used to check for the existence of the extended memory
.proc   check
template:
.org    ::TARGETLOC
entry:
        ldy     #$00            ; Assume hardware not present
        ldx     #$ff
        inc     SWPLUS60K       ; switch to bank 1
        cpx     SWPLUS60K
        bne     @done
        dec     SWPLUS60K       ; switch to bank 0
        ldx     $1000
        inc     SWPLUS60K       ; switch to bank 1
        cpx     $1000
        bne     @plus60kpresent
        inc     $1000
        inc     SWPLUS60K       ; switch to bank 0
        cpx     $1000
        beq     @plus60kpresent
        dec     $1000
@done:
        rts
@plus60kpresent:
        iny
        rts
.reloc
.endproc



.bss

curpage:        .res    1       ; Current page number
window:         .res    256     ; Memory "window"

; Since the functions above are copied to $200, the current contents of this
; memory area must be saved into backup storage. Allocate enough space.
backup:         .res    .max (.sizeof (copy), .sizeof (check))



.code
; ------------------------------------------------------------------------
; INSTALL routine. Is called after the driver is loaded into memory. If
; possible, check if the hardware is present and determine the amount of
; memory available.
; Must return an EM_ERR_xx code in a/x.
;

INSTALL:
        ldx     #$ff
        cpx     SWPLUS60K       ; if +60k is present, this always returns #$ff
        bne     @notpresent
        sei
        jsr     backup_and_setup_check_routine
        jsr     check::entry
        ldx     #.sizeof (check) - 1
        jsr     restore_data
        cli
        cpy     #$01
        beq     @present
@notpresent:
        lda     #<EM_ERR_NO_DEVICE
        ldx     #>EM_ERR_NO_DEVICE
        rts

@present:
        lda     #<EM_ERR_OK
        ldx     #>EM_ERR_OK
;       rts                     ; Run into UNINSTALL instead

; ------------------------------------------------------------------------
; UNINSTALL routine. Is called before the driver is removed from memory.
; Can do cleanup or whatever. Must not return anything.
;

UNINSTALL:
        rts


; ------------------------------------------------------------------------
; PAGECOUNT: Return the total number of available pages in a/x.
;

PAGECOUNT:
        lda     #<PAGES
        ldx     #>PAGES
        rts

; ------------------------------------------------------------------------
; MAP: Map the page in a/x into memory and return a pointer to the page in
; a/x. The contents of the currently mapped page (if any) may be discarded
; by the driver.
;

MAP:
        sta     curpage         ; Remember the new page
        clc
        adc     #>BASE
        sta     ptr1+1
        ldy     #0
        sty     ptr1
        sei
        jsr     backup_and_setup_copy_routine
        ldx     #<ptr1
        stx     copy::address
@L1:
        jsr     copy::entry
        ldx     ptr1
        sta     window,x
        inc     ptr1
        bne     @L1

; Return the memory window

        jsr     restore_copy_routine
        cli
        lda     #<window
        ldx     #>window                ; Return the window address
        rts

; ------------------------------------------------------------------------
; USE: Tell the driver that the window is now associated with a given page.

USE:    sta     curpage                ; Remember the page
        lda     #<window
        ldx     #>window               ; Return the window
        rts

; ------------------------------------------------------------------------
; COMMIT: Commit changes in the memory window to extended storage.

COMMIT:
        lda     curpage         ; Get the current page

        clc
        adc     #>BASE
        sta     ptr1+1
        ldy     #0
        sty     ptr1
        sei
        jsr     backup_and_setup_copy_routine
        ldx     #<ptr1
        stx     copy::address
        ldx     #<copy::stashop
        stx     copy::operation
@L1:
        ldx     ptr1
        lda     window,x
        jsr     copy::entry
        inc     ptr1
        bne     @L1

        jsr     restore_copy_routine
done:
        cli
        rts

; ------------------------------------------------------------------------
; COPYFROM: Copy from extended into linear memory. A pointer to a structure
; describing the request is passed in a/x.
; The function must not return anything.
;


COPYFROM:
        jsr     setup
        sei
        jsr     backup_and_setup_copy_routine

; Setup is:
;
;   - ptr1 contains the struct pointer
;   - ptr2 contains the linear memory buffer
;   - ptr3 contains -(count-1)
;   - ptr4 contains the page memory buffer plus offset
;   - tmp1 contains zero (to be used for linear memory buffer offset)

        lda     #<ptr4
        sta     copy::address
        jmp     @L3

@L1:
        ldy     #0
        jsr     copy::entry
        ldy     tmp1
        sta     (ptr2),y
        inc     tmp1
        bne     @L2
        inc     ptr2+1
@L2:
        inc     ptr4
        beq     @L4

; Bump count and repeat

@L3:
        inc     ptr3
        bne     @L1
        inc     ptr3+1
        bne     @L1
        jsr     restore_copy_routine
        cli
        rts

; Bump page register

@L4:
        inc     ptr4+1
        jmp     @L3

; ------------------------------------------------------------------------
; COPYTO: Copy from linear into extended memory. A pointer to a structure
; describing the request is passed in a/x.
; The function must not return anything.
;

COPYTO:
        jsr     setup
        sei

; Setup is:
;
;   - ptr1 contains the struct pointer
;   - ptr2 contains the linear memory buffer
;   - ptr3 contains -(count-1)
;   - ptr4 contains the page memory buffer plus offset
;   - tmp1 contains zero (to be used for linear memory buffer offset)
;   - tmp2 contains the bank value

        lda     #<ptr4
        sta     copy::address
        lda     #<copy::stashop
        sta     copy::operation
        jmp     @L3

@L1:
        ldy     tmp1
        lda     (ptr2),y
        ldy     #0
        jsr     copy::entry
        inc     tmp1
        bne     @L2
        inc     ptr2+1
@L2:
        inc     ptr4
        beq     @L4

; Bump count and repeat

@L3:
        inc     ptr3
        bne     @L1
        inc     ptr3+1
        bne     @L1
        jsr     restore_copy_routine
        cli
        rts

; Bump page register

@L4:
        inc     ptr4+1
        jmp     @L3

; ------------------------------------------------------------------------
; Helper function for COPYFROM and COPYTO: Store the pointer to the request
; structure and prepare data for the copy

setup:
        sta     ptr1
        stx     ptr1+1                                  ; Save passed pointer

; Get the page number from the struct

        ldy     #EM_COPY::PAGE
        lda     (ptr1),y
        clc
        adc     #>BASE
        sta     ptr4+1

; Get the page offset into ptr4

        ldy     #EM_COPY::OFFS
        lda     (ptr1),y
        sta     ptr4

; Get the buffer pointer into ptr2

        ldy     #EM_COPY::BUF
        lda     (ptr1),y
        sta     ptr2
        iny
        lda     (ptr1),y
        sta     ptr2+1

; Get the count, calculate -(count-1) and store it into ptr3

        ldy     #EM_COPY::COUNT
        lda     (ptr1),y
        eor     #$FF
        sta     ptr3
        iny
        lda     (ptr1),y
        eor     #$FF
        sta     ptr3+1

; Clear tmp1

        lda     #$00
        sta     tmp1

; Done

        rts

; Helper routines for copying to and from the +60k ram

backup_and_setup_copy_routine:
        ldx     #.sizeof (copy) - 1
@L1:
        lda     copy::entry,x
        sta     backup,x
        lda     copy::template,x
        sta     copy::entry,x
        dex
        bpl     @L1
        rts

backup_and_setup_check_routine:
        ldx     #.sizeof (check) - 1
@L1:
        lda     check::entry,x
        sta     backup,x
        lda     check::template,x
        sta     check::entry,x
        dex
        bpl     @L1
        rts

restore_copy_routine:
        ldx     #.sizeof (copy) - 1
restore_data:
        lda     backup,x
        sta     TARGETLOC,x
        dex
        bpl     restore_data
        rts
