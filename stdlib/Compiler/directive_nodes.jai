// Syntax nodes for the `#` directives (run, import, load, scope and the rest).
// Same plain-data conventions as syntax_nodes.jai.

#scope_export

// ---------------------------------------------------------------------------
// Directive nodes
// ---------------------------------------------------------------------------

Code_Directive_Run :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_RUN;

    procedure: *Code_Procedure_Header;

    flags: enum u32 {
        ASSERTION :: 0x1;
        STALLABLE :: 0x2;
        SYNTACTICALLY_IMPLICIT :: 0x4;
        HAS_IMPLICIT_RETURN_TYPES :: 0x8;
    }

    assertion_string: string;

    // jaic: the operand of `#run x;` / the condition and message of `#assert(x, "m")` in
    // a body, so the directive prints back (`procedure` stays null).
    expression: *Code_Node;
    message: *Code_Node;
}

Code_Directive_Import :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_IMPORT;
    name: string;

    flags: enum u32 {
        UNSHARED :: 0x1;
    }

    import_type: Provided_Import_Type;

    module_parameters_call: *Code_Procedure_Call;
    program_parameters_call: *Code_Procedure_Call;
}

Code_Directive_Bake :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_BAKE;

    procedure_call: *Code_Procedure_Call;

    bake_type: enum u8 {
        CONSTANTS_BAKE :: 0;
        PARAMETER_VALUE_BAKE :: 1;
        DYNAMIC_SPECIALIZE :: 2;
    }
}

Code_Directive_Modify :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_MODIFY;
    block: *Code_Block;
}

Code_Directive_Scope :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_SCOPE;

    scope_type: enum u32 {
        EXPORT :: 0;
        FILE :: 1;
        INTERNAL :: 2;
    }
}

Code_Directive_Module_Parameters :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_MODULE_PARAMETERS;

    module_parameters: *Code_Procedure_Header;
    program_parameters: *Code_Procedure_Header;

    common_code: *Code_Block;
}

Code_Directive_Location :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_LOCATION;

    expression: *Code_Node;

    is_caller_location := false;

    // jaic extension: `#caller_code`.
    is_caller_code := false;
}

Code_Directive_Library :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_LIBRARY;

    name: string;
    library_flags: enum u32 {
        IS_SYSTEM_LIBRARY :: 0x1;
        DYNAMIC_LIBRARY_UNAVAILABLE :: 0x2;
        STATIC_LIBRARY_UNAVAILABLE :: 0x4;
        LINK_ALWAYS :: 0x8;
    }
}

Code_Directive_Load :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_LOAD;

    short_name: string;

    fully_pathed_filename: string;
    loaded_string: string;
    load_flags: s32;
}

Code_Directive_Bytes :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_BYTES;

    expression: *Code_Node;
}

Code_Directive_Code :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_CODE;

    expression: *Code_Node;
    code_flags: enum u32 {
        IMPLICITLY_GENERATED :: 0x1;
        NULL :: 0x2;
        TYPED :: 0x8;
    }
}

Code_Directive_Poke_Name :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_POKE_NAME;
    module_struct: *Code_Struct;
    name: string;
}

Code_Directive_Add_Context :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_ADD_CONTEXT;
    expression: *Code_Node;
}

Code_Directive_Context_Type :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_CONTEXT_TYPE;
}

Code_Directive_Wildcard :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_WILDCARD;

    index: s32 = -1;
}

Code_Directive_Exists :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_EXISTS;

    query_expression: *Code_Node;
    sync_expression: *Code_Node;
}

// `#overlay`: a declaration or `using` laid over a target expression.
Code_Directive_Overlay :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_OVERLAY;

    declaration_or_using: *Code_Node;
    target_expression: *Code_Node;
}

Code_Directive_Insert :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_INSERT;

    expression: *Code_Node;
    scope_redirection: *Code_Node;
    break_replacement: *Code_Node;
    continue_replacement: *Code_Node;
    remove_replacement: *Code_Node;

    expansion: *Code_Node;

    is_internal := false;
}

Code_Directive_Through :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_THROUGH;
}

Code_Directive_Place :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_PLACE;
    ident: *Code_Ident;
}

Code_Directive_Procedure_Name :: struct {
    #as using base: Code_Node;
    base.kind = .DIRECTIVE_PROCEDURE_NAME;
    argument: *Code_Node;
}
