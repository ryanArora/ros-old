.code16
.globl _start

// ------------------
// SYMBOLIC CONSTANTS
// ------------------

.equ MBR_PARTITION_TABLE_ENTRY_STATUS_BOOTABLE,		0x80
.equ MBR_PARTITION_TABLE_ENTRY_TYPE_FAT32LBA,		0x0C

.equ DIRECTORY_ENTRY_NAME_OFFSET,			0
.equ DIRECTORY_ENTRY_ATTR_OFFSET,			11
.equ DIRECTORY_ENTRY_FstClusHI_OFFSET,		20
.equ DIRECTORY_ENTRY_FstClusLO_OFFSET, 		26
.equ DIRECTORY_ENTRY_FileSize_OFFSET, 		28

.equ DIRECTORY_ENTRY_ATTR_ARCHIVE,		0x20

// ----------------
// MEMORY ADDRESSES
// ----------------

// SECTOR 1: MBR (0x7C00)
.equ MBR_START,									0x7C00
.equ MBR_PARTITION_TABLE,						MBR_START + 446
.equ MBR_PARTITION_TABLE_P1,					MBR_PARTITION_TABLE
.equ MBR_PARTITION_TABLE_P1_STATUS,				MBR_PARTITION_TABLE_P1 + 0x00
.equ MBR_PARTITION_TABLE_P1_TYPE,				MBR_PARTITION_TABLE_P1 + 0x04
.equ MBR_PARTITION_TABLE_P1_START_SECTOR,		MBR_PARTITION_TABLE_P1 + 0x08
.equ MBR_PARTITION_TABLE_P1_SECTORS,			MBR_PARTITION_TABLE_P1 + 0x0C

// SECTOR 2: BPB (0x7E00)
.equ BPB_START,				0x7E00
.equ BPB_SecPerClus,		BPB_START + 13
.equ BPB_RsvdSecCnt,		BPB_START + 14
.equ BPB_NumFATs,			BPB_START + 16
.equ BPB_FATSz32,			BPB_START + 36
.equ BPB_RootClus,			BPB_START + 44

// SECTOR 3: CURRENT_FAT (0x8000)
.equ CURRENT_FAT,		0x8000

// SECTOR 4: CURRENT_CLUSTER (0x8200)
.equ CURRENT_CLUSTER,	0x8200

// -----
// START
// -----

_start:
	// setup ds segment and stack
	xor %ax, %ax
	mov %ax, %ds
	mov %ax, %ss
	mov $_start, %sp

	call check_p1_is_bootable
	call check_p1_is_fat32lba

	call load_stage2
	jmp CURRENT_CLUSTER

exit_failure:
	mov $'E', %al
	mov $0x0E, %ah
	xor %bh, %bh
	int $0x10
die:
	hlt
	jmp die

// ----------
// PROCEDURES
// ----------

load_stage2:
	call load_bpb
 
	call get_stage2_start_cluster # ax
	mov $0x820, %bx
	mov %bx, %es # es - segment
	xor %di, %di # di - offset 0
	movb %ds:(BPB_SecPerClus), %bl
	xor %bh, %bh
	shl $5, %bx # bx - increment es

	loop:
	mov $0xFFFF, %cx
	cmp %ax, %cx
	je loop_end

	push %di
	push %es
	push %bx
	push %ax
	call load_cluster
	loop_continue:
	pop %ax
	call get_next_cluster
	pop %bx
	pop %es
	pop %di

	mov %es, %dx
	add %bx, %dx
	mov %dx, %es

	jmp loop
	loop_end:
	ret

load_bpb:
	// The disk address packet is initialized to the default values for load_bpb.
	// We only must load the runtime value for disk_address_packet_start_sector.

	// check_p1_start_sector_16bit
	mov $MBR_PARTITION_TABLE_P1_START_SECTOR + 2, %si
	call assert_zero

	mov %ds:(MBR_PARTITION_TABLE_P1_START_SECTOR), %ax
	mov %ax, %ds:(disk_address_packet_start_sector)
	call load
	ret

// ---------
// FUNCTIONS
// ---------

// Precondition: disk_address_packet is initialized.
//
// void load();
load:
	mov $0x42, %ah
	mov $0x80, %dl
	mov $disk_address_packet, %si
	int $0x13
	jnc load_done
	jmp exit_failure
	load_done:
	ret

// void load_cluster(cluster %ax, address %es:(%di));
load_cluster:
	// cx = partition_start_sector + RsvdSecCnt
	mov %ds:(MBR_PARTITION_TABLE_P1_START_SECTOR), %cx
	add %ds:(BPB_RsvdSecCnt), %cx
	jc exit_failure

	// cx += (cluster - 2) * SecPerClus
	add $-2, %ax
	movb %ds:(BPB_SecPerClus), %dl

	// We need to set the disk address packet number of sectors to SecPerClus anyways...
	// Might as well do it now to save an instruction.
	// Ignore the upper byte because its never nonzeroed.
	movb %dl, %ds:(disk_address_packet_sectors)
	
	xor %dh, %dh
	mul %dx
	jc exit_failure
	add %ax, %cx
	jc exit_failure

	// cx += FatSz32 * NumFATs
	mov %ds:(BPB_FATSz32), %ax
	mov %ds:(BPB_NumFATs), %dl
	xor %dh, %dh
	mul %dx
	jc exit_failure
	add %ax, %cx
	jc exit_failure

	// Ignore the upper 6 bytes because they are never nonzeroed.
	mov %cx, %ds:(disk_address_packet_start_sector)

	mov %es, %ds:(disk_address_packet_segment)
	mov %di, %ds:(disk_address_packet_offset)

	call load
	ret

// %ax get_is_stage2_filename(char* %ds:(%si));
get_is_stage2_filename:
	push %si

	mov $stage2_filename, %di
	mov %si, %dx
	add $11, %dx
	get_is_stage2_filename_loop:
	cmp %si, %dx
	je get_is_stage2_filename_loop_done
	movb %ds:(%si), %al
	movb %ds:(%di), %ah
	cmp %al, %ah
	jne get_is_stage2_filename_ne
	get_is_stage2_filename_loop_continue:
	inc %si
	inc %di
	jmp get_is_stage2_filename_loop
	get_is_stage2_filename_loop_done:
	get_is_stage2_filename_e:
	mov $1, %ax
	jmp get_is_stage2_filename_done
	get_is_stage2_filename_ne:
	xor %ax, %ax
	get_is_stage2_filename_done:

	pop %si
	ret

// Limitation: Only reads one cluster of the root directory.
// Precondition: load_bpb has been called.
//
// uint16_t get_stage2_start_cluster();
get_stage2_start_cluster:
	// check_bpb_rootclus_16bit
	mov $BPB_RootClus + 2, %si
	call assert_zero
	
	// Load Root Cluster
	xor %ax, %ax
	mov %ax, %es
	mov $CURRENT_CLUSTER, %di
	mov %ds:(BPB_RootClus), %ax
	call load_cluster

	# si = Loop Counter
	mov $CURRENT_CLUSTER, %si
	# bx = exclusive max for si.
	mov %si, %bx
	mov %ds:(BPB_SecPerClus), %ax
	mov $512, %cx
	mul %cx
	add %ax, %bx

	get_stage2_start_cluster_loop:
	cmp %si, %bx
	je get_stage2_start_cluster_loop_end

	# Check if the directory entry is a file.
	mov %si, %di
	add $DIRECTORY_ENTRY_ATTR_OFFSET, %di
	mov $DIRECTORY_ENTRY_ATTR_ARCHIVE, %cl
	cmpb %ds:(%di), %cl
	jne get_stage2_start_cluster_loop_continue

	# Check if the filename is stage2.bin
	call get_is_stage2_filename
	xor %cx, %cx
	cmp %ax, %cx
	je get_stage2_start_cluster_loop_continue

	# In this case we are good!
	# we can corrupt %si because we're about to return
	add $DIRECTORY_ENTRY_FstClusHI_OFFSET, %si
	// check_directoryentry_fstclus_16bit
	call assert_zero

	add $DIRECTORY_ENTRY_FstClusLO_OFFSET - DIRECTORY_ENTRY_FstClusHI_OFFSET, %si
	mov %ds:(%si), %ax
	jmp get_stage2_start_cluster_found

	get_stage2_start_cluster_loop_continue:
	add $32, %si
	jmp get_stage2_start_cluster_loop
	get_stage2_start_cluster_loop_end:
	get_stage2_start_cluster_not_found:
	jmp exit_failure

	get_stage2_start_cluster_found:
	ret

# uint16_t get_next_cluster(current_cluster %ax);
get_next_cluster:
	mov $4, %bx
	mul %bx
	# ax = FatOffset

	mov $512, %bx
	div %bx
	add %ds:(MBR_PARTITION_TABLE_P1_START_SECTOR), %ax
	add %ds:(BPB_RsvdSecCnt), %ax
	# ax = offset + BPB_RsvdSecCnt + (FatOffset / 512)
	# dx = FatOffset % 512

	movw $1, %ds:(disk_address_packet_sectors)
	movw $CURRENT_FAT, %ds:(disk_address_packet_offset)
	movw $0, %ds:(disk_address_packet_segment)
	movw %ax, %ds:(disk_address_packet_start_sector)

	push %ax
	push %dx
	call load
	pop %dx
	pop %ax

	mov $CURRENT_FAT, %si
	add %dx, %si
	mov %ds:(%si), %ax
	add $2, %si
	mov %ds:(%si), %bx
	and $0x0FFF, %bx

	mov $0xFFFF, %cx
	cmp %ax, %cx
	jne get_next_cluster_not_final
	mov $0x0FFF, %cx
	cmp %bx, %cx
	jne get_next_cluster_not_final
	get_next_cluster_final:
	jmp get_next_cluster_done
	get_next_cluster_not_final:
	// check_fatentry_16bit
	call assert_zero
	get_next_cluster_done:
	ret

// -------------
// SANITY CHECKS
// -------------

check_p1_is_bootable:
	movb $MBR_PARTITION_TABLE_ENTRY_STATUS_BOOTABLE, %al
	cmp %al, %ds:(MBR_PARTITION_TABLE_P1_STATUS)
	je check_p1_is_bootable_done
	jmp exit_failure
	check_p1_is_bootable_done:
	ret

check_p1_is_fat32lba:
	movb $MBR_PARTITION_TABLE_ENTRY_TYPE_FAT32LBA, %al
	cmp %al, %ds:(MBR_PARTITION_TABLE_P1_TYPE)
	je check_p1_is_fat32lba_done
	jmp exit_failure
	check_p1_is_fat32lba_done:
	ret

// void assert_zero(%ds:(si));
assert_zero:
	push %ax
	xor %ax, %ax
	cmp %ax, %ds:(%si)
	je assert_zero_done
	jmp exit_failure
	assert_zero_done:
	pop %ax
	ret


// ----
// DATA
// ----

data:
stage2_filename:
.string "STAGE2  BIN"
// This is initialized to the default values for the first caller, load_bpb
// disk_address_packet_sector must be found at runtime.
disk_address_packet:
.byte 0x10
.byte 0x00
disk_address_packet_sectors:
.word 1
disk_address_packet_offset:
.word BPB_START
disk_address_packet_segment:
.word 0
disk_address_packet_start_sector:
.quad 0
