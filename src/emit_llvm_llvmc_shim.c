#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdio.h>
#include <llvm-c/Core.h>
#include <llvm-c/BitWriter.h>
#include <llvm-c/Analysis.h>
#include <llvm-c/DebugInfo.h>
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>

typedef enum { SA_T_VOID=0, SA_T_I1=1, SA_T_I8=2, SA_T_I16=3, SA_T_I32=4, SA_T_I64=5, SA_T_F32=6, SA_T_F64=7, SA_T_PTR=8, SA_T_U8=9, SA_T_U16=10, SA_T_U32=11, SA_T_U64=12 } SaType;
typedef enum { SA_F_NORMAL=0, SA_F_EXTERNAL=1, SA_F_EXPORTED=2, SA_F_TEST=3 } SaFuncKind;
typedef enum { SA_OP_NONE=0, SA_OP_LABEL=1, SA_OP_ALLOC=2, SA_OP_STACK_ALLOC=3, SA_OP_LOAD=4, SA_OP_STORE=5, SA_OP_BINOP=6, SA_OP_PTR_ADD=7, SA_OP_JMP=8, SA_OP_BR=9, SA_OP_CALL=10, SA_OP_RET=11, SA_OP_PANIC=12, SA_OP_PANIC_MSG=13, SA_OP_ATOMIC_LOAD=14, SA_OP_ATOMIC_STORE=15, SA_OP_ATOMIC_RMW=16, SA_OP_CMPXCHG=17, SA_OP_FENCE=18, SA_OP_TRY=19, SA_OP_CALL_INDIRECT=20, SA_OP_ASSIGN=21 } SaOp;
typedef enum { SA_OPER_NONE=0, SA_OPER_REG=1, SA_OPER_IMM_I64=2, SA_OPER_IMM_U64=3, SA_OPER_CONST_PTR=4 } SaOperandKind;
typedef enum { SA_BIN_ADD=0, SA_BIN_SUB=1, SA_BIN_MUL=2, SA_BIN_SDIV=3, SA_BIN_UDIV=4, SA_BIN_SREM=5, SA_BIN_UREM=6, SA_BIN_AND=7, SA_BIN_OR=8, SA_BIN_XOR=9, SA_BIN_SHL=10, SA_BIN_LSHR=11, SA_BIN_ASHR=12, SA_BIN_EQ=13, SA_BIN_NE=14, SA_BIN_SLT=15, SA_BIN_SLE=16, SA_BIN_SGT=17, SA_BIN_SGE=18, SA_BIN_ULT=19, SA_BIN_ULE=20, SA_BIN_UGT=21, SA_BIN_UGE=22 } SaBinaryOp;
typedef enum { SA_ATOMIC_RELAXED=0, SA_ATOMIC_ACQUIRE=1, SA_ATOMIC_RELEASE=2, SA_ATOMIC_ACQ_REL=3, SA_ATOMIC_SEQ_CST=4 } SaAtomicOrdering;
typedef enum { SA_RMW_ADD=0, SA_RMW_SUB=1, SA_RMW_AND=2, SA_RMW_OR=3, SA_RMW_XOR=4, SA_RMW_XCHG=5, SA_RMW_MIN=6, SA_RMW_MAX=7, SA_RMW_UMIN=8, SA_RMW_UMAX=9 } SaAtomicRmwOp;

typedef struct { const char *name; const unsigned char *data; size_t len; } SaConst;
typedef struct { const char *name; const char *const *funcs; size_t func_count; } SaVTable;
typedef struct { const char *name; SaType ty; unsigned int slot; } SaParam;
typedef struct { unsigned int line; unsigned int col; } SaDebugLoc;
typedef struct { const char *name; SaType ty; unsigned int slot; unsigned char is_param; unsigned int line; unsigned int col; } SaDebugVar;
typedef struct { SaOperandKind kind; unsigned int reg; long long i64_value; unsigned long long u64_value; SaType ty; const char *name; } SaOperand;
typedef struct {
    SaOp op;
    unsigned int dst;
    SaOperand operand0;
    SaOperand operand1;
    SaOperand operand2;
    SaType ty;
    SaBinaryOp binary_op;
    const char *label;
    const char *false_label;
    const char *callee;
    const SaOperand *args;
    size_t arg_count;
    const SaType *indirect_param_tys;
    size_t indirect_param_count;
    unsigned char has_dst;
    SaAtomicOrdering atomic_ordering;
    SaAtomicOrdering atomic_second_ordering;
    SaAtomicRmwOp atomic_rmw_op;
    unsigned char return_fallible;
    unsigned int indirect_sig_index;
} SaInstruction;
typedef struct {
    const char *name;
    SaFuncKind kind;
    SaType ret_ty;
    unsigned char return_fallible;
    const SaParam *params;
    size_t param_count;
    const SaInstruction *instructions;
    size_t instruction_count;
    const char *source_file;
    const char *source_dir;
    unsigned int entry_line;
    unsigned int entry_col;
    const SaDebugLoc *debug_locs;
    size_t debug_loc_count;
    const SaDebugVar *debug_vars;
    size_t debug_var_count;
    unsigned char emit_main_wrapper;
} SaFunction;
typedef struct {
    unsigned short size_bits;
    unsigned char wasm_compat;
    unsigned char test_mode;
    unsigned char debug;
    unsigned char is_cgu;
    const char *source_file;
    const char *source_dir;
    const SaConst *consts;
    size_t const_count;
    const SaVTable *vtables;
    size_t vtable_count;
    const SaFunction *functions;
    size_t function_count;
} SaModule;

typedef struct { const char *name; LLVMBasicBlockRef block; } LabelEntry;
typedef struct { LLVMValueRef slot; LLVMValueRef value; LLVMValueRef fallible_slot; SaType ty; unsigned char fallible; unsigned char initialized; unsigned int indirect_sig_index; } RegValue;
typedef struct {
    LLVMContextRef ctx;
    LLVMModuleRef module;
    LLVMBuilderRef builder;
    unsigned short size_bits;
    unsigned char is_cgu;
    LLVMTypeRef i8_ty;
    LLVMTypeRef i32_ty;
    LLVMTypeRef i64_ty;
    LLVMTypeRef ptr_ty;
    LLVMValueRef malloc_fn;
    LLVMValueRef free_fn;
    LLVMValueRef write_fn;
    LLVMValueRef exit_fn;
    LLVMValueRef panic_fn;
    LLVMValueRef fopen_fn;
    LLVMValueRef fclose_fn;
    LLVMValueRef fread_fn;
    LLVMValueRef fwrite_fn;
    LLVMValueRef fseek_fn;
    LLVMValueRef ftell_fn;
    LLVMValueRef rewind_fn;
    LLVMValueRef memcpy_fn;
    LLVMValueRef saasm_argc_global;
    LLVMValueRef saasm_argv_global;
    const SaFunction *functions;
    size_t function_count;
    unsigned char debug;
    LLVMDIBuilderRef dib;
    LLVMMetadataRef di_file;
    LLVMMetadataRef di_cu;
    LLVMMetadataRef di_subroutine_type;
    LLVMMetadataRef di_i1_type;
    LLVMMetadataRef di_i8_type;
    LLVMMetadataRef di_i16_type;
    LLVMMetadataRef di_i32_type;
    LLVMMetadataRef di_i64_type;
    LLVMMetadataRef di_f32_type;
    LLVMMetadataRef di_f64_type;
    LLVMMetadataRef di_ptr_type;
    char body_error[256];
} EmitCtx;

static int set_error(char **out_error, const char *message) {
    if (out_error == NULL) return 0;
    size_t len = strlen(message);
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL) return 1;
    memcpy(copy, message, len + 1);
    *out_error = copy;
    return 1;
}

void sa_llvmc_free(void *ptr) { free(ptr); }

static void dispose_emit_ctx(EmitCtx *e) {
    if (e == NULL) return;
    if (e->dib != NULL) LLVMDisposeDIBuilder(e->dib);
    if (e->builder != NULL) LLVMDisposeBuilder(e->builder);
    if (e->module != NULL) LLVMDisposeModule(e->module);
    if (e->ctx != NULL) LLVMContextDispose(e->ctx);
}

static int module_bitcode_to_heap(LLVMModuleRef module, unsigned char **out_bytes, size_t *out_len) {
    LLVMMemoryBufferRef buffer = LLVMWriteBitcodeToMemoryBuffer(module);
    if (buffer == NULL) return 1;
    size_t len = LLVMGetBufferSize(buffer);
    unsigned char *bytes = (unsigned char *)malloc(len);
    if (bytes == NULL) { LLVMDisposeMemoryBuffer(buffer); return 1; }
    memcpy(bytes, LLVMGetBufferStart(buffer), len);
    LLVMDisposeMemoryBuffer(buffer);
    *out_bytes = bytes;
    *out_len = len;
    return 0;
}

static LLVMTypeRef type_of(EmitCtx *e, SaType ty) {
    switch (ty) {
        case SA_T_VOID: return LLVMVoidTypeInContext(e->ctx);
        case SA_T_I1: return LLVMInt1TypeInContext(e->ctx);
        case SA_T_I8: return LLVMInt8TypeInContext(e->ctx);
        case SA_T_U8: return LLVMInt8TypeInContext(e->ctx);
        case SA_T_I16: return LLVMInt16TypeInContext(e->ctx);
        case SA_T_U16: return LLVMInt16TypeInContext(e->ctx);
        case SA_T_I32: return LLVMInt32TypeInContext(e->ctx);
        case SA_T_U32: return LLVMInt32TypeInContext(e->ctx);
        case SA_T_I64: return LLVMInt64TypeInContext(e->ctx);
        case SA_T_U64: return LLVMInt64TypeInContext(e->ctx);
        case SA_T_F32: return LLVMFloatTypeInContext(e->ctx);
        case SA_T_F64: return LLVMDoubleTypeInContext(e->ctx);
        case SA_T_PTR: return LLVMPointerType(LLVMInt8TypeInContext(e->ctx), 0);
    }
    return LLVMInt64TypeInContext(e->ctx);
}

static LLVMTypeRef size_type(EmitCtx *e) {
    return e->size_bits == 32 ? e->i32_ty : e->i64_ty;
}

static LLVMValueRef size_const(EmitCtx *e, unsigned long long value) {
    return LLVMConstInt(size_type(e), value, 0);
}

static LLVMTypeRef vtable_slot_type(EmitCtx *e) {
    if (e->size_bits == 32) {
        LLVMTypeRef fields[2] = { e->ptr_ty, e->i32_ty };
        return LLVMStructTypeInContext(e->ctx, fields, 2, 0);
    }
    return e->ptr_ty;
}

static LLVMValueRef vtable_slot_value(EmitCtx *e, LLVMValueRef fn) {
    LLVMValueRef ptr = LLVMConstPointerCast(fn, e->ptr_ty);
    if (e->size_bits == 32) {
        LLVMValueRef fields[2] = { ptr, LLVMConstInt(e->i32_ty, 0, 0) };
        return LLVMConstNamedStruct(vtable_slot_type(e), fields, 2);
    }
    return ptr;
}

static LLVMValueRef coerce_to_size(EmitCtx *e, LLVMValueRef value, const char *name) {
    LLVMTypeRef from_ty = LLVMTypeOf(value);
    LLVMTypeRef to_ty = size_type(e);
    if (from_ty == to_ty) return value;
    if (LLVMGetTypeKind(from_ty) == LLVMIntegerTypeKind) {
        unsigned from_bits = LLVMGetIntTypeWidth(from_ty);
        unsigned to_bits = LLVMGetIntTypeWidth(to_ty);
        if (from_bits > to_bits) return LLVMBuildTrunc(e->builder, value, to_ty, name);
        if (from_bits < to_bits) return LLVMBuildZExt(e->builder, value, to_ty, name);
    }
    return value;
}

static LLVMValueRef coerce_int_to(EmitCtx *e, LLVMValueRef value, LLVMTypeRef to_ty, const char *name) {
    LLVMTypeRef from_ty = LLVMTypeOf(value);
    if (from_ty == to_ty) return value;
    if (LLVMGetTypeKind(from_ty) == LLVMIntegerTypeKind && LLVMGetTypeKind(to_ty) == LLVMIntegerTypeKind) {
        unsigned from_bits = LLVMGetIntTypeWidth(from_ty);
        unsigned to_bits = LLVMGetIntTypeWidth(to_ty);
        if (from_bits > to_bits) return LLVMBuildTrunc(e->builder, value, to_ty, name);
        if (from_bits < to_bits) return LLVMBuildZExt(e->builder, value, to_ty, name);
    }
    return value;
}

static LLVMTypeRef fallible_type_of(EmitCtx *e, SaType payload_ty) {
    LLVMTypeRef fields[2] = { e->i32_ty, type_of(e, payload_ty) };
    return LLVMStructTypeInContext(e->ctx, fields, 2, 0);
}

static LLVMTypeRef return_type_for(EmitCtx *e, const SaFunction *f) {
    if (f->return_fallible) return fallible_type_of(e, f->ret_ty);
    return type_of(e, f->ret_ty);
}

static LLVMValueRef find_function(EmitCtx *e, const char *name) { return LLVMGetNamedFunction(e->module, name); }
static LLVMValueRef find_global(EmitCtx *e, const char *name) { return LLVMGetNamedGlobal(e->module, name); }

static SaType sa_type_from_llvm(LLVMTypeRef ty) {
    switch (LLVMGetTypeKind(ty)) {
        case LLVMVoidTypeKind: return SA_T_VOID;
        case LLVMPointerTypeKind: return SA_T_PTR;
        case LLVMIntegerTypeKind: {
            unsigned bits = LLVMGetIntTypeWidth(ty);
            if (bits <= 1) return SA_T_I1;
            if (bits <= 8) return SA_T_I8;
            if (bits <= 16) return SA_T_I16;
            if (bits <= 32) return SA_T_I32;
            return SA_T_I64;
        }
        case LLVMFloatTypeKind: return SA_T_F32;
        case LLVMDoubleTypeKind: return SA_T_F64;
        default: return SA_T_PTR;
    }
}

static unsigned type_bits(SaType ty) {
    switch (ty) {
        case SA_T_I1:
            return 1;
        case SA_T_I8:
        case SA_T_U8:
            return 8;
        case SA_T_I16:
        case SA_T_U16:
            return 16;
        case SA_T_I32:
        case SA_T_U32:
        case SA_T_F32:
            return 32;
        case SA_T_I64:
        case SA_T_U64:
        case SA_T_F64:
        case SA_T_PTR:
            return 64;
        case SA_T_VOID:
            return 0;
    }
    return 64;
}

static int type_is_signed_int(SaType ty) {
    switch (ty) {
        case SA_T_I8:
        case SA_T_I16:
        case SA_T_I32:
        case SA_T_I64:
            return 1;
        default:
            return 0;
    }
}

static LLVMTypeRef fn_type_for(EmitCtx *e, const SaFunction *f) {
    LLVMTypeRef *params = NULL;
    if (f->param_count != 0) {
        params = (LLVMTypeRef *)malloc(sizeof(LLVMTypeRef) * f->param_count);
        if (params == NULL) return NULL;
        for (size_t i = 0; i < f->param_count; i++) params[i] = type_of(e, f->params[i].ty);
    }
    LLVMTypeRef ty = LLVMFunctionType(return_type_for(e, f), params, (unsigned)f->param_count, 0);
    free(params);
    return ty;
}

static const SaFunction *function_by_index(EmitCtx *e, unsigned int index) {
    if (index == UINT_MAX || index >= e->function_count) return NULL;
    return &e->functions[index];
}

static int sa_type_can_coerce(SaType from, SaType to) {
    if (from == to) return 1;
    if (from == SA_T_PTR || to == SA_T_PTR) return 1;
    return 1;
}

static unsigned int infer_indirect_sig_index(EmitCtx *e, const SaInstruction *in, const SaType *arg_tys) {
    unsigned int chosen = UINT_MAX;

    for (size_t i = 0; i < e->function_count; i++) {
        const SaFunction *candidate = &e->functions[i];
        if (candidate->kind == SA_F_EXTERNAL) continue;

        size_t param_count = in->indirect_param_count != 0 ? in->indirect_param_count : candidate->param_count;
        if (param_count != in->arg_count) continue;

        int ok = 1;
        for (size_t a = 0; a < in->arg_count; a++) {
            SaType param_ty = in->indirect_param_count != 0 ? in->indirect_param_tys[a] : candidate->params[a].ty;
            if (!sa_type_can_coerce(arg_tys[a], param_ty)) {
                ok = 0;
                break;
            }
        }
        if (!ok) continue;

        if (chosen == UINT_MAX) {
            chosen = (unsigned int)i;
        }
    }

    return chosen;
}

static LLVMTypeRef indirect_fn_type_for(EmitCtx *e, const SaFunction *sig, const SaInstruction *in) {
    size_t param_count = in->indirect_param_count != 0 ? in->indirect_param_count : sig->param_count;
    LLVMTypeRef *params = NULL;
    if (param_count != 0) {
        params = (LLVMTypeRef *)malloc(sizeof(LLVMTypeRef) * param_count);
        if (params == NULL) return NULL;
        for (size_t i = 0; i < param_count; i++) {
            SaType ty = in->indirect_param_count != 0 ? in->indirect_param_tys[i] : sig->params[i].ty;
            params[i] = type_of(e, ty);
        }
    }
    LLVMTypeRef ret_ty = return_type_for(e, sig);
    LLVMTypeRef ty = LLVMFunctionType(ret_ty, params, (unsigned)param_count, 0);
    free(params);
    return ty;
}

static LLVMValueRef coerce(EmitCtx *e, LLVMValueRef v, SaType from, SaType to) {
    if (from == to) return v;
    LLVMTypeRef dst = type_of(e, to);
    if (to == SA_T_PTR) return LLVMBuildIntToPtr(e->builder, v, dst, "cast_ptr");
    if (from == SA_T_PTR) return LLVMBuildPtrToInt(e->builder, v, dst, "cast_int");
    unsigned from_bits = type_bits(from);
    unsigned to_bits = type_bits(to);
    if (from_bits < to_bits) return type_is_signed_int(from) ? LLVMBuildSExt(e->builder, v, dst, "sext") : LLVMBuildZExt(e->builder, v, dst, "zext");
    if (from_bits > to_bits) return LLVMBuildTrunc(e->builder, v, dst, "trunc");
    return v;
}

static LLVMValueRef build_fallible_ok(EmitCtx *e, SaType payload_ty, LLVMValueRef payload, SaType payload_from) {
    LLVMTypeRef result_ty = fallible_type_of(e, payload_ty);
    LLVMValueRef agg = LLVMGetUndef(result_ty);
    agg = LLVMBuildInsertValue(e->builder, agg, LLVMConstInt(e->i32_ty, 0, 0), 0, "fallible_status");
    payload = coerce(e, payload, payload_from, payload_ty);
    return LLVMBuildInsertValue(e->builder, agg, payload, 1, "fallible_ok");
}

static LLVMValueRef default_value_of(EmitCtx *e, SaType ty) {
    return LLVMConstNull(type_of(e, ty));
}

static LLVMValueRef build_fallible_err(EmitCtx *e, SaType payload_ty, LLVMValueRef status) {
    LLVMTypeRef result_ty = fallible_type_of(e, payload_ty);
    LLVMValueRef agg = LLVMGetUndef(result_ty);
    agg = LLVMBuildInsertValue(e->builder, agg, status, 0, "fallible_status");
    return LLVMBuildInsertValue(e->builder, agg, default_value_of(e, payload_ty), 1, "fallible_err");
}

static LLVMValueRef const_c_string(EmitCtx *e, const char *name, const char *text) {
    size_t len = strlen(text) + 1;
    LLVMTypeRef arr_ty = LLVMArrayType(e->i8_ty, (unsigned)len);
    LLVMValueRef glob = LLVMAddGlobal(e->module, arr_ty, name);
    LLVMSetGlobalConstant(glob, 1);
    LLVMSetLinkage(glob, LLVMPrivateLinkage);
    LLVMSetInitializer(glob, LLVMConstStringInContext(e->ctx, text, (unsigned)(len - 1), 0));
    LLVMValueRef zero = LLVMConstInt(e->i32_ty, 0, 0);
    LLVMValueRef idxs[2] = { zero, zero };
    return LLVMConstGEP2(arr_ty, glob, idxs, 2);
}

static LLVMAtomicOrdering atomic_ordering(SaAtomicOrdering ordering) {
    switch (ordering) {
        case SA_ATOMIC_RELAXED: return LLVMAtomicOrderingMonotonic;
        case SA_ATOMIC_ACQUIRE: return LLVMAtomicOrderingAcquire;
        case SA_ATOMIC_RELEASE: return LLVMAtomicOrderingRelease;
        case SA_ATOMIC_ACQ_REL: return LLVMAtomicOrderingAcquireRelease;
        case SA_ATOMIC_SEQ_CST: return LLVMAtomicOrderingSequentiallyConsistent;
    }
    return LLVMAtomicOrderingSequentiallyConsistent;
}

static LLVMAtomicRMWBinOp atomic_rmw_op(SaAtomicRmwOp op) {
    switch (op) {
        case SA_RMW_ADD: return LLVMAtomicRMWBinOpAdd;
        case SA_RMW_SUB: return LLVMAtomicRMWBinOpSub;
        case SA_RMW_AND: return LLVMAtomicRMWBinOpAnd;
        case SA_RMW_OR: return LLVMAtomicRMWBinOpOr;
        case SA_RMW_XOR: return LLVMAtomicRMWBinOpXor;
        case SA_RMW_XCHG: return LLVMAtomicRMWBinOpXchg;
        case SA_RMW_MIN: return LLVMAtomicRMWBinOpMin;
        case SA_RMW_MAX: return LLVMAtomicRMWBinOpMax;
        case SA_RMW_UMIN: return LLVMAtomicRMWBinOpUMin;
        case SA_RMW_UMAX: return LLVMAtomicRMWBinOpUMax;
    }
    return LLVMAtomicRMWBinOpAdd;
}

static unsigned align_of(SaType ty) {
    switch (ty) {
        case SA_T_I1:
        case SA_T_I8:
        case SA_T_U8:
            return 1;
        case SA_T_I16:
        case SA_T_U16:
            return 2;
        case SA_T_I32:
        case SA_T_U32:
        case SA_T_F32:
            return 4;
        case SA_T_I64:
        case SA_T_U64:
        case SA_T_F64:
        case SA_T_PTR:
            return 8;
        case SA_T_VOID:
            return 1;
    }
    return 8;
}

static LLVMValueRef reg_encode(EmitCtx *e, LLVMValueRef value, SaType ty) {
    if (ty == SA_T_PTR) return LLVMBuildPtrToInt(e->builder, value, e->i64_ty, "slot_ptr_to_int");
    if (ty == SA_T_F64) return LLVMBuildBitCast(e->builder, value, e->i64_ty, "slot_f64_bits");
    if (ty == SA_T_F32) {
        LLVMValueRef bits32 = LLVMBuildBitCast(e->builder, value, e->i32_ty, "slot_f32_bits");
        return LLVMBuildZExt(e->builder, bits32, e->i64_ty, "slot_f32_ext");
    }
    return coerce(e, value, ty, SA_T_I64);
}

static LLVMValueRef reg_decode(EmitCtx *e, LLVMValueRef bits, SaType ty) {
    if (ty == SA_T_PTR) return LLVMBuildIntToPtr(e->builder, bits, e->ptr_ty, "slot_int_to_ptr");
    if (ty == SA_T_F64) return LLVMBuildBitCast(e->builder, bits, LLVMDoubleTypeInContext(e->ctx), "slot_f64");
    if (ty == SA_T_F32) {
        LLVMValueRef bits32 = LLVMBuildTrunc(e->builder, bits, e->i32_ty, "slot_f32_trunc");
        return LLVMBuildBitCast(e->builder, bits32, LLVMFloatTypeInContext(e->ctx), "slot_f32");
    }
    return coerce(e, bits, SA_T_I64, ty);
}

static int reg_store(EmitCtx *e, RegValue *regs, size_t reg_count, unsigned int slot, LLVMValueRef value, SaType ty, unsigned char fallible, unsigned int indirect_sig_index) {
    if (slot >= reg_count) return 1;
    regs[slot].ty = ty;
    regs[slot].fallible = fallible;
    regs[slot].initialized = 1;
    regs[slot].indirect_sig_index = indirect_sig_index;
    regs[slot].fallible_slot = NULL;
    if (fallible) {
        regs[slot].value = value;
        return 0;
    }
    if (regs[slot].slot == NULL) return 1;
    LLVMValueRef bits = reg_encode(e, value, ty);
    LLVMBuildStore(e->builder, bits, regs[slot].slot);
    return 0;
}

static int fallible_value_ptr(EmitCtx *e, RegValue *reg, LLVMValueRef *out, SaType *out_ty) {
    if (reg == NULL || !reg->fallible || reg->value == NULL) return 1;
    if (reg->fallible_slot == NULL) {
        LLVMTypeRef result_ty = fallible_type_of(e, reg->ty);
        reg->fallible_slot = LLVMBuildAlloca(e->builder, result_ty, "fallible_slot");
    }
    LLVMBuildStore(e->builder, reg->value, reg->fallible_slot);
    *out = LLVMBuildPointerCast(e->builder, reg->fallible_slot, e->ptr_ty, "fallible_ptr");
    *out_ty = SA_T_PTR;
    return 0;
}

static int operand_value(EmitCtx *e, const SaOperand *op, RegValue *regs, size_t reg_count, LLVMValueRef *out, SaType *out_ty) {
    switch (op->kind) {
        case SA_OPER_REG:
            if (op->reg >= reg_count || !regs[op->reg].initialized) return 1;
            *out_ty = regs[op->reg].ty;
            if (regs[op->reg].fallible) {
                if (regs[op->reg].value == NULL) return 1;
                *out = regs[op->reg].value;
            } else {
                if (regs[op->reg].slot == NULL) return 1;
                LLVMValueRef bits = LLVMBuildLoad2(e->builder, e->i64_ty, regs[op->reg].slot, "slot_load");
                *out = reg_decode(e, bits, *out_ty);
            }
            return 0;
        case SA_OPER_IMM_I64:
            *out = LLVMConstInt(e->i64_ty, (unsigned long long)op->i64_value, 1);
            *out_ty = SA_T_I64;
            return 0;
        case SA_OPER_IMM_U64:
            *out = LLVMConstInt(e->i64_ty, op->u64_value, 0);
            *out_ty = SA_T_I64;
            return 0;
        case SA_OPER_CONST_PTR:
            *out = find_global(e, op->name);
            if (*out == NULL) return 1;
            *out = LLVMBuildPointerCast(e->builder, *out, e->ptr_ty, "const_ptr");
            *out_ty = SA_T_PTR;
            return 0;
        default:
            return 1;
    }
}

static int operand_addressable_value(EmitCtx *e, const SaOperand *op, RegValue *regs, size_t reg_count, LLVMValueRef *out, SaType *out_ty) {
    if (op->kind == SA_OPER_REG) {
        if (op->reg >= reg_count || !regs[op->reg].initialized) return 1;
        if (regs[op->reg].fallible) return fallible_value_ptr(e, &regs[op->reg], out, out_ty);
    }
    return operand_value(e, op, regs, reg_count, out, out_ty);
}

static LLVMBasicBlockRef label_block(LabelEntry *labels, size_t label_count, const char *name) {
    for (size_t i = 0; i < label_count; i++) if (strcmp(labels[i].name, name) == 0) return labels[i].block;
    return NULL;
}

static int current_has_terminator(EmitCtx *e) {
    LLVMBasicBlockRef bb = LLVMGetInsertBlock(e->builder);
    return bb != NULL && LLVMGetBasicBlockTerminator(bb) != NULL;
}

static int fail_body(EmitCtx *e, const SaFunction *f, const SaInstruction *in, size_t index, const char *message) {
    const char *fn_name = f != NULL && f->name != NULL ? f->name : "<unknown>";
    SaOp op = in != NULL ? in->op : SA_OP_NONE;
    snprintf(e->body_error, sizeof(e->body_error), "emit body failed in %s instruction %zu op %d: %s", fn_name, index, (int)op, message);
    return 1;
}

static int fail_body_callee(EmitCtx *e, const SaFunction *f, const SaInstruction *in, size_t index, const char *message) {
    const char *fn_name = f != NULL && f->name != NULL ? f->name : "<unknown>";
    const char *callee = in != NULL && in->callee != NULL ? in->callee : "<null>";
    SaOp op = in != NULL ? in->op : SA_OP_NONE;
    snprintf(e->body_error, sizeof(e->body_error), "emit body failed in %s instruction %zu op %d: %s: %s", fn_name, index, (int)op, message, callee);
    return 1;
}

static LLVMValueRef build_binop(EmitCtx *e, SaBinaryOp op, LLVMValueRef lhs, LLVMValueRef rhs) {
    switch (op) {
        case SA_BIN_ADD: return LLVMBuildAdd(e->builder, lhs, rhs, "op");
        case SA_BIN_SUB: return LLVMBuildSub(e->builder, lhs, rhs, "op");
        case SA_BIN_MUL: return LLVMBuildMul(e->builder, lhs, rhs, "op");
        case SA_BIN_SDIV: return LLVMBuildSDiv(e->builder, lhs, rhs, "op");
        case SA_BIN_UDIV: return LLVMBuildUDiv(e->builder, lhs, rhs, "op");
        case SA_BIN_SREM: return LLVMBuildSRem(e->builder, lhs, rhs, "op");
        case SA_BIN_UREM: return LLVMBuildURem(e->builder, lhs, rhs, "op");
        case SA_BIN_AND: return LLVMBuildAnd(e->builder, lhs, rhs, "op");
        case SA_BIN_OR: return LLVMBuildOr(e->builder, lhs, rhs, "op");
        case SA_BIN_XOR: return LLVMBuildXor(e->builder, lhs, rhs, "op");
        case SA_BIN_SHL: return LLVMBuildShl(e->builder, lhs, rhs, "op");
        case SA_BIN_LSHR: return LLVMBuildLShr(e->builder, lhs, rhs, "op");
        case SA_BIN_ASHR: return LLVMBuildAShr(e->builder, lhs, rhs, "op");
        case SA_BIN_EQ: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntEQ, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_NE: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntNE, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_SLT: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntSLT, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_SLE: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntSLE, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_SGT: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntSGT, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_SGE: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntSGE, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_ULT: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntULT, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_ULE: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntULE, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_UGT: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGT, lhs, rhs, "cmp"), e->i64_ty, "bool64");
        case SA_BIN_UGE: return LLVMBuildZExt(e->builder, LLVMBuildICmp(e->builder, LLVMIntUGE, lhs, rhs, "cmp"), e->i64_ty, "bool64");
    }
    return NULL;
}

static void debug_init(EmitCtx *e, const SaModule *m) {
    if (m == NULL || !m->debug) return;
    const char *source_file = m->source_file != NULL ? m->source_file : "unknown.sa";
    const char *source_dir = m->source_dir != NULL ? m->source_dir : ".";
    e->debug = 1;
    e->dib = LLVMCreateDIBuilder(e->module);
    e->di_file = LLVMDIBuilderCreateFile(e->dib, source_file, strlen(source_file), source_dir, strlen(source_dir));
    e->di_cu = LLVMDIBuilderCreateCompileUnit(
        e->dib,
        LLVMDWARFSourceLanguageC99,
        e->di_file,
        "sa",
        2,
        1,
        "",
        0,
        0,
        "",
        0,
        LLVMDWARFEmissionFull,
        0,
        0,
        0,
        "",
        0,
        "",
        0
    );
    e->di_subroutine_type = LLVMDIBuilderCreateSubroutineType(e->dib, e->di_file, NULL, 0, LLVMDIFlagZero);
    e->di_i1_type = LLVMDIBuilderCreateBasicType(e->dib, "bool", strlen("bool"), 1, 0x02, LLVMDIFlagZero);
    e->di_i8_type = LLVMDIBuilderCreateBasicType(e->dib, "u8", strlen("u8"), 8, 0x08, LLVMDIFlagZero);
    e->di_i16_type = LLVMDIBuilderCreateBasicType(e->dib, "i16", strlen("i16"), 16, 0x05, LLVMDIFlagZero);
    e->di_i32_type = LLVMDIBuilderCreateBasicType(e->dib, "i32", strlen("i32"), 32, 0x05, LLVMDIFlagZero);
    e->di_i64_type = LLVMDIBuilderCreateBasicType(e->dib, "i64", strlen("i64"), 64, 0x05, LLVMDIFlagZero);
    e->di_f32_type = LLVMDIBuilderCreateBasicType(e->dib, "f32", strlen("f32"), 32, 0x04, LLVMDIFlagZero);
    e->di_f64_type = LLVMDIBuilderCreateBasicType(e->dib, "f64", strlen("f64"), 64, 0x04, LLVMDIFlagZero);
    e->di_ptr_type = LLVMDIBuilderCreatePointerType(e->dib, e->di_i8_type, e->size_bits, 0, 0, "ptr", strlen("ptr"));
    LLVMAddModuleFlag(e->module, LLVMModuleFlagBehaviorWarning, "Dwarf Version", strlen("Dwarf Version"), LLVMValueAsMetadata(LLVMConstInt(e->i32_ty, 4, 0)));
    LLVMAddModuleFlag(e->module, LLVMModuleFlagBehaviorWarning, "Debug Info Version", strlen("Debug Info Version"), LLVMValueAsMetadata(LLVMConstInt(e->i32_ty, LLVMDebugMetadataVersion(), 0)));
}

static LLVMMetadataRef debug_type_for(EmitCtx *e, SaType ty) {
    switch (ty) {
        case SA_T_I1: return e->di_i1_type;
        case SA_T_I8: return e->di_i8_type;
        case SA_T_U8: return e->di_i8_type;
        case SA_T_I16: return e->di_i16_type;
        case SA_T_U16: return e->di_i16_type;
        case SA_T_I32: return e->di_i32_type;
        case SA_T_U32: return e->di_i32_type;
        case SA_T_I64: return e->di_i64_type;
        case SA_T_U64: return e->di_i64_type;
        case SA_T_F32: return e->di_f32_type;
        case SA_T_F64: return e->di_f64_type;
        case SA_T_PTR: return e->di_ptr_type;
        case SA_T_VOID: return e->di_i64_type;
    }
    return e->di_i64_type;
}

static LLVMMetadataRef debug_subprogram(EmitCtx *e, LLVMValueRef fn, const SaFunction *f) {
    if (!e->debug || e->dib == NULL || f == NULL) return NULL;
    const char *name = f->name != NULL ? f->name : "<unknown>";
    const char *linkage = f->name != NULL ? f->name : "";
    const char *source_file = f->source_file != NULL ? f->source_file : NULL;
    const char *source_dir = f->source_dir != NULL ? f->source_dir : NULL;
    LLVMMetadataRef file = e->di_file;
    if (source_file != NULL || source_dir != NULL) {
        const char *file_name = source_file != NULL ? source_file : "unknown.sa";
        const char *dir_name = source_dir != NULL ? source_dir : ".";
        file = LLVMDIBuilderCreateFile(e->dib, file_name, strlen(file_name), dir_name, strlen(dir_name));
    }
    unsigned line = f->entry_line == 0 ? 1 : f->entry_line;
    LLVMMetadataRef sp = LLVMDIBuilderCreateFunction(
        e->dib,
        file,
        name,
        strlen(name),
        linkage,
        strlen(linkage),
        file,
        line,
        e->di_subroutine_type,
        f->kind != SA_F_EXPORTED,
        1,
        line,
        LLVMDIFlagZero,
        1
    );
    LLVMSetSubprogram(fn, sp);
    return sp;
}

static void debug_set_location(EmitCtx *e, LLVMMetadataRef scope, const SaFunction *f, size_t inst_index) {
    if (!e->debug || e->dib == NULL || scope == NULL || f == NULL) return;
    if (inst_index >= f->debug_loc_count || f->debug_locs == NULL) {
        LLVMSetCurrentDebugLocation2(e->builder, NULL);
        return;
    }
    unsigned line = f->debug_locs[inst_index].line;
    if (line == 0) {
        LLVMSetCurrentDebugLocation2(e->builder, NULL);
        return;
    }
    unsigned col = f->debug_locs[inst_index].col;
    LLVMMetadataRef loc = LLVMDIBuilderCreateDebugLocation(e->ctx, line, col, scope, NULL);
    LLVMSetCurrentDebugLocation2(e->builder, loc);
}

static void debug_declare_locals(EmitCtx *e, LLVMMetadataRef scope, const SaFunction *f, RegValue *regs, size_t reg_count, LLVMBasicBlockRef block) {
    if (!e->debug || e->dib == NULL || scope == NULL || f == NULL || f->debug_vars == NULL) return;
    LLVMMetadataRef expr = LLVMDIBuilderCreateExpression(e->dib, NULL, 0);
    unsigned line = f->entry_line == 0 ? 1 : f->entry_line;
    unsigned col = f->entry_col == 0 ? 1 : f->entry_col;
    LLVMMetadataRef loc = LLVMDIBuilderCreateDebugLocation(e->ctx, line, col, scope, NULL);
    for (size_t i = 0; i < f->debug_var_count; i++) {
        const SaDebugVar *var = &f->debug_vars[i];
        if (var->slot >= reg_count || regs[var->slot].slot == NULL || var->name == NULL) continue;
        LLVMMetadataRef ty = debug_type_for(e, var->ty);
        LLVMMetadataRef info;
        unsigned var_line = var->line == 0 ? line : var->line;
        if (var->is_param) {
            info = LLVMDIBuilderCreateParameterVariable(e->dib, scope, var->name, strlen(var->name), var->slot + 1, e->di_file, var_line, ty, 1, LLVMDIFlagZero);
        } else {
            info = LLVMDIBuilderCreateAutoVariable(e->dib, scope, var->name, strlen(var->name), e->di_file, var_line, ty, 1, LLVMDIFlagZero, 64);
        }
        LLVMDIBuilderInsertDeclareAtEnd(e->dib, regs[var->slot].slot, info, expr, loc, block);
    }
}

static void note_operand_reg(const SaOperand *op, size_t *max_reg) {
    if (op != NULL && op->kind == SA_OPER_REG && (size_t)op->reg > *max_reg) *max_reg = op->reg;
}

static size_t function_reg_count(const SaFunction *f) {
    size_t max_reg = 0;
    for (size_t i = 0; i < f->param_count; i++) {
        if ((size_t)f->params[i].slot > max_reg) max_reg = f->params[i].slot;
    }
    for (size_t i = 0; i < f->instruction_count; i++) {
        const SaInstruction *in = &f->instructions[i];
        if (in->has_dst && (size_t)in->dst > max_reg) max_reg = in->dst;
        note_operand_reg(&in->operand0, &max_reg);
        note_operand_reg(&in->operand1, &max_reg);
        note_operand_reg(&in->operand2, &max_reg);
        for (size_t a = 0; a < in->arg_count; a++) note_operand_reg(&in->args[a], &max_reg);
    }
    return max_reg + 1;
}

static int emit_function_body(EmitCtx *e, const SaFunction *f) {
    LLVMValueRef fn = find_function(e, f->name);
    if (fn == NULL) return fail_body(e, f, NULL, 0, "function not found");
    LLVMMetadataRef debug_scope = debug_subprogram(e, fn, f);
    size_t reg_count = function_reg_count(f);
    if (reg_count < 1) reg_count = 1;
    RegValue *regs = (RegValue *)calloc(reg_count, sizeof(RegValue));
    LabelEntry *labels = (LabelEntry *)calloc(f->instruction_count + 1, sizeof(LabelEntry));
    if (regs == NULL || labels == NULL) { free(regs); free(labels); return fail_body(e, f, NULL, 0, "alloc frame failed"); }
    size_t label_count = 0;
    for (size_t i = 0; i < reg_count; i++) regs[i].indirect_sig_index = UINT_MAX;

    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    for (size_t i = 0; i < reg_count; i++) {
        regs[i].slot = LLVMBuildAlloca(e->builder, e->i64_ty, "sa_slot");
        LLVMBuildStore(e->builder, LLVMConstInt(e->i64_ty, 0, 0), regs[i].slot);
    }
    debug_declare_locals(e, debug_scope, f, regs, reg_count, entry);
    for (size_t i = 0; i < f->param_count; i++) {
        if (f->params[i].slot < reg_count) {
            reg_store(e, regs, reg_count, f->params[i].slot, LLVMGetParam(fn, (unsigned)i), f->params[i].ty, 0, UINT_MAX);
        }
    }
    for (size_t i = 0; i < f->instruction_count; i++) {
        if (f->instructions[i].op == SA_OP_LABEL && f->instructions[i].label != NULL) {
            labels[label_count].name = f->instructions[i].label;
            labels[label_count].block = LLVMAppendBasicBlockInContext(e->ctx, fn, f->instructions[i].label);
            label_count++;
        }
    }

    for (size_t i = 0; i < f->instruction_count; i++) {
        const SaInstruction *in = &f->instructions[i];
        LLVMValueRef v0, v1, v2;
        SaType t0, t1, t2;
        snprintf(e->body_error, sizeof(e->body_error), "emit body failed in %s instruction %zu op %d", f->name, i, (int)in->op);
        debug_set_location(e, debug_scope, f, i);
        switch (in->op) {
            case SA_OP_LABEL: {
                LLVMBasicBlockRef bb = label_block(labels, label_count, in->label);
                if (bb == NULL) { free(regs); free(labels); return 1; }
                if (!current_has_terminator(e)) LLVMBuildBr(e->builder, bb);
                LLVMPositionBuilderAtEnd(e->builder, bb);
                break;
            }
            case SA_OP_ALLOC:
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_I64);
                v0 = coerce_to_size(e, v0, "alloc_size");
                if (reg_store(e, regs, reg_count, in->dst, LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->malloc_fn), e->malloc_fn, &v0, 1, "malloced"), SA_T_PTR, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            case SA_OP_STACK_ALLOC:
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_I64);
                v0 = coerce_to_size(e, v0, "stack_size");
                if (reg_store(e, regs, reg_count, in->dst, LLVMBuildArrayAlloca(e->builder, e->i8_ty, v0, "stack_alloc"), SA_T_PTR, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            case SA_OP_LOAD:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64);
                LLVMValueRef gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "gep");
                LLVMTypeRef load_ty = type_of(e, in->ty);
                LLVMValueRef load_ptr = LLVMBuildPointerCast(e->builder, gep, LLVMPointerType(load_ty, 0), "load_ptr");
                if (reg_store(e, regs, reg_count, in->dst, LLVMBuildLoad2(e->builder, load_ty, load_ptr, "load"), in->ty, 0, in->indirect_sig_index)) { free(regs); free(labels); return 1; }
                break;
            case SA_OP_STORE:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1) || operand_value(e, &in->operand2, regs, reg_count, &v2, &t2)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64); v2 = coerce(e, v2, t2, in->ty);
                LLVMValueRef store_gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "gep");
                LLVMTypeRef store_ty = type_of(e, in->ty);
                LLVMValueRef store_ptr = LLVMBuildPointerCast(e->builder, store_gep, LLVMPointerType(store_ty, 0), "store_ptr");
                LLVMBuildStore(e->builder, v2, store_ptr);
                break;
            case SA_OP_ATOMIC_LOAD:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64);
                LLVMValueRef atomic_load_gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "atomic_gep");
                LLVMTypeRef atomic_load_ty = type_of(e, in->ty);
                LLVMValueRef atomic_load_ptr = LLVMBuildPointerCast(e->builder, atomic_load_gep, LLVMPointerType(atomic_load_ty, 0), "atomic_load_ptr");
                LLVMValueRef atomic_loaded = LLVMBuildLoad2(e->builder, atomic_load_ty, atomic_load_ptr, "atomic_load");
                LLVMSetOrdering(atomic_loaded, atomic_ordering(in->atomic_ordering));
                LLVMSetAlignment(atomic_loaded, align_of(in->ty));
                if (reg_store(e, regs, reg_count, in->dst, atomic_loaded, in->ty, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            case SA_OP_ATOMIC_STORE:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1) || operand_value(e, &in->operand2, regs, reg_count, &v2, &t2)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64); v2 = coerce(e, v2, t2, in->ty);
                LLVMValueRef atomic_store_gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "atomic_gep");
                LLVMTypeRef atomic_store_ty = type_of(e, in->ty);
                LLVMValueRef atomic_store_ptr = LLVMBuildPointerCast(e->builder, atomic_store_gep, LLVMPointerType(atomic_store_ty, 0), "atomic_store_ptr");
                LLVMValueRef atomic_store_inst = LLVMBuildStore(e->builder, v2, atomic_store_ptr);
                LLVMSetOrdering(atomic_store_inst, atomic_ordering(in->atomic_ordering));
                LLVMSetAlignment(atomic_store_inst, align_of(in->ty));
                break;
            case SA_OP_ATOMIC_RMW:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1) || operand_value(e, &in->operand2, regs, reg_count, &v2, &t2)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64); v2 = coerce(e, v2, t2, in->ty);
                LLVMValueRef atomic_rmw_gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "atomic_gep");
                LLVMTypeRef atomic_rmw_ty = type_of(e, in->ty);
                LLVMValueRef atomic_rmw_ptr = LLVMBuildPointerCast(e->builder, atomic_rmw_gep, LLVMPointerType(atomic_rmw_ty, 0), "atomic_rmw_ptr");
                LLVMValueRef atomic_rmw = LLVMBuildAtomicRMW(e->builder, atomic_rmw_op(in->atomic_rmw_op), atomic_rmw_ptr, v2, atomic_ordering(in->atomic_ordering), 0);
                LLVMSetAlignment(atomic_rmw, align_of(in->ty));
                if (reg_store(e, regs, reg_count, in->dst, atomic_rmw, in->ty, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            case SA_OP_CMPXCHG: {
                if (in->arg_count < 2) { free(regs); free(labels); return 1; }
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1) || operand_value(e, &in->operand2, regs, reg_count, &v2, &t2)) { free(regs); free(labels); return 1; }
                LLVMValueRef new_value;
                SaType new_ty;
                if (operand_value(e, &in->args[0], regs, reg_count, &new_value, &new_ty)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR);
                v1 = coerce(e, v1, t1, SA_T_I64);
                v2 = coerce(e, v2, t2, in->ty);
                new_value = coerce(e, new_value, new_ty, in->ty);
                LLVMValueRef cmpxchg_gep = LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "cmpxchg_gep");
                LLVMTypeRef cmpxchg_ty = type_of(e, in->ty);
                LLVMValueRef cmpxchg_ptr = LLVMBuildPointerCast(e->builder, cmpxchg_gep, LLVMPointerType(cmpxchg_ty, 0), "cmpxchg_ptr");
                LLVMValueRef pair = LLVMBuildAtomicCmpXchg(e->builder, cmpxchg_ptr, v2, new_value, atomic_ordering(in->atomic_ordering), atomic_ordering(in->atomic_second_ordering), 0);
                LLVMSetAlignment(pair, align_of(in->ty));
                if (reg_store(e, regs, reg_count, in->dst, LLVMBuildExtractValue(e->builder, pair, 0, "cmpxchg_old"), in->ty, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                unsigned int ok_slot = in->args[1].reg;
                if (ok_slot >= reg_count) { free(regs); free(labels); return 1; }
                if (reg_store(e, regs, reg_count, ok_slot, LLVMBuildExtractValue(e->builder, pair, 1, "cmpxchg_ok"), SA_T_I1, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            }
            case SA_OP_FENCE:
                LLVMBuildFence(e->builder, atomic_ordering(in->atomic_ordering), 0, "");
                break;
            case SA_OP_BINOP:
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_I64); v1 = coerce(e, v1, t1, SA_T_I64);
                if (reg_store(e, regs, reg_count, in->dst, build_binop(e, in->binary_op, v0, v1), SA_T_I64, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            case SA_OP_PTR_ADD:
                if (operand_addressable_value(e, &in->operand0, regs, reg_count, &v0, &t0) || operand_value(e, &in->operand1, regs, reg_count, &v1, &t1)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_PTR); v1 = coerce(e, v1, t1, SA_T_I64);
                if (reg_store(e, regs, reg_count, in->dst, LLVMBuildGEP2(e->builder, e->i8_ty, v0, &v1, 1, "ptradd"), SA_T_PTR, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            case SA_OP_ASSIGN: {
                if (in->dst >= reg_count) { free(regs); free(labels); return fail_body(e, f, in, i, "assign destination out of range"); }
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return fail_body(e, f, in, i, "assign operand unavailable"); }
                SaType dst_ty = in->ty == SA_T_VOID ? t0 : in->ty;
                unsigned char dst_fallible = 0;
                unsigned int dst_indirect = in->indirect_sig_index;
                if (in->operand0.kind == SA_OPER_REG && in->operand0.reg < reg_count) {
                    dst_fallible = regs[in->operand0.reg].fallible;
                    dst_indirect = regs[in->operand0.reg].indirect_sig_index;
                }
                if (dst_fallible) {
                    if (reg_store(e, regs, reg_count, in->dst, v0, t0, dst_fallible, dst_indirect)) { free(regs); free(labels); return 1; }
                } else {
                    if (reg_store(e, regs, reg_count, in->dst, coerce(e, v0, t0, dst_ty), dst_ty, dst_fallible, dst_indirect)) { free(regs); free(labels); return 1; }
                }
                break;
            }
            case SA_OP_JMP: {
                LLVMBasicBlockRef bb = label_block(labels, label_count, in->label);
                if (bb == NULL) { free(regs); free(labels); return 1; }
                LLVMBuildBr(e->builder, bb);
                break;
            }
            case SA_OP_BR: {
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                v0 = coerce(e, v0, t0, SA_T_I64);
                LLVMValueRef cond = LLVMBuildICmp(e->builder, LLVMIntNE, v0, LLVMConstInt(e->i64_ty, 0, 0), "cond");
                LLVMBasicBlockRef tb = label_block(labels, label_count, in->label);
                LLVMBasicBlockRef fb = label_block(labels, label_count, in->false_label);
                if (tb == NULL || fb == NULL) { free(regs); free(labels); return 1; }
                LLVMBuildCondBr(e->builder, cond, tb, fb);
                break;
            }
            case SA_OP_CALL: {
                LLVMValueRef callee = find_function(e, in->callee);
                if (callee == NULL) { free(regs); free(labels); return fail_body_callee(e, f, in, i, "callee not found"); }
                LLVMValueRef *args = NULL;
                if (in->arg_count != 0) args = (LLVMValueRef *)malloc(sizeof(LLVMValueRef) * in->arg_count);
                if (in->arg_count != 0 && args == NULL) { free(regs); free(labels); return fail_body(e, f, in, i, "alloc call args failed"); }
                LLVMTypeRef fn_ty = LLVMGlobalGetValueType(callee);
                unsigned param_count = LLVMCountParamTypes(fn_ty);
                LLVMTypeRef *param_types = NULL;
                if (param_count != 0) param_types = (LLVMTypeRef *)malloc(sizeof(LLVMTypeRef) * param_count);
                if (param_count != 0 && param_types == NULL) { free(args); free(regs); free(labels); return fail_body(e, f, in, i, "alloc param types failed"); }
                if (param_count != 0) LLVMGetParamTypes(fn_ty, param_types);
                for (size_t a = 0; a < in->arg_count; a++) {
                    SaType aty;
                    if (operand_value(e, &in->args[a], regs, reg_count, &args[a], &aty)) { free(param_types); free(args); free(regs); free(labels); return fail_body(e, f, in, i, "call argument unavailable"); }
                    if (a < param_count) args[a] = coerce(e, args[a], aty, sa_type_from_llvm(param_types[a]));
                }
                free(param_types);
                LLVMValueRef callv = LLVMBuildCall2(e->builder, fn_ty, callee, args, (unsigned)in->arg_count, in->has_dst ? "call" : "");
                if (in->has_dst) {
                    if (reg_store(e, regs, reg_count, in->dst, callv, in->ty, in->return_fallible, UINT_MAX)) { free(args); free(regs); free(labels); return 1; }
                }
                free(args);
                break;
            }
            case SA_OP_CALL_INDIRECT: {
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return fail_body(e, f, in, i, "indirect callee operand unavailable"); }
                unsigned int sig_index = UINT_MAX;
                if (in->operand0.kind == SA_OPER_REG && in->operand0.reg < reg_count) {
                    sig_index = regs[in->operand0.reg].indirect_sig_index;
                }
                const SaFunction *target_sig = function_by_index(e, sig_index);
                LLVMValueRef *args = NULL;
                SaType *arg_tys = NULL;
                if (in->arg_count != 0) {
                    args = (LLVMValueRef *)malloc(sizeof(LLVMValueRef) * in->arg_count);
                    arg_tys = (SaType *)malloc(sizeof(SaType) * in->arg_count);
                }
                if (in->arg_count != 0 && (args == NULL || arg_tys == NULL)) {
                    free(args);
                    free(arg_tys);
                    free(regs);
                    free(labels);
                    return fail_body(e, f, in, i, "alloc indirect args failed");
                }
                for (size_t a = 0; a < in->arg_count; a++) {
                    SaType aty;
                    if (operand_value(e, &in->args[a], regs, reg_count, &args[a], &aty)) { free(arg_tys); free(args); free(regs); free(labels); return fail_body(e, f, in, i, "indirect argument unavailable"); }
                    arg_tys[a] = aty;
                }

                if (target_sig == NULL) {
                    sig_index = infer_indirect_sig_index(e, in, arg_tys);
                    target_sig = function_by_index(e, sig_index);
                }
                if (target_sig == NULL) { free(arg_tys); free(args); free(regs); free(labels); return fail_body(e, f, in, i, "indirect callee missing signature provenance"); }

                LLVMTypeRef fn_ty = indirect_fn_type_for(e, target_sig, in);
                if (fn_ty == NULL) { free(regs); free(labels); return fail_body(e, f, in, i, "indirect function type failed"); }
                for (size_t a = 0; a < in->arg_count; a++) {
                    SaType param_ty = a < target_sig->param_count ? target_sig->params[a].ty : arg_tys[a];
                    if (a < in->indirect_param_count) param_ty = in->indirect_param_tys[a];
                    args[a] = coerce(e, args[a], arg_tys[a], param_ty);
                }
                free(arg_tys);
                LLVMValueRef callee = coerce(e, v0, t0, SA_T_PTR);
                callee = LLVMBuildPointerCast(e->builder, callee, LLVMPointerType(fn_ty, 0), "indirect_fn");
                LLVMValueRef callv = LLVMBuildCall2(e->builder, fn_ty, callee, args, (unsigned)in->arg_count, in->has_dst ? "call_indirect" : "");
                if (in->has_dst) {
                    if (reg_store(e, regs, reg_count, in->dst, callv, target_sig->ret_ty, target_sig->return_fallible, UINT_MAX)) { free(args); free(regs); free(labels); return 1; }
                }
                free(args);
                break;
            }
            case SA_OP_TRY: {
                if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                if (in->operand0.kind != SA_OPER_REG || !regs[in->operand0.reg].fallible) { free(regs); free(labels); return 1; }
                LLVMValueRef status = LLVMBuildExtractValue(e->builder, v0, 0, "try_status");
                LLVMValueRef ok = LLVMBuildICmp(e->builder, LLVMIntEQ, status, LLVMConstInt(e->i32_ty, 0, 0), "try_ok");
                LLVMBasicBlockRef current = LLVMGetInsertBlock(e->builder);
                LLVMValueRef current_fn = LLVMGetBasicBlockParent(current);
                LLVMBasicBlockRef ok_bb = LLVMAppendBasicBlockInContext(e->ctx, current_fn, "try_ok");
                LLVMBasicBlockRef early_bb = LLVMAppendBasicBlockInContext(e->ctx, current_fn, "try_early");
                LLVMBuildCondBr(e->builder, ok, ok_bb, early_bb);
                LLVMPositionBuilderAtEnd(e->builder, early_bb);
                if (f->return_fallible) {
                    LLVMBuildRet(e->builder, build_fallible_err(e, f->ret_ty, status));
                } else if (f->ret_ty == SA_T_VOID) {
                    LLVMBuildRetVoid(e->builder);
                } else {
                    LLVMBuildRet(e->builder, default_value_of(e, f->ret_ty));
                }
                LLVMPositionBuilderAtEnd(e->builder, ok_bb);
                if (reg_store(e, regs, reg_count, in->dst, LLVMBuildExtractValue(e->builder, v0, 1, "try_payload"), t0, 0, UINT_MAX)) { free(regs); free(labels); return 1; }
                break;
            }
            case SA_OP_RET:
                if (f->return_fallible) {
                    if (!in->has_dst || f->ret_ty == SA_T_VOID) { free(regs); free(labels); return 1; }
                    if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                    if (in->operand0.kind == SA_OPER_REG && regs[in->operand0.reg].fallible) {
                        LLVMBuildRet(e->builder, v0);
                    } else {
                        LLVMBuildRet(e->builder, build_fallible_ok(e, f->ret_ty, v0, t0));
                    }
                } else if (!in->has_dst || f->ret_ty == SA_T_VOID) {
                    LLVMBuildRetVoid(e->builder);
                } else {
                    if (operand_value(e, &in->operand0, regs, reg_count, &v0, &t0)) { free(regs); free(labels); return 1; }
                    v0 = coerce(e, v0, t0, f->ret_ty);
                    LLVMBuildRet(e->builder, v0);
                }
                break;
            case SA_OP_PANIC: {
                if (in->operand0.kind == SA_OPER_NONE) { free(regs); free(labels); return 1; }
                LLVMValueRef code = NULL;
                SaType code_ty;
                if (operand_value(e, &in->operand0, regs, reg_count, &code, &code_ty)) { free(regs); free(labels); return 1; }
                code = coerce(e, code, code_ty, SA_T_I32);
                LLVMValueRef panic_msg_fn = LLVMGetNamedFunction(e->module, "panic_msg");
                if (panic_msg_fn == NULL) { free(regs); free(labels); return 1; }
                LLVMValueRef args[3] = {
                    code,
                    LLVMConstNull(e->ptr_ty),
                    LLVMConstInt(e->i64_ty, 0, 0)
                };
                LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(panic_msg_fn), panic_msg_fn, args, 3, "");
                LLVMBuildUnreachable(e->builder);
                break;
            }
            case SA_OP_PANIC_MSG: {
                if (in->operand0.kind == SA_OPER_NONE || in->operand1.kind == SA_OPER_NONE || in->operand2.kind == SA_OPER_NONE) { free(regs); free(labels); return 1; }
                LLVMValueRef code = NULL, msg_ptr = NULL, msg_len = NULL;
                SaType code_ty, msg_ptr_ty, msg_len_ty;
                if (operand_value(e, &in->operand0, regs, reg_count, &code, &code_ty) || operand_value(e, &in->operand1, regs, reg_count, &msg_ptr, &msg_ptr_ty) || operand_value(e, &in->operand2, regs, reg_count, &msg_len, &msg_len_ty)) { free(regs); free(labels); return 1; }
                code = coerce(e, code, code_ty, SA_T_I32);
                msg_ptr = coerce(e, msg_ptr, msg_ptr_ty, SA_T_PTR);
                msg_len = coerce(e, msg_len, msg_len_ty, SA_T_I64);
                LLVMValueRef panic_msg_fn = LLVMGetNamedFunction(e->module, "panic_msg");
                if (panic_msg_fn == NULL) { free(regs); free(labels); return 1; }
                LLVMValueRef args[3] = { code, msg_ptr, msg_len };
                LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(panic_msg_fn), panic_msg_fn, args, 3, "");
                break;
            }
            default:
                free(regs); free(labels); return 1;
        }
    }
    LLVMSetCurrentDebugLocation2(e->builder, NULL);
    if (!current_has_terminator(e)) {
        if (f->return_fallible) {
            LLVMValueRef zero = LLVMConstInt(type_of(e, f->ret_ty), 0, 0);
            LLVMBuildRet(e->builder, build_fallible_ok(e, f->ret_ty, zero, f->ret_ty));
        } else if (f->ret_ty == SA_T_VOID) LLVMBuildRetVoid(e->builder);
        else LLVMBuildRet(e->builder, LLVMConstInt(type_of(e, f->ret_ty), 0, 0));
    }
    free(regs);
    free(labels);
    return 0;
}

static int declare_runtime(EmitCtx *e) {
    LLVMTypeRef sz_ty = size_type(e);
    LLVMTypeRef malloc_params[1] = { sz_ty };
    e->malloc_fn = LLVMAddFunction(e->module, "malloc", LLVMFunctionType(e->ptr_ty, malloc_params, 1, 0));
    LLVMTypeRef free_params[1] = { e->ptr_ty };
    e->free_fn = LLVMAddFunction(e->module, "free", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), free_params, 1, 0));
    LLVMTypeRef write_params[3] = { e->i32_ty, e->ptr_ty, sz_ty };
    e->write_fn = LLVMAddFunction(e->module, "write", LLVMFunctionType(sz_ty, write_params, 3, 0));
    LLVMTypeRef exit_params[1] = { e->i32_ty };
    e->exit_fn = LLVMAddFunction(e->module, "exit", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), exit_params, 1, 0));
    LLVMTypeRef memcpy_params[3] = { e->ptr_ty, e->ptr_ty, sz_ty };
    e->memcpy_fn = LLVMAddFunction(e->module, "memcpy", LLVMFunctionType(e->ptr_ty, memcpy_params, 3, 0));
    LLVMTypeRef fopen_params[2] = { e->ptr_ty, e->ptr_ty };
    e->fopen_fn = LLVMAddFunction(e->module, "fopen", LLVMFunctionType(e->ptr_ty, fopen_params, 2, 0));
    LLVMTypeRef fclose_params[1] = { e->ptr_ty };
    e->fclose_fn = LLVMAddFunction(e->module, "fclose", LLVMFunctionType(e->i32_ty, fclose_params, 1, 0));
    LLVMTypeRef fread_params[4] = { e->ptr_ty, sz_ty, sz_ty, e->ptr_ty };
    e->fread_fn = LLVMAddFunction(e->module, "fread", LLVMFunctionType(sz_ty, fread_params, 4, 0));
    e->fwrite_fn = LLVMAddFunction(e->module, "fwrite", LLVMFunctionType(sz_ty, fread_params, 4, 0));
    LLVMTypeRef fseek_params[3] = { e->ptr_ty, sz_ty, e->i32_ty };
    e->fseek_fn = LLVMAddFunction(e->module, "fseek", LLVMFunctionType(e->i32_ty, fseek_params, 3, 0));
    LLVMTypeRef ftell_params[1] = { e->ptr_ty };
    e->ftell_fn = LLVMAddFunction(e->module, "ftell", LLVMFunctionType(sz_ty, ftell_params, 1, 0));
    e->rewind_fn = LLVMAddFunction(e->module, "rewind", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), ftell_params, 1, 0));
    unsigned char has_main_wrapper = 0;
    for (size_t i = 0; i < e->function_count; i++) {
        if (e->functions[i].emit_main_wrapper) {
            has_main_wrapper = 1;
            break;
        }
    }
    e->saasm_argc_global = LLVMAddGlobal(e->module, e->i32_ty, "saasm_argc");
    e->saasm_argv_global = LLVMAddGlobal(e->module, e->ptr_ty, "saasm_argv");
    if (e->is_cgu && !has_main_wrapper) {
        LLVMSetLinkage(e->saasm_argc_global, LLVMExternalLinkage);
        LLVMSetLinkage(e->saasm_argv_global, LLVMExternalLinkage);
    } else {
        LLVMSetLinkage(e->saasm_argc_global, LLVMWeakAnyLinkage);
        LLVMSetLinkage(e->saasm_argv_global, LLVMWeakAnyLinkage);
        LLVMSetInitializer(e->saasm_argc_global, LLVMConstInt(e->i32_ty, 0, 0));
        LLVMSetInitializer(e->saasm_argv_global, LLVMConstPointerNull(e->ptr_ty));
    }
    return 0;
}

static void declare_sa_print_bytes(EmitCtx *e) {
    LLVMTypeRef params[2] = { e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_print_bytes");
    if (fn == NULL) {
        fn = LLVMAddFunction(e->module, "sa_print_bytes", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), params, 2, 0));
    }
    LLVMSetLinkage(fn, LLVMExternalLinkage);
}

static void emit_sa_print_bytes(EmitCtx *e) {
    LLVMTypeRef params[2] = { e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_print_bytes");
    if (fn == NULL) {
        fn = LLVMAddFunction(e->module, "sa_print_bytes", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), params, 2, 0));
    }
    if (LLVMCountBasicBlocks(fn) != 0) return;
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef len = coerce_to_size(e, LLVMGetParam(fn, 1), "len_size");
    LLVMValueRef args[3] = { LLVMConstInt(e->i32_ty, 1, 0), LLVMGetParam(fn, 0), len };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, args, 3, "");
    LLVMBuildRetVoid(e->builder);
}

static void emit_sys_print(EmitCtx *e) {
    LLVMTypeRef params[2] = { e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_print", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), params, 2, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef len = coerce_to_size(e, LLVMGetParam(fn, 1), "len_size");
    LLVMValueRef args[3] = { LLVMConstInt(e->i32_ty, 1, 0), LLVMGetParam(fn, 0), len };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, args, 3, "");
    LLVMBuildRetVoid(e->builder);
}

static void emit_sys_exit(EmitCtx *e) {
    LLVMTypeRef params[1] = { e->i32_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_exit", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), params, 1, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef code = LLVMGetParam(fn, 0);
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->exit_fn), e->exit_fn, &code, 1, "");
    LLVMBuildUnreachable(e->builder);
}

static void emit_panic_msg(EmitCtx *e) {
    LLVMTypeRef params[3] = { e->i32_ty, e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "panic_msg", LLVMFunctionType(LLVMVoidTypeInContext(e->ctx), params, 3, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    e->panic_fn = fn;
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef code = LLVMGetParam(fn, 0);
    LLVMValueRef msg_ptr = LLVMBuildPointerCast(e->builder, LLVMGetParam(fn, 1), LLVMPointerType(e->i8_ty, 0), "panic_msg_ptr");
    LLVMValueRef msg_len = coerce_to_size(e, LLVMGetParam(fn, 2), "panic_msg_len");
    LLVMTypeRef sz_ty = size_type(e);

    // Dynamic formatting of 'code' on the stack
    LLVMValueRef zero = LLVMConstInt(e->i64_ty, 0, 0);
    LLVMValueRef one = LLVMConstInt(e->i64_ty, 1, 0);
    LLVMValueRef two = LLVMConstInt(e->i64_ty, 2, 0);

    LLVMValueRef buf = LLVMBuildAlloca(e->builder, LLVMArrayType(e->i8_ty, 4), "buf");
    LLVMValueRef buf_ptr = LLVMBuildPointerCast(e->builder, buf, e->ptr_ty, "buf_ptr");

    LLVMBasicBlockRef ge_100_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "ge_100");
    LLVMBasicBlockRef lt_100_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "lt_100");
    LLVMBasicBlockRef ge_10_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "ge_10");
    LLVMBasicBlockRef lt_10_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "lt_10");
    LLVMBasicBlockRef merge_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "merge");

    LLVMValueRef cond_100 = LLVMBuildICmp(e->builder, LLVMIntSGE, code, LLVMConstInt(e->i32_ty, 100, 0), "cond_100");
    LLVMBuildCondBr(e->builder, cond_100, ge_100_bb, lt_100_bb);

    // Block: ge_100
    LLVMPositionBuilderAtEnd(e->builder, ge_100_bb);
    LLVMValueRef d0_100 = LLVMBuildSDiv(e->builder, code, LLVMConstInt(e->i32_ty, 100, 0), "d0");
    LLVMValueRef c0_100 = LLVMBuildAdd(e->builder, d0_100, LLVMConstInt(e->i32_ty, '0', 0), "c0");
    LLVMValueRef rem_100 = LLVMBuildSRem(e->builder, code, LLVMConstInt(e->i32_ty, 100, 0), "rem");
    LLVMValueRef d1_100 = LLVMBuildSDiv(e->builder, rem_100, LLVMConstInt(e->i32_ty, 10, 0), "d1");
    LLVMValueRef c1_100 = LLVMBuildAdd(e->builder, d1_100, LLVMConstInt(e->i32_ty, '0', 0), "c1");
    LLVMValueRef d2_100 = LLVMBuildSRem(e->builder, rem_100, LLVMConstInt(e->i32_ty, 10, 0), "d2");
    LLVMValueRef c2_100 = LLVMBuildAdd(e->builder, d2_100, LLVMConstInt(e->i32_ty, '0', 0), "c2");

    LLVMValueRef p0_100 = LLVMBuildGEP2(e->builder, e->i8_ty, buf_ptr, &zero, 1, "p0");
    LLVMBuildStore(e->builder, LLVMBuildTrunc(e->builder, c0_100, e->i8_ty, ""), p0_100);
    LLVMValueRef p1_100 = LLVMBuildGEP2(e->builder, e->i8_ty, buf_ptr, &one, 1, "p1");
    LLVMBuildStore(e->builder, LLVMBuildTrunc(e->builder, c1_100, e->i8_ty, ""), p1_100);
    LLVMValueRef p2_100 = LLVMBuildGEP2(e->builder, e->i8_ty, buf_ptr, &two, 1, "p2");
    LLVMBuildStore(e->builder, LLVMBuildTrunc(e->builder, c2_100, e->i8_ty, ""), p2_100);

    LLVMBuildBr(e->builder, merge_bb);

    // Block: lt_100
    LLVMPositionBuilderAtEnd(e->builder, lt_100_bb);
    LLVMValueRef cond_10 = LLVMBuildICmp(e->builder, LLVMIntSGE, code, LLVMConstInt(e->i32_ty, 10, 0), "cond_10");
    LLVMBuildCondBr(e->builder, cond_10, ge_10_bb, lt_10_bb);

    // Block: ge_10
    LLVMPositionBuilderAtEnd(e->builder, ge_10_bb);
    LLVMValueRef d0_10 = LLVMBuildSDiv(e->builder, code, LLVMConstInt(e->i32_ty, 10, 0), "d0");
    LLVMValueRef c0_10 = LLVMBuildAdd(e->builder, d0_10, LLVMConstInt(e->i32_ty, '0', 0), "c0");
    LLVMValueRef d1_10 = LLVMBuildSRem(e->builder, code, LLVMConstInt(e->i32_ty, 10, 0), "d1");
    LLVMValueRef c1_10 = LLVMBuildAdd(e->builder, d1_10, LLVMConstInt(e->i32_ty, '0', 0), "c1");

    LLVMValueRef p0_10 = LLVMBuildGEP2(e->builder, e->i8_ty, buf_ptr, &zero, 1, "p0");
    LLVMBuildStore(e->builder, LLVMBuildTrunc(e->builder, c0_10, e->i8_ty, ""), p0_10);
    LLVMValueRef p1_10 = LLVMBuildGEP2(e->builder, e->i8_ty, buf_ptr, &one, 1, "p1");
    LLVMBuildStore(e->builder, LLVMBuildTrunc(e->builder, c1_10, e->i8_ty, ""), p1_10);

    LLVMBuildBr(e->builder, merge_bb);

    // Block: lt_10
    LLVMPositionBuilderAtEnd(e->builder, lt_10_bb);
    LLVMValueRef c0_1 = LLVMBuildAdd(e->builder, code, LLVMConstInt(e->i32_ty, '0', 0), "c0");
    LLVMValueRef p0_1 = LLVMBuildGEP2(e->builder, e->i8_ty, buf_ptr, &zero, 1, "p0");
    LLVMBuildStore(e->builder, LLVMBuildTrunc(e->builder, c0_1, e->i8_ty, ""), p0_1);

    LLVMBuildBr(e->builder, merge_bb);

    // Block: merge
    LLVMPositionBuilderAtEnd(e->builder, merge_bb);
    LLVMValueRef formatted_len = LLVMBuildPhi(e->builder, sz_ty, "formatted_len");
    LLVMValueRef incoming_values[3] = {
        LLVMConstInt(sz_ty, 3, 0),
        LLVMConstInt(sz_ty, 2, 0),
        LLVMConstInt(sz_ty, 1, 0)
    };
    LLVMBasicBlockRef incoming_blocks[3] = {
        ge_100_bb,
        ge_10_bb,
        lt_10_bb
    };
    LLVMAddIncoming(formatted_len, incoming_values, incoming_blocks, 3);

    // Branch on msg_len == 0 to determine layout
    LLVMValueRef is_zero_len = LLVMBuildICmp(e->builder, LLVMIntEQ, msg_len, LLVMConstInt(sz_ty, 0, 0), "is_zero_len");
    LLVMBasicBlockRef simple_panic_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "simple_panic");
    LLVMBasicBlockRef msg_panic_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "msg_panic");
    LLVMBasicBlockRef exit_bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "exit_block");
    LLVMBuildCondBr(e->builder, is_zero_len, simple_panic_bb, msg_panic_bb);

    // Block: simple_panic
    LLVMPositionBuilderAtEnd(e->builder, simple_panic_bb);
    LLVMValueRef simple_prefix = const_c_string(e, ".panic_simple_prefix", "PANIC: code=");
    LLVMValueRef write_args_simple1[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        simple_prefix,
        LLVMConstInt(sz_ty, 12, 0)
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_simple1, 3, "");

    LLVMValueRef write_args_simple2[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        buf_ptr,
        formatted_len
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_simple2, 3, "");

    LLVMBuildBr(e->builder, exit_bb);

    // Block: msg_panic
    LLVMPositionBuilderAtEnd(e->builder, msg_panic_bb);
    LLVMValueRef msg_prefix = const_c_string(e, ".panic_msg_prefix", "PANIC[");
    LLVMValueRef write_args_msg1[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        msg_prefix,
        LLVMConstInt(sz_ty, 6, 0)
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_msg1, 3, "");

    LLVMValueRef write_args_msg2[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        buf_ptr,
        formatted_len
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_msg2, 3, "");

    LLVMValueRef msg_suffix = const_c_string(e, ".panic_msg_suffix", "]: ");
    LLVMValueRef write_args_msg3[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        msg_suffix,
        LLVMConstInt(sz_ty, 3, 0)
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_msg3, 3, "");

    LLVMValueRef write_args_msg4[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        msg_ptr,
        msg_len
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_msg4, 3, "");

    LLVMBuildBr(e->builder, exit_bb);

    // Block: exit_block
    LLVMPositionBuilderAtEnd(e->builder, exit_bb);
    LLVMValueRef newline = const_c_string(e, ".panic_newline", "\n");
    LLVMValueRef write_args_exit1[3] = {
        LLVMConstInt(e->i32_ty, 2, 0),
        newline,
        LLVMConstInt(sz_ty, 1, 0)
    };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args_exit1, 3, "");

    LLVMValueRef exit_code = LLVMBuildAdd(e->builder, code, LLVMConstInt(e->i32_ty, 128, 0), "exit_code");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->exit_fn), e->exit_fn, &exit_code, 1, "");
    LLVMBuildUnreachable(e->builder);
}

static void emit_sys_argc(EmitCtx *e) {
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_argc", LLVMFunctionType(e->i32_ty, NULL, 0, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMBuildRet(e->builder, LLVMBuildLoad2(e->builder, e->i32_ty, e->saasm_argc_global, "argc"));
}

static void emit_sys_argv(EmitCtx *e) {
    LLVMTypeRef params[1] = { e->i64_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_argv", LLVMFunctionType(e->ptr_ty, params, 1, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef argv = LLVMBuildLoad2(e->builder, e->ptr_ty, e->saasm_argv_global, "argv");
    LLVMValueRef index = coerce_to_size(e, LLVMGetParam(fn, 0), "index_size");
    LLVMTypeRef argv_array_ty = LLVMPointerType(e->ptr_ty, 0);
    LLVMValueRef argv_array = LLVMBuildPointerCast(e->builder, argv, argv_array_ty, "argv_array");
    LLVMValueRef slot = LLVMBuildGEP2(e->builder, e->ptr_ty, argv_array, &index, 1, "argv_slot");
    LLVMBuildRet(e->builder, LLVMBuildLoad2(e->builder, e->ptr_ty, slot, "arg"));
}

static void emit_sa_strdupz(EmitCtx *e) {
    LLVMTypeRef params[2] = { e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sa_strdupz", LLVMFunctionType(e->ptr_ty, params, 2, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, bb);
    LLVMValueRef len = coerce_to_size(e, LLVMGetParam(fn, 1), "len_size");
    LLVMValueRef one = size_const(e, 1);
    LLVMValueRef size = LLVMBuildAdd(e->builder, len, one, "size");
    LLVMValueRef buf = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->malloc_fn), e->malloc_fn, &size, 1, "buf");
    LLVMValueRef memcpy_args[3] = { buf, LLVMGetParam(fn, 0), len };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->memcpy_fn), e->memcpy_fn, memcpy_args, 3, "");
    LLVMValueRef end_index = len;
    LLVMValueRef end = LLVMBuildGEP2(e->builder, e->i8_ty, buf, &end_index, 1, "end");
    LLVMBuildStore(e->builder, LLVMConstInt(e->i8_ty, 0, 0), end);
    LLVMBuildRet(e->builder, buf);
}

static void emit_sys_read_file(EmitCtx *e) {
    LLVMTypeRef params[3] = { e->ptr_ty, e->i64_ty, e->ptr_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_read_file", LLVMFunctionType(e->ptr_ty, params, 3, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef fail = LLVMAppendBasicBlockInContext(e->ctx, fn, "fail");
    LLVMBasicBlockRef ok = LLVMAppendBasicBlockInContext(e->ctx, fn, "ok");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef dup_args[2] = { LLVMGetParam(fn, 0), LLVMGetParam(fn, 1) };
    LLVMValueRef path = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(LLVMGetNamedFunction(e->module, "sa_strdupz")), LLVMGetNamedFunction(e->module, "sa_strdupz"), dup_args, 2, "path");
    LLVMValueRef mode = const_c_string(e, ".mode_rb", "rb");
    LLVMValueRef fopen_args[2] = { path, mode };
    LLVMValueRef file = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fopen_fn), e->fopen_fn, fopen_args, 2, "file");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->free_fn), e->free_fn, &path, 1, "");
    LLVMValueRef is_null = LLVMBuildICmp(e->builder, LLVMIntEQ, file, LLVMConstPointerNull(e->ptr_ty), "is_null");
    LLVMBuildCondBr(e->builder, is_null, fail, ok);
    LLVMPositionBuilderAtEnd(e->builder, fail);
    LLVMValueRef out_len_ptr_fail = LLVMBuildPointerCast(e->builder, LLVMGetParam(fn, 2), LLVMPointerType(e->i64_ty, 0), "out_len_ptr");
    LLVMBuildStore(e->builder, LLVMConstInt(e->i64_ty, 0, 0), out_len_ptr_fail);
    LLVMBuildRet(e->builder, LLVMConstPointerNull(e->ptr_ty));
    LLVMPositionBuilderAtEnd(e->builder, ok);
    LLVMValueRef seek_args[3] = { file, size_const(e, 0), LLVMConstInt(e->i32_ty, 2, 0) };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fseek_fn), e->fseek_fn, seek_args, 3, "");
    LLVMValueRef size = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->ftell_fn), e->ftell_fn, &file, 1, "size");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->rewind_fn), e->rewind_fn, &file, 1, "");
    LLVMValueRef size_arg = coerce_to_size(e, size, "size_arg");
    LLVMValueRef buf = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->malloc_fn), e->malloc_fn, &size_arg, 1, "buf");
    LLVMValueRef fread_args[4] = { buf, size_const(e, 1), size_arg, file };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fread_fn), e->fread_fn, fread_args, 4, "");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fclose_fn), e->fclose_fn, &file, 1, "");
    LLVMValueRef out_len_ptr_ok = LLVMBuildPointerCast(e->builder, LLVMGetParam(fn, 2), LLVMPointerType(e->i64_ty, 0), "out_len_ptr");
    LLVMBuildStore(e->builder, coerce_int_to(e, size, e->i64_ty, "size64"), out_len_ptr_ok);
    LLVMBuildRet(e->builder, buf);
}

static void emit_sys_write_file(EmitCtx *e) {
    LLVMTypeRef params[4] = { e->ptr_ty, e->i64_ty, e->ptr_ty, e->i64_ty };
    LLVMValueRef fn = LLVMAddFunction(e->module, "sys_write_file", LLVMFunctionType(e->i32_ty, params, 4, 0));
    LLVMSetLinkage(fn, LLVMInternalLinkage);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMBasicBlockRef fail = LLVMAppendBasicBlockInContext(e->ctx, fn, "fail");
    LLVMBasicBlockRef ok = LLVMAppendBasicBlockInContext(e->ctx, fn, "ok");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMValueRef dup_args[2] = { LLVMGetParam(fn, 0), LLVMGetParam(fn, 1) };
    LLVMValueRef path = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(LLVMGetNamedFunction(e->module, "sa_strdupz")), LLVMGetNamedFunction(e->module, "sa_strdupz"), dup_args, 2, "path");
    LLVMValueRef mode = const_c_string(e, ".mode_wb", "wb");
    LLVMValueRef fopen_args[2] = { path, mode };
    LLVMValueRef file = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fopen_fn), e->fopen_fn, fopen_args, 2, "file");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->free_fn), e->free_fn, &path, 1, "");
    LLVMValueRef is_null = LLVMBuildICmp(e->builder, LLVMIntEQ, file, LLVMConstPointerNull(e->ptr_ty), "is_null");
    LLVMBuildCondBr(e->builder, is_null, fail, ok);
    LLVMPositionBuilderAtEnd(e->builder, fail);
    LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, (unsigned long long)-1, 1));
    LLVMPositionBuilderAtEnd(e->builder, ok);
    LLVMValueRef data_len = coerce_to_size(e, LLVMGetParam(fn, 3), "data_len_size");
    LLVMValueRef fwrite_args[4] = { LLVMGetParam(fn, 2), size_const(e, 1), data_len, file };
    LLVMValueRef written = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fwrite_fn), e->fwrite_fn, fwrite_args, 4, "written");
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->fclose_fn), e->fclose_fn, &file, 1, "");
    LLVMBuildRet(e->builder, coerce_int_to(e, written, e->i32_ty, "status"));
}

static void emit_sa_time_sleep_ns(EmitCtx *e) {
    LLVMTypeRef params[1] = { e->i64_ty };
    LLVMTypeRef ret_ty = fallible_type_of(e, SA_T_I32);
    LLVMValueRef fn = LLVMGetNamedFunction(e->module, "sa_time_sleep_ns");
    if (fn == NULL) {
        fn = LLVMAddFunction(e->module, "sa_time_sleep_ns", LLVMFunctionType(ret_ty, params, 1, 0));
    }
    LLVMSetLinkage(fn, LLVMWeakAnyLinkage);
    if (LLVMCountBasicBlocks(fn) != 0) return;
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(e->ctx, fn, "entry");
    LLVMPositionBuilderAtEnd(e->builder, entry);
    LLVMBuildRet(e->builder, build_fallible_ok(e, SA_T_I32, LLVMConstInt(e->i32_ty, 0, 0), SA_T_I32));
}

static void emit_sys_runtime(EmitCtx *e) {
    emit_sa_strdupz(e);
    emit_sys_print(e);
    emit_sys_exit(e);
    emit_panic_msg(e);
    emit_sys_argc(e);
    emit_sys_argv(e);
    emit_sys_read_file(e);
    emit_sys_write_file(e);
    emit_sa_time_sleep_ns(e);
}

int sa_llvmc_make_minimal_module_bitcode(unsigned char **out_bytes, size_t *out_len, char **out_error) {
    if (out_bytes == NULL || out_len == NULL) return set_error(out_error, "invalid output pointers");
    *out_bytes = NULL; *out_len = 0;
    LLVMContextRef context = LLVMContextCreate();
    if (context == NULL) return set_error(out_error, "LLVMContextCreate failed");
    LLVMModuleRef module = LLVMModuleCreateWithNameInContext("sa_llvmc_test", context);
    LLVMBuilderRef builder = LLVMCreateBuilderInContext(context);
    LLVMTypeRef i32_ty = LLVMInt32TypeInContext(context);
    LLVMTypeRef fn_ty = LLVMFunctionType(i32_ty, NULL, 0, 0);
    LLVMValueRef fn_value = LLVMAddFunction(module, "main", fn_ty);
    LLVMBasicBlockRef entry = LLVMAppendBasicBlockInContext(context, fn_value, "entry");
    LLVMPositionBuilderAtEnd(builder, entry);
    LLVMBuildRet(builder, LLVMConstInt(i32_ty, 0, 0));
    int status = module_bitcode_to_heap(module, out_bytes, out_len);
    LLVMDisposeBuilder(builder); LLVMDisposeModule(module); LLVMContextDispose(context);
    if (status != 0) return set_error(out_error, "writing bitcode failed");
    return 0;
}

static void emit_test_harness_main(EmitCtx *e, const SaModule *m) {
    LLVMValueRef getenv_fn = LLVMGetNamedFunction(e->module, "getenv");
    if (getenv_fn == NULL) {
        LLVMTypeRef getenv_param = e->ptr_ty;
        getenv_fn = LLVMAddFunction(e->module, "getenv", LLVMFunctionType(e->ptr_ty, &getenv_param, 1, 0));
    }

    LLVMValueRef strcmp_fn = LLVMGetNamedFunction(e->module, "strcmp");
    if (strcmp_fn == NULL) {
        LLVMTypeRef strcmp_params[2] = { e->ptr_ty, e->ptr_ty };
        strcmp_fn = LLVMAddFunction(e->module, "strcmp", LLVMFunctionType(e->i32_ty, strcmp_params, 2, 0));
    }

    size_t test_count = 0;
    for (size_t i = 0; i < m->function_count; i++) {
        if (m->functions[i].kind == SA_F_TEST) test_count++;
    }

    LLVMTypeRef main_params[2] = { e->i32_ty, e->ptr_ty };
    LLVMValueRef main_fn = LLVMAddFunction(e->module, "main", LLVMFunctionType(e->i32_ty, main_params, 2, 0));

    if (test_count == 0) {
        LLVMBasicBlockRef entry_bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "entry");
        LLVMPositionBuilderAtEnd(e->builder, entry_bb);
        LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 0, 0));
        return;
    }

    LLVMBasicBlockRef entry_bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "entry");
    LLVMBasicBlockRef run_all_bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "run_all");
    LLVMBasicBlockRef select_bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "select");

    LLVMPositionBuilderAtEnd(e->builder, entry_bb);
    LLVMBuildStore(e->builder, LLVMGetParam(main_fn, 0), e->saasm_argc_global);
    LLVMBuildStore(e->builder, LLVMGetParam(main_fn, 1), e->saasm_argv_global);
    LLVMValueRef env_ptr = const_c_string(e, ".sa_test_name_env", "SA_TEST_NAME");
    LLVMValueRef filter = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(getenv_fn), getenv_fn, &env_ptr, 1, "filter");
    LLVMValueRef has_filter = LLVMBuildICmp(e->builder, LLVMIntNE, filter, LLVMConstPointerNull(e->ptr_ty), "has_filter");
    LLVMBuildCondBr(e->builder, has_filter, select_bb, run_all_bb);

    LLVMPositionBuilderAtEnd(e->builder, run_all_bb);
    for (size_t i = 0; i < m->function_count; i++) {
        if (m->functions[i].kind != SA_F_TEST) continue;
        LLVMValueRef test_fn = find_function(e, m->functions[i].name);
        LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(test_fn), test_fn, NULL, 0, "");
    }
    LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 0, 0));

    LLVMPositionBuilderAtEnd(e->builder, select_bb);
    LLVMBasicBlockRef current_select = select_bb;
    for (size_t i = 0; i < m->function_count; i++) {
        if (m->functions[i].kind != SA_F_TEST) continue;
        char glob_name[64];
        sprintf(glob_name, ".sa_test_name_%zu", i);
        LLVMValueRef test_name_ptr = const_c_string(e, glob_name, m->functions[i].name);
        LLVMValueRef strcmp_args[2] = { filter, test_name_ptr };
        LLVMValueRef cmp = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(strcmp_fn), strcmp_fn, strcmp_args, 2, "cmp");
        LLVMValueRef eq = LLVMBuildICmp(e->builder, LLVMIntEQ, cmp, LLVMConstInt(e->i32_ty, 0, 0), "eq");

        LLVMBasicBlockRef match_bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "match");
        LLVMBasicBlockRef next_select = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "select_next");
        LLVMBuildCondBr(e->builder, eq, match_bb, next_select);

        LLVMPositionBuilderAtEnd(e->builder, match_bb);
        LLVMValueRef test_fn = find_function(e, m->functions[i].name);
        LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(test_fn), test_fn, NULL, 0, "");
        LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 0, 0));

        current_select = next_select;
        LLVMPositionBuilderAtEnd(e->builder, current_select);
    }

    LLVMValueRef missing_ptr = const_c_string(e, ".sa_test_missing_msg", "error: no matching test\n");
    LLVMTypeRef sz_ty = size_type(e);
    LLVMValueRef missing_len = LLVMConstInt(sz_ty, 24, 0);
    LLVMValueRef write_args[3] = { LLVMConstInt(e->i32_ty, 2, 0), missing_ptr, missing_len };
    LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(e->write_fn), e->write_fn, write_args, 3, "written");
    LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 1, 0));
}

/* Build an LLVM module from a SA module description.
 * On success returns 0 and *e is fully initialised – caller must dispose_emit_ctx(e).
 * On failure returns non-zero and disposes the partial context itself. */
static int build_sa_llvm_module(const SaModule *m, EmitCtx *e, char **out_error) {
    memset(e, 0, sizeof(*e));
    e->ctx = LLVMContextCreate();
    if (e->ctx == NULL) return set_error(out_error, "LLVMContextCreate failed");
    e->module = LLVMModuleCreateWithNameInContext("sa_module", e->ctx);
    e->builder = LLVMCreateBuilderInContext(e->ctx);
    e->size_bits = m->size_bits;
    e->is_cgu = m->is_cgu;
    e->i8_ty  = LLVMInt8TypeInContext(e->ctx);
    e->i32_ty = LLVMInt32TypeInContext(e->ctx);
    e->i64_ty = LLVMInt64TypeInContext(e->ctx);
    e->ptr_ty = LLVMPointerType(e->i8_ty, 0);
    e->functions     = m->functions;
    e->function_count = m->function_count;

    debug_init(e, m);
    declare_runtime(e);

    for (size_t i = 0; i < m->const_count; i++) {
        LLVMTypeRef arr_ty = LLVMArrayType(e->i8_ty, (unsigned)m->consts[i].len);
        LLVMValueRef glob = LLVMAddGlobal(e->module, arr_ty, m->consts[i].name);
        LLVMSetGlobalConstant(glob, 1);
        LLVMSetLinkage(glob, LLVMPrivateLinkage);
        LLVMValueRef *vals = NULL;
        if (m->consts[i].len != 0) vals = (LLVMValueRef *)malloc(sizeof(LLVMValueRef) * m->consts[i].len);
        if (m->consts[i].len != 0 && vals == NULL) { dispose_emit_ctx(e); return set_error(out_error, "alloc const failed"); }
        for (size_t j = 0; j < m->consts[i].len; j++) vals[j] = LLVMConstInt(e->i8_ty, m->consts[i].data[j], 0);
        LLVMSetInitializer(glob, LLVMConstArray(e->i8_ty, vals, (unsigned)m->consts[i].len));
        free(vals);
    }

    for (size_t i = 0; i < m->function_count; i++) {
        if (strcmp(m->functions[i].name, "sa_print_bytes") == 0 && m->functions[i].kind == SA_F_EXTERNAL) {
            declare_sa_print_bytes(e);
            continue;
        }
        LLVMTypeRef fty = fn_type_for(e, &m->functions[i]);
        if (fty == NULL) { dispose_emit_ctx(e); return set_error(out_error, "function type failed"); }
        LLVMValueRef fn = LLVMAddFunction(e->module, m->functions[i].name, fty);
        if (m->functions[i].kind != SA_F_EXPORTED && strcmp(m->functions[i].name, "saasm_main") != 0)
            LLVMSetLinkage(fn, (m->functions[i].kind == SA_F_EXTERNAL || m->is_cgu) ? LLVMExternalLinkage : LLVMInternalLinkage);
    }
    if (m->wasm_compat) emit_sa_print_bytes(e);
    emit_sys_runtime(e);

    for (size_t i = 0; i < m->vtable_count; i++) {
        LLVMTypeRef slot_ty = vtable_slot_type(e);
        LLVMTypeRef arr_ty  = LLVMArrayType(slot_ty, (unsigned)m->vtables[i].func_count);
        LLVMValueRef glob   = LLVMAddGlobal(e->module, arr_ty, m->vtables[i].name);
        LLVMSetGlobalConstant(glob, 1);
        LLVMSetLinkage(glob, LLVMPrivateLinkage);
        LLVMValueRef *vals = NULL;
        if (m->vtables[i].func_count != 0) vals = (LLVMValueRef *)malloc(sizeof(LLVMValueRef) * m->vtables[i].func_count);
        if (m->vtables[i].func_count != 0 && vals == NULL) { dispose_emit_ctx(e); return set_error(out_error, "alloc vtable failed"); }
        for (size_t j = 0; j < m->vtables[i].func_count; j++) {
            LLVMValueRef fn = find_function(e, m->vtables[i].funcs[j]);
            if (fn == NULL) { free(vals); dispose_emit_ctx(e); return set_error(out_error, "vtable function not found"); }
            vals[j] = vtable_slot_value(e, fn);
        }
        LLVMSetInitializer(glob, LLVMConstArray(slot_ty, vals, (unsigned)m->vtables[i].func_count));
        free(vals);
    }

    for (size_t i = 0; i < m->function_count; i++) {
        if (m->functions[i].kind == SA_F_EXTERNAL) continue;
        if (emit_function_body(e, &m->functions[i]) != 0) {
            int err_status = set_error(out_error, e->body_error[0] != 0 ? e->body_error : "emit function body failed");
            dispose_emit_ctx(e);
            return err_status;
        }
    }

    if (m->test_mode) {
        emit_test_harness_main(e, m);
    } else {
        for (size_t i = 0; i < m->function_count; i++) {
            if (!m->functions[i].emit_main_wrapper) continue;
            LLVMTypeRef params[2] = { e->i32_ty, e->ptr_ty };
            LLVMValueRef main_fn = LLVMAddFunction(e->module, "main", LLVMFunctionType(e->i32_ty, params, 2, 0));
            LLVMBasicBlockRef bb = LLVMAppendBasicBlockInContext(e->ctx, main_fn, "entry");
            LLVMPositionBuilderAtEnd(e->builder, bb);
            LLVMBuildStore(e->builder, LLVMGetParam(main_fn, 0), e->saasm_argc_global);
            LLVMBuildStore(e->builder, LLVMGetParam(main_fn, 1), e->saasm_argv_global);
            LLVMValueRef target = find_function(e, m->functions[i].name);
            LLVMValueRef res = LLVMBuildCall2(e->builder, LLVMGlobalGetValueType(target), target, NULL, 0,
                m->functions[i].ret_ty == SA_T_VOID && !m->functions[i].return_fallible ? "" : "res");
            if (m->functions[i].return_fallible) {
                LLVMValueRef status = LLVMBuildExtractValue(e->builder, res, 0, "status");
                LLVMBuildRet(e->builder, status);
            } else if (m->functions[i].ret_ty == SA_T_VOID) {
                LLVMBuildRet(e->builder, LLVMConstInt(e->i32_ty, 0, 0));
            } else {
                LLVMBuildRet(e->builder, coerce(e, res, m->functions[i].ret_ty, SA_T_I32));
            }
            break;
        }
    }

    if (e->dib != NULL) LLVMDIBuilderFinalize(e->dib);

    char *verify_error = NULL;
    if (LLVMVerifyModule(e->module, LLVMReturnStatusAction, &verify_error) != 0) {
        if (verify_error != NULL) {
            int status = set_error(out_error, verify_error);
            LLVMDisposeMessage(verify_error);
            dispose_emit_ctx(e);
            return status;
        }
        dispose_emit_ctx(e);
        return set_error(out_error, "LLVMVerifyModule failed");
    }
    return 0;
}

/* Emit LLVM bitcode bytes to heap (original interface). */
int sa_llvmc_emit_module_bitcode(const SaModule *m, unsigned char **out_bytes, size_t *out_len, char **out_error) {
    if (m == NULL || out_bytes == NULL || out_len == NULL) return set_error(out_error, "invalid module pointers");
    *out_bytes = NULL; *out_len = 0;
    EmitCtx e;
    if (build_sa_llvm_module(m, &e, out_error) != 0) return 1;
    int status = module_bitcode_to_heap(e.module, out_bytes, out_len);
    dispose_emit_ctx(&e);
    if (status != 0) return set_error(out_error, "writing bitcode failed");
    return 0;
}

/* In-process native object emission: build IR and emit .o without spawning any subprocess.
 * opt_level: 0=none, 1=O1 (fast, matches -O1), 2=O2, 3=O3 */
int sa_llvmc_emit_module_object(const SaModule *m, const char *out_path, int opt_level, char **out_error) {
    if (m == NULL || out_path == NULL) return set_error(out_error, "invalid pointers");
    EmitCtx e;
    if (build_sa_llvm_module(m, &e, out_error) != 0) return 1;

    /* Initialize native backend (idempotent, safe to call from multiple threads) */
    LLVMInitializeNativeTarget();
    LLVMInitializeNativeAsmPrinter();

    char *triple = LLVMGetDefaultTargetTriple();
    LLVMTargetRef target;
    char *err_msg = NULL;
    if (LLVMGetTargetFromTriple(triple, &target, &err_msg)) {
        int s = set_error(out_error, err_msg ? err_msg : "target lookup failed");
        if (err_msg) LLVMDisposeMessage(err_msg);
        LLVMDisposeMessage(triple);
        dispose_emit_ctx(&e);
        return s;
    }

    LLVMCodeGenOptLevel cg_opt;
    switch (opt_level) {
        case 0:  cg_opt = LLVMCodeGenLevelNone;        break;
        case 1:  cg_opt = LLVMCodeGenLevelLess;        break;
        case 2:  cg_opt = LLVMCodeGenLevelDefault;     break;
        default: cg_opt = LLVMCodeGenLevelAggressive;  break;
    }

    /* Use the host CPU so we get tuned codegen (equivalent to -mcpu=native) */
    char *cpu      = LLVMGetHostCPUName();
    char *features = LLVMGetHostCPUFeatures();
    LLVMTargetMachineRef tm = LLVMCreateTargetMachine(
        target, triple, cpu, features,
        cg_opt, LLVMRelocDefault, LLVMCodeModelDefault
    );
    LLVMDisposeMessage(cpu);
    LLVMDisposeMessage(features);
    LLVMDisposeMessage(triple);

    if (tm == NULL) {
        dispose_emit_ctx(&e);
        return set_error(out_error, "TargetMachine creation failed");
    }

    /* Align the module data layout with the target machine */
    LLVMTargetDataRef dl = LLVMCreateTargetDataLayout(tm);
    char *dl_str = LLVMCopyStringRepOfTargetData(dl);
    LLVMSetDataLayout(e.module, dl_str);
    LLVMDisposeMessage(dl_str);
    LLVMDisposeTargetData(dl);

    if (LLVMTargetMachineEmitToFile(tm, e.module, (char *)out_path, LLVMObjectFile, &err_msg)) {
        int s = set_error(out_error, err_msg ? err_msg : "emit object failed");
        if (err_msg) LLVMDisposeMessage(err_msg);
        LLVMDisposeTargetMachine(tm);
        dispose_emit_ctx(&e);
        return s;
    }

    LLVMDisposeTargetMachine(tm);
    dispose_emit_ctx(&e);
    return 0;
}
