// Turning compiler records into Message_*, Code_* and Type_Info_* structs.
//
// jaic exports messages, syntax trees and type descriptors as records: a tag naming
// the struct to build and named fields (see docs/metaprogramming/compiler-records.md). The
// structs are filled by reflection, member by member, so the layouts in the *_nodes.jai and messages.jai files are the
// only place that knows them: each struct type is described to the compiler once, as a plan
// of its members, and the compiler builds a record and everything it reaches in one call
// (`__jaic_rec_build`). Each record is built once; pointers to the same record are the same
// pointer for the rest of the compilation.

#scope_module

REC_NONE :: 0;
REC_INT :: 1;
REC_STRING :: 2;
REC_REF :: 3;
REC_LIST :: 4;

// This program's builder in the compiler (0 = none yet).
record_builder: s64;

// The struct for record `id`, built on first use. `expected` is the pointed-to type of
// the member being filled; the record's tag may name a subtype of it.
record_struct :: (id: s64, expected: *Type_Info) -> *void {
    if id <= 0 return null;
    builder := records_builder();
    if expected && expected.type == .STRUCT record_plan(cast(*Type_Info_Struct) expected);
    return __jaic_rec_build(builder, id, expected);
}

// The record a built struct came from (0 if none).
record_of :: (pointer: *void) -> s64 {
    if !pointer || !record_builder return 0;
    return __jaic_rec_of(record_builder, pointer);
}

records_builder :: () -> s64 {
    if record_builder return record_builder;
    record_builder = __jaic_rec_builder();
    for RECORD_TYPES {
        info := cast(*Type_Info_Struct) it;
        record_plan(info);
        __jaic_rec_type(record_builder, info.name, info);
    }
    for BUILTIN_TYPES __jaic_rec_builtin(record_builder, BUILTIN_NAMES[it_index], cast(*Type_Info) it);
    return record_builder;
}

record_slot_hash :: (pointer: *void) -> s64 #no_aoc {
    return cast,no_check(s64) ((cast(u64) pointer * 11400714819323198485) >> 32);
}

// Structs a record's tag may name where a member points to a base type (*Code_Node,
// *Type_Info, *Message). Other records are built as the member's own type.
RECORD_TYPES :: Type.[
    Message_File, Message_Import, Message_Failed_Import, Message_Typechecked, Message_Performance_Report,

    Code_Node, Code_Ident, Code_Literal, Code_Context, Code_Binary_Operator, Code_Unary_Operator,
    Code_Procedure_Call, Code_Cast, Code_If, Code_Case, Code_Type_Instantiation,
    Code_Procedure_Header, Code_Procedure_Body, Code_Block, Code_Struct, Code_Enum,
    Code_Directive_Run, Code_Directive_Code, Code_Directive_Insert, Code_Directive_Location,
    Code_Directive_Import, Code_Note, Code_Declaration, Code_While, Code_For, Code_Loop_Control,
    Code_Return, Code_Defer, Code_Using, Code_Push_Context, Code_Compound_Declaration,
    Code_Comma_Separated_Arguments, Code_Directive_Exists, Code_Directive_Bytes,
    Code_Directive_Procedure_Name, Code_Directive_Bake, Code_Directive_Load, Code_Directive_Place,
    Code_Directive_Overlay, Code_Directive_Add_Context, Code_Directive_Module_Parameters, Code_Asm,

    Type_Info, Type_Info_Integer, Type_Info_Float, Type_Info_String, Type_Info_Pointer,
    Type_Info_Procedure, Type_Info_Struct, Type_Info_Array, Type_Info_Enum, Type_Info_Variant,
];

// The metaprogram's own descriptors for the target program's primitive types, by name.
BUILTIN_NAMES :: string.[
    "s8", "s16", "s32", "s64", "int", "u8", "u16", "u32", "u64",
    "float", "float32", "float64", "bool", "string", "void", "Any", "Type", "Code",
];

BUILTIN_TYPES :: Type.[
    s8, s16, s32, s64, int, u8, u16, u32, u64,
    float, float32, float64, bool, string, void, Any, Type, Code,
];

record_type :: (tag: string) -> *Type_Info_Struct {
    for RECORD_TYPES {
        info := cast(*Type_Info_Struct) it;
        if info.name == tag return info;
    }
    return null;
}

// record_type of a record's tag, cached by `__jaic_rec_tag_id` (UNKNOWN_TAG = not looked up yet).
record_tag_types: [..] *Type_Info_Struct;
UNKNOWN_TAG :: cast(*Type_Info_Struct) 1;

record_type_of :: (id: s64) -> *Type_Info_Struct {
    tag := __jaic_rec_tag_id(id);
    if tag < 0 return null;
    if tag >= record_tag_types.count {
        old := record_tag_types.count;
        array_resize(*record_tag_types, tag + 1, initialize = false);
        for old..tag record_tag_types[it] = UNKNOWN_TAG;
    }
    if record_tag_types[tag] == UNKNOWN_TAG record_tag_types[tag] = record_type(__jaic_rec_tag(id));
    return record_tag_types[tag];
}

// The members a struct is filled through, flattened through `using` and anonymous members.
// The compiler reads this layout (`__jaic_rec_plan`): keep it in step with record_build.rs.
Record_Plan_Entry :: struct {
    offset: s64;
    kind: s64;
    size: s64;
    name: string;
    type: *Type_Info;
    // PLAN_ARRAY: what the elements are.
    element_kind: s64;
    element_size: s64;
    // What a pointer (or an array's pointer elements) points to, or the struct held in place
    // (or as elements).
    target: *Type_Info;
    resizable: s64;
}

PLAN_OTHER :: 0;
PLAN_INT :: 1;
PLAN_STRING :: 2;
PLAN_POINTER :: 3;
PLAN_STRUCT :: 4;
PLAN_ARRAY :: 5;

Record_Plan :: struct {
    info: *Type_Info_Struct;
    entries: [] Record_Plan_Entry;
}

record_plans: [] Record_Plan; // Open addressing by info.
record_plans_used: s64;

last_plan_info: *Type_Info_Struct;
last_plan: [] Record_Plan_Entry;

record_plan :: (info: *Type_Info_Struct) -> [] Record_Plan_Entry {
    if info == last_plan_info return last_plan;
    plan := find_record_plan(info);
    last_plan_info = info;
    last_plan = plan;
    return plan;
}

// A struct's plan, made and handed to the compiler on first use, with the plans of every
// struct its members reach: the compiler builds whole graphs of records without asking.
find_record_plan :: (info: *Type_Info_Struct) -> [] Record_Plan_Entry {
    if record_plans.count {
        mask := record_plans.count - 1;
        slot := record_slot_hash(info) & mask;
        while record_plans[slot].info {
            if record_plans[slot].info == info return record_plans[slot].entries;
            slot = (slot + 1) & mask;
        }
    }
    entries: [..] Record_Plan_Entry;
    add_plan_entries(*entries, info, 0);
    if (record_plans_used + 1) * 2 >= record_plans.count {
        old := record_plans;
        record_plans = NewArray(max(64, old.count * 2), Record_Plan);
        record_plans_used = 0;
        for old if it.info insert_record_plan(it);
        array_free(old);
    }
    insert_record_plan(.{ info, entries });
    __jaic_rec_plan(records_builder(), info, info.runtime_size, entries.data, entries.count, info == type_info(Type_Info_Struct));
    for entries {
        if it.target && it.target.type == .STRUCT find_record_plan(cast(*Type_Info_Struct) it.target);
    }
    return entries;
}

insert_record_plan :: (plan: Record_Plan) {
    mask := record_plans.count - 1;
    slot := record_slot_hash(plan.info) & mask;
    while record_plans[slot].info slot = (slot + 1) & mask;
    record_plans[slot] = plan;
    record_plans_used += 1;
}

add_plan_entries :: (entries: *[..] Record_Plan_Entry, info: *Type_Info_Struct, base: s64) {
    for member: info.members {
        if member.flags & .CONSTANT continue;
        offset := base + member.offset_in_bytes;
        // `#as using base`, `using location`, anonymous unions: same record.
        if member.type.type == .STRUCT && (member.flags & .USING || member.name == "") {
            add_plan_entries(entries, cast(*Type_Info_Struct) member.type, offset);
            continue;
        }
        entry := Record_Plan_Entry.{ offset = offset, kind = plan_kind(member.type), size = member.type.runtime_size, name = member.name, type = member.type };
        entry.target = plan_target(member.type);
        if member.type.type == .ARRAY {
            array := cast(*Type_Info_Array) member.type;
            if array.array_type != .FIXED {
                entry.kind = PLAN_ARRAY;
                entry.element_kind = plan_kind(array.element_type);
                entry.element_size = array.element_type.runtime_size;
                entry.target = plan_target(array.element_type);
                entry.resizable = xx (array.array_type == .RESIZABLE);
            }
        }
        array_add(entries, entry);
    }
}

plan_kind :: (type: *Type_Info) -> s64 {
    if type.type == {
        case .INTEGER; #through;
        case .ENUM; #through;
        case .BOOL; #through;
        case .FLOAT; return PLAN_INT;
        case .STRING; return PLAN_STRING;
        case .POINTER; return PLAN_POINTER;
        case .STRUCT; return PLAN_STRUCT;
    }
    return PLAN_OTHER;
}

plan_target :: (type: *Type_Info) -> *Type_Info {
    if type.type == .POINTER return (cast(*Type_Info_Pointer) type).pointer_to;
    if type.type == .STRUCT return type;
    return null;
}

// Whether a built node was edited in place since it was built (by a metaprogram before
// compiler_modify_procedure). Compares member by member with the record, as fill_struct
// wrote them, and follows pointers into other Code nodes, but not into what a node
// resolves to (`resolved_*`, `type`): those are other trees, not part of this one.
record_differs :: (memory: *void, id: s64) -> bool {
    differs_seen.count = 0;
    return struct_differs(memory, record_type_of(id), id);
}

#scope_file

differs_seen: [..] *void;

struct_differs :: (memory: *u8, info: *Type_Info_Struct, id: s64) -> bool {
    if !info return false;
    for differs_seen if it == memory return false; // Headers and bodies point at each other.
    array_add(*differs_seen, memory);
    plan := record_plan(info);
    for plan {
        if it.name == "type" || begins_with_resolved(it.name) continue;
        if __jaic_rec_field(id, it.name) == REC_NONE && union_member_present(plan, it, id) continue;
        if value_differs(memory + it.offset, it.type, id, it.name, -1) return true;
    }
    return false;
}

// A member of a union (`Code_Literal`'s values) whose memory holds another member the record has.
union_member_present :: (plan: [] Record_Plan_Entry, entry: Record_Plan_Entry, id: s64) -> bool {
    for plan {
        if it.offset < entry.offset + entry.size && entry.offset < it.offset + it.size && it.name != entry.name
            && __jaic_rec_field(id, it.name) != REC_NONE return true;
    }
    return false;
}

begins_with_resolved :: (name: string) -> bool {
    prefix :: "resolved_";
    if name.count < prefix.count return false;
    return memcmp(name.data, prefix.data, prefix.count) == 0;
}

is_code_struct :: (info: *Type_Info_Struct) -> bool {
    return info.name.count > 5 && memcmp(info.name.data, "Code_".data, 5) == 0;
}

value_differs :: (target: *u8, type: *Type_Info, id: s64, name: string, index: s64) -> bool {
    if type.type == {
        case .INTEGER; #through;
        case .ENUM; #through;
        case .BOOL; #through;
        case .FLOAT;
            value := ifx index < 0 then __jaic_rec_int(id, name) else __jaic_rec_item_int(id, name, index);
            return memcmp(target, *value, type.runtime_size) != 0;

        case .STRING;
            value := ifx index < 0 then __jaic_rec_string(id, name) else __jaic_rec_item_string(id, name, index);
            have := (cast(*string) target).*;
            return have.count != value.count || (have.count > 0 && memcmp(have.data, value.data, have.count) != 0);

        case .POINTER;
            ref := ifx index < 0 then __jaic_rec_ref(id, name) else __jaic_rec_item_ref(id, name, index);
            pointer := (cast(**void) target).*;
            if !ref return pointer != null;
            if record_of(pointer) != ref return true;
            info := record_type_of(ref);
            if info && is_code_struct(info) return struct_differs(pointer, info, ref);
            return false;

        case .STRUCT;
            ref := ifx index < 0 then __jaic_rec_ref(id, name) else __jaic_rec_item_ref(id, name, index);
            if !ref return false;
            return struct_differs(target, cast(*Type_Info_Struct) type, ref);

        case .ARRAY;
            array := cast(*Type_Info_Array) type;
            if index >= 0 || array.array_type == .FIXED return false;
            count := __jaic_rec_count(id, name);
            view := cast(*Resizable_Array) target;
            if view.count != count return true;
            element := array.element_type;
            for k: 0..count - 1 {
                if value_differs(view.data + k * element.runtime_size, element, id, name, k) return true;
            }
    }
    return false;
}

#scope_module

__jaic_rec_tag :: (record: s64) -> string #compiler;
__jaic_rec_field :: (record: s64, name: string) -> s64 #compiler;
__jaic_rec_int :: (record: s64, name: string) -> s64 #compiler;
__jaic_rec_string :: (record: s64, name: string) -> string #compiler;
__jaic_rec_ref :: (record: s64, name: string) -> s64 #compiler;
__jaic_rec_count :: (record: s64, name: string) -> s64 #compiler;
__jaic_rec_item_int :: (record: s64, name: string, index: s64) -> s64 #compiler;
__jaic_rec_item_string :: (record: s64, name: string, index: s64) -> string #compiler;
__jaic_rec_item_ref :: (record: s64, name: string, index: s64) -> s64 #compiler;
__jaic_rec_tag_id :: (record: s64) -> s64 #compiler;
__jaic_rec_builder :: () -> s64 #compiler;
__jaic_rec_type :: (builder: s64, tag: string, info: *Type_Info) #compiler;
__jaic_rec_builtin :: (builder: s64, name: string, info: *Type_Info) #compiler;
__jaic_rec_plan :: (builder: s64, info: *Type_Info, size: s64, entries: *Record_Plan_Entry, count: s64, is_type_info_struct: bool) #compiler;
__jaic_rec_build :: (builder: s64, record: s64, expected: *Type_Info) -> *void #compiler;
__jaic_rec_of :: (builder: s64, pointer: *void) -> s64 #compiler;
__jaic_code_nodes :: (code: Code) -> s64 #compiler;
__jaic_parse_code :: (text: string, scope_from: Code) -> Code #compiler;
__jaic_modify_procedure :: (ws: s64, body: s64, statements: *s64, sources: *string, count: s64) #compiler;
__jaic_workspace_add_string_to_module :: (ws: s64, source: string, message: s64) #compiler;
