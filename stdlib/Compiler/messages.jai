// Message records delivered to compiler message loops, and the report records
// that ride along with them.
//
// Everything here is plain data built from records exported by jaic
// (records.jai, docs/metaprogramming/compiler-records.md).

#scope_export

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

Message_Phase :: struct {
    #as using m: Message;

    phase: enum u32 {
        ALL_SOURCE_CODE_PARSED :: 0;
        TYPECHECKED_ALL_WE_CAN :: 1;
        ALL_TARGET_CODE_BUILT :: 2;

        PRE_WRITE_EXECUTABLE :: 3;
        POST_WRITE_EXECUTABLE :: 4;

        READY_FOR_CUSTOM_LINK_COMMAND :: 5;
    };

    executable_name: string;
    executable_write_failed := false;
    linker_exit_code: s32;
    num_items_waiting_to_typecheck: s32;

    compiler_generated_object_files: [] string;
    support_object_files: [] string;
    system_libraries: [] string;
    user_libraries: [] string;
};

Message_Complete :: struct {
    #as using m: Message;

    error_code: enum u8 {
        NONE :: 0;
        COMPILATION_FAILED :: 1;
        COMPILER_SHUTDOWN :: 2;
    }
}

Message_Failed_Import :: struct {
    #as using m: Message;

    status: enum u8 {
        UNINITIALIZED :: 0;
        BLOCKED :: 1;
        NOT_FOUND :: 2;
    };

    host_module_name: string;
    target_module_name: string;

    import_code: *Code_Directive_Import;
}

Message_Import :: struct {
    #as using m: Message;

    module_type: enum u8 {
        UNINITIALIZED :: 0;
        PRELOAD :: 1;
        RUNTIME_SUPPORT :: 2;
        MAIN_PROGRAM :: 3;
        FILE :: 4;
    };

    module_name: string;
    fully_pathed_filename: string;
}

Message_File :: struct {
    #as using m: Message;

    fully_pathed_filename: string;
    enclosing_import: *Message_Import;
    from_a_string: bool;
}

Message :: struct {
    kind: enum u8 {
        UNINITIALIZED :: 0;
        FILE;
        IMPORT;
        FAILED_IMPORT;
        PHASE;
        TYPECHECKED;
        COMPLETE;
        DEBUG_DUMP;
        ERROR;
        PERFORMANCE_REPORT;
    }

    workspace: Workspace;
}

Message_Typechecked :: struct {
    #as using m: Message;

    declarations: [] Typechecked(Code_Declaration);
    procedure_headers: [] Typechecked(Code_Procedure_Header);
    procedure_bodies: [] Typechecked(Code_Procedure_Body);
    structs: [] Typechecked(Code_Struct);
    others: [] Typechecked(Code_Node);
    all: [] Typechecked(Code_Node);
};

// Wraps a node of type T together with the flattened expressions below it.
Typechecked :: struct(T: Type) {
    expression: *T;
    subexpressions: [] *Code_Node;
}

Message_Debug_Dump :: struct {
    #as using m: Message;

    dump_text: string;
};

Message_Performance_Report :: struct {
    #as using m: Message;

    time_report: Time_Report;
    run_directive_report: Run_Directive_Report;
    polymorph_report: Polymorph_Report;
    bytecode_report: Bytecode_Report;
};

// ---------------------------------------------------------------------------
// Syntax nodes
// ---------------------------------------------------------------------------

Time_Report :: struct {
    run_directives: float64;
    bytecode_inlining: float64;
    bytecode_generating: float64;
}

Run_Directive_Report :: struct {
    reported := false;

    Record :: struct {
        callee: *Code_Procedure_Header;
        num_stalls: s64;
        elapsed_time: float64;
    }

    records: [] Record;
}

Polymorph_Report :: struct {
    num_solves_invoked: s64;
    num_solves_used: s64;

    reported := false;

    Record :: struct {
        source: *Code_Procedure_Header;
        num_call_sites: s64;
        num_deduplications_by_constants: s64;
        num_deduplications_by_bytecode: s64;

        distinct_polymorphs: [] Distinct_Polymorph;
    }

    Distinct_Polymorph :: struct {
        polymorphed: *Code_Procedure_Header;
        call_site: *Code_Node;
        location: Source_Code_Location;
    }

    records: [] Record;
}

Bytecode_Report :: struct {
    num_calls_inlined: s64;
    num_calls_total: s64;
    num_instructions_inlined: s64;
    num_instructions_total: s64;
}
