
open Cil_types


let debug_builtins = Kernel.register_category "printer:builtins"

let print_var v =
  not (Cil.is_unused_builtin v) || Kernel.is_debug_key_enabled debug_builtins


type label =
| BegStmt of int
| EndStmt of int
| BegFunc of string
| EndFunc of string
| BegIter of int
| EndIter of int

type fresh_gmp_var =
| Fresh_gmp_var of int (* uid *)
| My_gmp_var of string

type declared_gmp_var =
| Declared_gmp_var of fresh_gmp_var

type initialized_gmp_var =
| Initialized_gmp_var of declared_gmp_var

and gmp_expr = initialized_gmp_var

and ctype_expr = (* distinguer type pointeur/int *)
| Fresh_ctype_var of int (* uid *) * typ
| My_ctype_var of typ * string (* when its name is predefined *)
| Zero | One
| Cst of string
| Gmp_get_ui of gmp_expr
| Gmp_get_si of gmp_expr
| Unop of unop * ctype_expr
| Binop of binop * ctype_expr * ctype_expr
| Pc_dim of ctype_expr
| Malloc of ctype_expr
| Cast of typ * ctype_expr
| Sizeof of typ
| Deref of ctype_expr
| Index of ctype_expr * ctype_expr
| Field of ctype_expr * string
| Of_pred of pred_expr

and pred_expr =
| Fresh_pred_var of int (* uid *)
| True | False
| Cmp of relation * ctype_expr * ctype_expr
| Gmp_cmp of binop * gmp_expr * gmp_expr
| Gmp_cmp_ui of binop * gmp_expr * ctype_expr
| Gmp_cmp_si of binop * gmp_expr * ctype_expr
| Gmp_cmpr of relation * gmp_expr * gmp_expr
| Gmp_cmpr_ui of relation * gmp_expr * ctype_expr
| Gmp_cmpr_si of relation * gmp_expr * ctype_expr
| Lnot of pred_expr
| Land of pred_expr * pred_expr
| Lor of pred_expr * pred_expr

and fragment =
| Gmp_fragment of gmp_expr
| Ctype_fragment of ctype_expr

and instruction =
| Affect of ctype_expr * ctype_expr
| Affect_pred of pred_expr * pred_expr
| Free of ctype_expr
| Pc_to_framac of string
| Pc_exn of string * int
| Ret of ctype_expr
| Gmp_clear of gmp_expr
| Gmp_init of declared_gmp_var
| Gmp_init_set of declared_gmp_var * gmp_expr
| Gmp_init_set_ui of declared_gmp_var * ctype_expr
| Gmp_init_set_si of declared_gmp_var * ctype_expr
| Gmp_init_set_str of declared_gmp_var * string
| Gmp_set of gmp_expr * gmp_expr
| Gmp_abs of gmp_expr * gmp_expr
| Gmp_ui_sub of gmp_expr * ctype_expr * gmp_expr
| Gmp_binop of binop * gmp_expr * gmp_expr * gmp_expr
| Gmp_binop_ui of binop * gmp_expr * gmp_expr * ctype_expr
| Gmp_binop_si of binop * gmp_expr * gmp_expr * ctype_expr

type insertion =
| Instru of instruction
| Decl_gmp_var of fresh_gmp_var
| Decl_ctype_var of ctype_expr
| Decl_pred_var of pred_expr
| If of pred_expr * insertion list * insertion list
| For of instruction option * pred_expr option * instruction option *
    insertion list
| Block of insertion list


class gather_insertions props = object(self)
  inherit Visitor.frama_c_inplace as super

  val insertions : (label, insertion Queue.t) Hashtbl.t = Hashtbl.create 64
  val mutable current_label : label option = None
  val mutable result_varinfo = None
  val mutable current_function = None
  val mutable in_old_term = false
  val mutable in_old_ptr = false
  val mutable bhv_to_reach_cpt = 0
  val mutable visited_globals = []
  val mutable last_gmp_var_id = -1
  val mutable last_ctype_var_id = -1
  val mutable last_pred_var_id = -1

  (* list of (stmtkind * stmt) used for testing reachibility of some stmts *)
  val mutable stmts_to_reach = []

  (* we can only modify the property_status of the properties that have really
     been translated into pathcrawler_assert_exception *)
  val mutable translated_properties = []

  method get_insertions () =
    insertions

  method private insert str =
    let label = Extlib.the current_label in
    try
      Queue.add str (Hashtbl.find insertions label)
    with Not_found ->
      let q = Queue.create() in
      Queue.add str q;
      Hashtbl.add insertions label q

  method private fresh_gmp_var() =
    last_gmp_var_id <- last_gmp_var_id + 1;
    Fresh_gmp_var last_gmp_var_id

  method private decl_gmp_var var =
    Decl_gmp_var var, Declared_gmp_var var

  method private init_gmp_var var =
    Instru(Gmp_init var), Initialized_gmp_var var

  method private init_set_gmp_var var v =
    Instru(Gmp_init_set (var, v)), Initialized_gmp_var var

  method private init_set_si_gmp_var var v =
    Instru(Gmp_init_set_si (var, v)), Initialized_gmp_var var

  method private init_set_ui_gmp_var var v =
    Instru(Gmp_init_set_ui (var, v)), Initialized_gmp_var var

  method private init_set_str_gmp_var var v =
    Instru(Gmp_init_set_str (var, v)), Initialized_gmp_var var

  method private fresh_ctype_var ty =
    last_ctype_var_id <- last_ctype_var_id + 1;
    Fresh_ctype_var (last_ctype_var_id, ty)

  method private fresh_pred_var() =
    last_pred_var_id <- last_pred_var_id + 1;
    Fresh_pred_var last_pred_var_id

  (* unmodified *)
  method private in_current_function vi =
    assert (current_function = None);
    current_function <- Some vi

  (* unmodified *)
  method private out_current_function =
    assert (current_function <> None);
    current_function <- None

  (* getter *)
  method translated_properties() = Sd_utils.no_repeat translated_properties

  method private logic_var v =
    let ret =
      match current_function with
      | Some _ when in_old_term ->
	let prefix =
	  match v.lv_type with
	  | Ctype ty
	      when (Cil.isPointerType ty || Cil.isArrayType ty) && in_old_ptr ->
	    "old_ptr"
	  | _ -> "old"
	in
	begin
	  match v.lv_origin with
	  | Some _ -> prefix ^ "_" ^ v.lv_name
	  | None -> v.lv_name
	end
      | _ -> v.lv_name
    in
    match v.lv_type with
    | Linteger ->
      Gmp_fragment (Initialized_gmp_var(Declared_gmp_var(My_gmp_var ret)))
    | Lreal -> assert false (* TODO: reals *)
    | Ctype ty -> Ctype_fragment (My_ctype_var (ty, ret))
    | _ -> assert false

  method private term t : insertion list * fragment =
    self#term_node t

  method private gmp_fragment = function
  | Gmp_fragment x -> x
  | Ctype_fragment _ -> assert false

  method private ctype_fragment = function
  | Ctype_fragment x -> x
  | Gmp_fragment _ -> assert false

  method private lambda li lower upper q t =
    assert(lower.term_type = Linteger && upper.term_type = Linteger);
    let name = li.l_var_info.lv_name in
    let init_val = if name = "\\sum" || name = "\\numof" then Zero else One in
    let fresh_var = self#fresh_gmp_var() in
    let i_0, decl_var = self#decl_gmp_var fresh_var in
    let i_1, init_var = self#init_set_si_gmp_var decl_var init_val in
    let i_3, low = self#term lower in
    let i_4, up = self#term upper in
    let low = self#gmp_fragment low in
    let up = self#gmp_fragment up in
    let fresh_iter = My_gmp_var q.lv_name in
    let i_5, decl_iter = self#decl_gmp_var fresh_iter in
    let i_6, init_iter = self#init_set_gmp_var decl_iter low in
    let ins_b_0, lambda_t = self#term t in
    let ins_b_1, clear_lambda =
      match name with
      | s when s = "\\sum" ->
	Instru(Gmp_binop(PlusA,init_var,init_var, self#gmp_fragment lambda_t)),
	[(Instru(Gmp_clear(self#gmp_fragment lambda_t)))]
      | s when s = "\\product" ->
	Instru(Gmp_binop(Mult, init_var, init_var, self#gmp_fragment lambda_t)),
	[(Instru(Gmp_clear(self#gmp_fragment lambda_t)))]
      | s when s = "\\numof" ->
	(* lambda_t of type: Ltype(lt,_) when lt.lt_name = Utf8_logic.boolean *)
	let cond = Cmp(Rneq, self#ctype_fragment lambda_t, Zero) in
	let instr = Instru(Gmp_binop_ui(PlusA, init_var, init_var, One)) in
	If(cond, [instr], []), []
      | _ -> assert false
    in
    let ins_b_2 = Instru(Gmp_binop_ui(PlusA,init_iter,init_iter,One)) in
    let ins_b = ins_b_0 @ [ins_b_1; ins_b_2] @ clear_lambda in
    let cond = Gmp_cmp(Le,init_iter,up) in
    let i_7 = For(None, Some cond, None, ins_b) in
    let i_8 = Instru(Gmp_clear init_iter) in
    let i_9 = Instru(Gmp_clear low) in
    let i_10 = Instru(Gmp_clear up) in
    let inserts_block = i_3 @ i_4 @ [i_5; i_6; i_7; i_8; i_9; i_10] in
    [i_0; i_1; Block inserts_block], Gmp_fragment init_var

  method private term_node t =
    let ty = match t.term_type with
      | Ctype c -> Ctype (Cil.unrollType c)
      | x -> x
    in
    match t.term_node with

    | TConst _ ->
      begin
	match ty with
	| Linteger ->
	  let fresh_var = self#fresh_gmp_var() in
	  let insert_0, decl_var = self#decl_gmp_var fresh_var in
	  let str = Pretty_utils.sfprintf "%a" Printer.pp_term t in
	  let insert_1, init_var = self#init_set_str_gmp_var decl_var str in
	  [insert_0; insert_1], Gmp_fragment init_var
	| Lreal -> assert false (* TODO: reals *)
	| _ ->
	  [], Ctype_fragment(Cst(Pretty_utils.sfprintf "%a" Printer.pp_term t))
      end

    | TLval tlval ->
      begin
	match ty with
	| Linteger ->
	  let fresh_var = self#fresh_gmp_var() in
	  let inserts_0, t' = self#tlval tlval in
	  let t' = self#gmp_fragment t' in
	  let insert_1, decl_var = self#decl_gmp_var fresh_var in
	  let insert_2, init_var = self#init_set_gmp_var decl_var t' in
	  inserts_0 @ [insert_1; insert_2], Gmp_fragment init_var
	| Lreal -> assert false (* TODO: reals *)
	| _ -> self#tlval tlval
      end

    | TSizeOf _
    | TSizeOfE _
    | TSizeOfStr _
    | TAlignOf _
    | TAlignOfE _ ->
      assert false (* TODO ? *)

    | TUnOp(op, t') ->
      begin
	match ty with
	| Linteger ->
	  assert(op = Neg);
	  let inserts_0, x = self#term t' in
	  let fresh_var = self#fresh_gmp_var() in
	  let insert_1, decl_var = self#decl_gmp_var fresh_var in
	  let insert_2, init_var = self#init_gmp_var decl_var in
	  let inserts_3 =
	    match t'.term_type with
	    | Linteger ->
	      [Instru(Gmp_ui_sub(init_var,Zero,self#gmp_fragment x));
	       Instru(Gmp_clear(self#gmp_fragment x))]
	    | Lreal -> assert false (* unreachable *)
	    | Ctype ty' ->
	      let fresh_var' = self#fresh_gmp_var() in
	      let insert_0', decl_var' = self#decl_gmp_var fresh_var' in
	      let f =
		if Cil.isUnsignedInteger ty' then self#init_set_ui_gmp_var
		else if Cil.isSignedInteger ty' then self#init_set_si_gmp_var
		else assert false
	      in
	      let insert_1', init_var' = f decl_var' (self#ctype_fragment x) in
	      let insert_2' = Instru(Gmp_ui_sub(init_var', Zero, init_var')) in
	      let insert_3' = Instru(Gmp_clear init_var') in
	      [insert_0'; insert_1'; insert_2'; insert_3']
	    | _ -> assert false (* unreachable *)
	  in
	  inserts_0 @ [insert_1; insert_2] @ inserts_3, Gmp_fragment init_var
	| Lreal -> assert false (* TODO: reals *)
	| _ ->
	  let inserts, x = self#term t' in
	  inserts, Ctype_fragment (Unop(op, self#ctype_fragment x))
      end

    | TBinOp((IndexPI|PlusPI|MinusPI) as op, t1, t2) ->
      let inserts_0, x = self#term t1 in
      let x = self#ctype_fragment x in
      let inserts_1, y = self#term t2 in
      let inserts, var =
	match t2.term_type with
	| Linteger ->
	  let y = self#gmp_fragment y in
	  let var = self#fresh_ctype_var Cil.intType in
	  let insert_2 = Decl_ctype_var var in
	  let insert_3 = Instru(Affect(var, Gmp_get_si y)) in
	  let insert_4 = Instru(Gmp_clear y) in
	  [insert_2; insert_3; insert_4], var
	| Lreal -> assert false (* unreachable *)
	| _ -> [], self#ctype_fragment y
      in
      inserts_0 @ inserts_1 @ inserts, Ctype_fragment (Binop(op, x, var))

    | TBinOp(op, t1, t2) ->
      let inserts_0, x = self#term t1 in
      let inserts_1, y = self#term t2 in
      begin
	match ty with
	| Linteger ->
	  let fresh_var = self#fresh_gmp_var() in
	  let insert_2, decl_var = self#decl_gmp_var fresh_var in
	  let insert_3, init_var = self#init_gmp_var decl_var in
	  let clear_t1 = match t1.term_type with
	    Linteger -> [Instru(Gmp_clear (self#gmp_fragment x))] | _ -> []
	  in
	  let clear_t2 = match t2.term_type with
	    Linteger -> [Instru(Gmp_clear (self#gmp_fragment y))] | _ -> []
	  in
	  let inserts =
	    match t1.term_type, t2.term_type with
	    | Linteger, Linteger ->
	      let x = self#gmp_fragment x and y = self#gmp_fragment y in
	      [Instru(Gmp_binop(op, init_var, x, y))]
	    | Linteger, Ctype ty' when Cil.isUnsignedInteger ty' ->
	      let x = self#gmp_fragment x and y = self#ctype_fragment y in
	      [Instru(Gmp_binop_ui(op, init_var, x, y))]
	    | Linteger, Ctype ty' when Cil.isSignedInteger ty' ->
	      let x = self#gmp_fragment x and y = self#ctype_fragment y in
	      [Instru(Gmp_binop_si(op, init_var, x, y))]
	    | Ctype ty', Linteger when Cil.isUnsignedInteger ty' ->
	      if op = PlusA || op = Mult then
		let x = self#ctype_fragment x and y = self#gmp_fragment y in
	        [Instru(Gmp_binop_ui(op,init_var,y,x))]
	      else
		assert false (* TODO *)
	    | Ctype ty', Linteger when Cil.isSignedInteger ty' ->
	      if op = PlusA || op = Mult then
		let x = self#ctype_fragment x and y = self#gmp_fragment y in
	        [Instru(Gmp_binop_si(op, init_var,y,x))]
	      else
		assert false (* TODO *)
	    | Ctype(TInt _), Ctype(TInt _) ->
	      let fresh_var1 = self#fresh_gmp_var() in
	      let insert_4, decl_var1 = self#decl_gmp_var fresh_var1 in
	      let fresh_var2 = self#fresh_gmp_var() in
	      let insert_5, decl_var2 = self#decl_gmp_var fresh_var2 in
	      let insert_6, init_var1 =
		self#init_set_si_gmp_var decl_var1 (self#ctype_fragment x) in
	      let insert_7, init_var2 =
		self#init_set_si_gmp_var decl_var2 (self#ctype_fragment y) in
	      [insert_4; insert_5; insert_6; insert_7;
	       Instru(Gmp_binop(op,init_var,init_var1,init_var2));
	       Instru(Gmp_clear init_var1);
	       Instru(Gmp_clear init_var2)]
	    | _ -> assert false
	  in
	  inserts_0 @ inserts_1 @ [insert_2; insert_3] @ inserts
	  @ clear_t1 @ clear_t2,
	  Gmp_fragment init_var
	| Lreal -> assert false (* TODO: reals *)
	| Ltype (lt,_) when lt.lt_name = Utf8_logic.boolean ->
	  begin
	    match t1.term_type, t2.term_type with
	    | Linteger, Linteger ->
	      let var = self#fresh_ctype_var Cil.intType in
	      let insert_2 = Decl_ctype_var var in
	      let pred = Gmp_cmp(op, self#gmp_fragment x,self#gmp_fragment y) in
	      let insert_3 = Instru(Affect(var, Of_pred pred)) in
	      let insert_4 = Instru(Gmp_clear(self#gmp_fragment x)) in
	      let insert_5 = Instru(Gmp_clear(self#gmp_fragment y)) in
	      inserts_0 @ inserts_1 @ [insert_2; insert_3; insert_4; insert_5],
	      Ctype_fragment var
	    | _ ->
	      let x = self#ctype_fragment x and y = self#ctype_fragment y in
	      inserts_0 @ inserts_1, Ctype_fragment (Binop(op, x, y))
	  end
	| _ -> assert false (* unreachable ? *)
      end

    | TCastE (ty', t') ->
      begin
	match t'.term_type with (* source type *)
	| Linteger ->
	  let inserts_0, v = self#term t' in
	  let v = self#gmp_fragment v in
	  let var = self#fresh_ctype_var ty' in
	  let insert_1 = Decl_ctype_var var in
	  let value =
	    match ty with (* dest type *)
	    | Ctype x when Cil.isUnsignedInteger x -> Gmp_get_ui v
	    | Ctype x when Cil.isSignedInteger x -> Gmp_get_si v
	    | _ -> assert false (* unreachable *)
	  in
	  let insert_2 = Instru(Affect(var, value)) in
	  let insert_3 = Instru(Gmp_clear v) in
	  inserts_0 @ [insert_1; insert_2; insert_3], Ctype_fragment var
	| Lreal -> assert false (* reals *)
	| Ctype _ ->
	  let inserts_0, v = self#term t' in
	  inserts_0, Ctype_fragment (Cast (ty', self#ctype_fragment v))
	| _ -> assert false (* unreachable *)
      end

    | TAddrOf _
    | TStartOf _ ->
      assert false (* TODO ? *)

    | Tapp (li, _ (* already substituted *), params) ->
      let builtin_name = li.l_var_info.lv_name in
      begin
	match ty with
	| Linteger ->
	  if builtin_name = "\\abs" then
	    begin
	      let param = List.hd params in
	      assert (List.tl params = []);
	      let inserts_0, x = self#term param in
	      let x = self#gmp_fragment x in
	      let fresh_var = self#fresh_gmp_var() in
	      let insert_1, decl_var = self#decl_gmp_var fresh_var in
	      let insert_2, init_var = self#init_gmp_var decl_var in
	      let insert_3 = Instru(Gmp_abs(init_var, x)) in
	      let insert_4 = Instru(Gmp_clear x) in
	      inserts_0 @ [insert_1; insert_2; insert_3; insert_4],
	      Gmp_fragment init_var
	    end
	  else
	    if builtin_name = "\\sum" || builtin_name = "\\product" ||
	      builtin_name = "\\numof" then
	      match params with
	      | [l;u;{term_node=Tlambda([q],t)}] -> self#lambda li l u q t
	      | _ -> assert false
	    else
	      assert false
	| Lreal -> assert false (* TODO: reals *)
	| _ -> assert false (* unreachable *)
      end

    | Tlambda _ -> assert false (* unreachable *)
    | TDataCons _ -> Sd_options.Self.not_yet_implemented "TDataCons"
    
    | Tif (cond, then_b, else_b) -> (* untested *)
      begin
	match ty with
	| Linteger ->
	  let fresh_var = self#fresh_gmp_var() in
	  let insert_0, decl_var = self#decl_gmp_var fresh_var in
	  let insert_1, init_var = self#init_gmp_var decl_var in
	  let inserts_2, cond' = self#term cond in
	  let cond' = self#gmp_fragment cond' in
	  let cond'' = Gmp_cmp_si(Ne, cond', Zero) in
	  let inserts_then =
	    let inserts_then_0, then_b' = self#term then_b in
	    let then_b' = self#gmp_fragment then_b' in
	    inserts_then_0
	    @ [Instru(Gmp_set(init_var, then_b')); Instru(Gmp_clear then_b')]
	  in
	  let inserts_else =
	    let inserts_else_0, else_b' = self#term else_b in
	    let else_b' = self#gmp_fragment else_b' in
	    inserts_else_0
	    @ [Instru(Gmp_set(init_var, else_b')); Instru(Gmp_clear else_b')]
	  in
	  let insert_3 = If(cond'', inserts_then, inserts_else) in
	  let insert_4 = Instru(Gmp_clear cond') in
	  [insert_0; insert_1] @ inserts_2 @ [insert_3; insert_4],
	  Gmp_fragment init_var
	| Lreal -> assert false (* TODO: reals *)
	| _ -> assert false (* unreachable *)
      end
    
    | Tat(_, StmtLabel _) ->
      if current_function <> None then
	Sd_options.Self.warning "%a unsupported" Printer.pp_term t;
      assert false (* TODO ? *)

    | Tat(term,LogicLabel(_,stringlabel)) ->
      if stringlabel = "Old" || stringlabel = "Pre" then
	let is_ptr =
	  match term.term_node with TLval(TMem _,_) -> true | _ -> false in
	if is_ptr then in_old_ptr <- true;
	in_old_term <- true;
	let v = self#term term in
	if is_ptr then in_old_ptr <- false;
	in_old_term <- false;
	v
      else
	(* label Post is only encoutered in post-conditions, and \at(t,Post)
	   in a post-condition is t *)
	if stringlabel = "Post" || stringlabel = "Here" then
	  self#term term
	else
	  begin
	    if current_function <> None then
	      Sd_options.Self.warning "%a unsupported" Printer.pp_term t;
	    assert false (* TODO ? *)
	  end

    | Tbase_addr _ -> Sd_options.Self.not_yet_implemented "Tbase_addr"
    | Toffset _ -> Sd_options.Self.not_yet_implemented "Toffset"
    | Tblock_length _ -> Sd_options.Self.not_yet_implemented "Tblock_length"
    | Tnull -> [], Ctype_fragment Zero

    (* C type -> logic type *)
    | TLogic_coerce (_, t')
    | TCoerceE (t', {term_type=(Linteger|Lreal)}) ->
      begin
	match ty with
	| Linteger ->
	  let ty' =
	    match t'.term_type with
	    | Ctype x -> Ctype (Cil.unrollType x)
	    | x -> x
	  in
	  let inserts_0, v = self#term t' in
	  let v = self#ctype_fragment v in
	  let fresh_var = self#fresh_gmp_var() in
	  let insert_1, decl_var = self#decl_gmp_var fresh_var in
	  let init_set =
	    match ty' with
	    | Ctype x when Cil.isUnsignedInteger x -> self#init_set_ui_gmp_var
	    | Ctype x when Cil.isSignedInteger x -> self#init_set_si_gmp_var
	    | _ -> assert false
	  in
	  let insert_2, init_var = init_set decl_var v in
	  inserts_0 @ [insert_1; insert_2], Gmp_fragment init_var
	| Lreal -> assert false (* TODO: reals *)
	| _ -> assert false (* unreachable *)
      end

    (* logic type -> C type *)
    | TCoerce (t', ty')
    | TCoerceE (t', {term_type=Ctype ty'}) ->
      begin
	match t'.term_type with
	| Linteger ->
	  let inserts_0, v = self#term t' in
	  let v = self#gmp_fragment v in
	  let var = self#fresh_ctype_var ty' in
	  let insert_1 = Decl_ctype_var var in
	  let value =
	    match ty' with
	    | x when Cil.isUnsignedInteger x -> Gmp_get_ui v
	    | x when Cil.isSignedInteger x -> Gmp_get_si v
	    | _ -> assert false
	  in
	  let insert_2 = Instru(Affect(var,value)) in
	  let insert_3 = Instru(Gmp_clear v) in
	  inserts_0 @ [insert_1; insert_2; insert_3], Ctype_fragment var
	| Lreal -> assert false (* TODO: reals *)
	| _ -> assert false (* unreachable *)
      end

    | TCoerceE _ -> Sd_options.Self.not_yet_implemented "TCoerceE"
    | TUpdate _ -> Sd_options.Self.not_yet_implemented "TUpdate"
    | Ttypeof _ -> Sd_options.Self.not_yet_implemented "Ttypeof"
    | Ttype _ -> Sd_options.Self.not_yet_implemented "Ttype"
    | Tempty_set -> Sd_options.Self.not_yet_implemented "Tempty_set"
    | Tunion _ -> Sd_options.Self.not_yet_implemented "Tunion"
    | Tinter _ -> Sd_options.Self.not_yet_implemented "Tinter"
    | Tcomprehension _ -> Sd_options.Self.not_yet_implemented "Tcomprehension"
    | Trange _ -> assert false (* unreachable *)
    | Tlet _ -> assert false (* unreachable *)
  (* end term *)

  method private tlval (tlhost, toffset) =
    match tlhost with
    | TResult _ ->
      let var = Extlib.the result_varinfo in
      [], Ctype_fragment (My_ctype_var(var.vtype, var.vname))
    | _ ->
      let inserts_0, lhost = self#tlhost tlhost in
      let rec aux insertions ret = function
	| TNoOffset -> insertions, ret
	| TField (fi, tof) -> aux insertions (Field(ret, fi.fname)) tof
	| TModel _ -> assert false (* TODO *)
	| TIndex (t, tof) ->
	  let inserts_1, t' = self#term t in
	  begin
	    match t.term_type with
	    | Linteger ->
	      aux (insertions @ inserts_1)
		(Index(ret, Gmp_get_si(self#gmp_fragment t'))) tof
	    | Lreal -> assert false (* unreachable *)
	    | _ -> aux insertions (Index(ret, self#ctype_fragment t')) tof
	  end
      in
      match lhost with
      | Gmp_fragment _ -> (* TODO *)
	assert (toffset = TNoOffset);
	inserts_0, lhost
      | Ctype_fragment lhost' ->
	let insertions, ret = aux inserts_0 lhost' toffset in
	insertions, Ctype_fragment ret

  method private tlhost lhost =
    match lhost with
    | TVar lv -> [], self#logic_var lv
    | TResult _ -> assert false
    | TMem t ->
      let inserts_0, t' = self#term t in
      inserts_0, Ctype_fragment (Deref (self#ctype_fragment t'))

  (* modify result_varinfo when the function returns something *)
  method private compute_result_varinfo fct =
    let rec do_stmts = function
      | [] -> ()
      | {skind=Return(Some{enode=Lval(Var v,_)},_)}::_ -> result_varinfo<-Some v
      | _ :: t -> do_stmts t
    in
    do_stmts fct.sallstmts

  method private at_least_one_prop kf behaviors kloc =
    let in_ensures b r k =
      r || (List.mem (Property.ip_of_ensures kf kloc b k) props) in
    let in_bhv r b = r || List.fold_left (in_ensures b) false b.b_post_cond in
    List.fold_left in_bhv false behaviors

  method private requires kf behaviors kloc =
    let do_behavior b =
      let pre = b.b_requires in
      let to_prop = Property.ip_of_requires kf kloc b in
      let pre = List.filter (fun p -> List.mem (to_prop p) props) pre in
      let do_precond pred =
	let prop = to_prop pred in
	let id = Sd_utils.to_id prop in
	self#pc_assert_exception pred.ip_content "Pre-condition!" id prop
      in
      if pre <> [] then
	if b.b_assumes <> [] then
	  let inserts_0, exp = self#cond_of_assumes b.b_assumes in
	  let inserts_t = List.fold_left (@) [] (List.map do_precond pre) in
	  let insert_1 = If(exp, inserts_t, []) in
	  inserts_0 @ [insert_1]
	else
	  List.fold_left (@) [] (List.map do_precond pre)
      else
	[]
    in
    List.fold_left (@) [] (List.map do_behavior behaviors)

  method private ensures kf behaviors kloc =
    let do_behavior b =
      let post = b.b_post_cond in
      let to_prop = Property.ip_of_ensures kf kloc b in
      let post = List.filter (fun x->List.mem (to_prop x) props) post in
      let do_postcond (tk,pred) =
	let prop = to_prop (tk,pred) in
	let id = Sd_utils.to_id prop in
	self#pc_assert_exception pred.ip_content "Post-condition!" id prop
      in
      let str = Format.sprintf "@@FC:REACHABLE_BHV:%i" bhv_to_reach_cpt in
      let add_reach_info =
	not (Cil.is_default_behavior b)
	&& (Sd_options.Behavior_Reachability.get())
      in
      if post <> [] || (Sd_options.Behavior_Reachability.get()) then
	begin
	  if b.b_assumes <> [] then
	    let inserts_0, exp = self#cond_of_assumes b.b_assumes in
	    let inserts_then_0 =
	      if add_reach_info then
		begin
		  Sd_states.Behavior_Reachability.replace
		    bhv_to_reach_cpt (kf, b, false);
		  bhv_to_reach_cpt <- bhv_to_reach_cpt+1;
		  [Instru(Pc_to_framac str)]
		end
	      else
		[]
	    in
	    let inserts_then_1 =
	      List.fold_left (@) [] (List.map do_postcond post) in
	    let insert_1 = If(exp, inserts_then_0 @ inserts_then_1, []) in
	    inserts_0 @ [insert_1]
	  else
	    let inserts_0 = 
	      if add_reach_info then
		begin
		  Sd_states.Behavior_Reachability.replace
		    bhv_to_reach_cpt (kf, b, false);
		  bhv_to_reach_cpt <- bhv_to_reach_cpt+1;
		  [Instru(Pc_to_framac str)]
		end
	      else
		[]
	    in
	    let inserts_1 =
	      List.fold_left (@) [] (List.map do_postcond post) in
	    inserts_0 @ inserts_1
	end
      else
	[]
    in
    List.fold_left (@) [] (List.map do_behavior behaviors)

  method! vfunc f =
    let entry_point = Kernel_function.get_name (fst(Globals.entry_point())) in
    let kf = Globals.Functions.find_by_name f.svar.vname in
    let behaviors = Annotations.behaviors kf in
    self#compute_result_varinfo f;

    (* BEGIN precond (entry-point) *)
    if f.svar.vname = entry_point then
      begin
	current_label <- Some (BegFunc (f.svar.vname ^ "_precond"));
	List.iter (fun b ->
	  let preconds =
	    List.rev_append (List.rev (Sd_utils.typically_preds b)) b.b_requires
	  in
	  let not_translated p =
	    Sd_states.Not_Translated_Predicates.fold_left
	      (fun b e -> b || e = p.ip_id) false
	  in
	  let preconds = List.filter not_translated preconds in
	  let do_precond p =
	    let inserts, v = self#predicate(self#subst_pred p.ip_content) in
	    if v <> True then (* untreated predicates are translated as True *)
	      inserts @ [If(Lnot v, [Instru(Ret Zero)], [])]
	    else
	      inserts
	  in
	  if preconds <> [] then
	    if b.b_assumes <> [] then
	      let inserts_0, exp = self#cond_of_assumes b.b_assumes in
	      let inserts_then =
		List.fold_left (@) [] (List.map do_precond preconds) in
	      let insert_1 = If(exp, inserts_then, []) in
	      let inserts = inserts_0 @ [insert_1] in
	      List.iter self#insert inserts
	    else
	      let inserts =
		List.fold_left (@) [] (List.map do_precond preconds) in
	      List.iter self#insert inserts
	) behaviors;
      end
    (* END precond (entry-point) *)
    (* BEGIN precond (not entry-point) *)
    else
      begin
	current_label <- Some (BegFunc f.svar.vname);
	let inserts = self#requires kf behaviors Kglobal in
	List.iter self#insert inserts
      end;
    (* END precond (not entry-point) *)

    current_label <- Some (EndFunc f.svar.vname);

    (* BEGIN postcond *)
    if (self#at_least_one_prop kf behaviors Kglobal)
      || (Sd_options.Behavior_Reachability.get()) then
      begin
	let inserts = self#ensures kf behaviors Kglobal in
	self#insert (Block inserts)
      end;
    (* END postcond *)

    current_label <- Some (BegFunc f.svar.vname);

    (* alloc variables for \at terms *)
    let dig_type = function
      | TPtr(ty,_) | TArray(ty,_,_,_) -> ty
      | ty -> Sd_options.Self.abort "dig_type %a" Printer.pp_typ ty
    in
    let dig_type x = dig_type (Cil.unrollTypeDeep x) in
    let lengths = Sd_utils.lengths_from_requires kf in
    let do_varinfo v =
      let terms =
	try Cil_datatype.Varinfo.Hashtbl.find lengths v
	with Not_found -> []
      in
      let my_v = My_ctype_var(v.vtype, v.vname) in
      let my_old_v = My_ctype_var(v.vtype, "old_"^v.vname) in
      self#insert (Decl_ctype_var my_old_v);
      self#insert (Instru(Affect(my_old_v, my_v)));
      let rec alloc_aux my_old_ptr my_ptr ty = function
	| h :: t ->
	  let ty = dig_type ty in
	  let inserts_0, h' = self#term h in
	  let my_iterator = self#fresh_ctype_var Cil.intType in
	  let insert_1 = Decl_ctype_var my_iterator in
	  begin
	    match h.term_type with
	    | Linteger ->
	      let h' = self#gmp_fragment h' in
	      let malloc = Malloc(Binop(Mult,(Gmp_get_si h'), Sizeof ty)) in
	      let insert_2 = Instru(Affect(my_old_ptr, malloc)) in
	      let my_new_old_ptr = Index(my_old_ptr, my_iterator) in
	      let my_new_ptr = Index(my_ptr, my_iterator) in
	      let inserts_block = alloc_aux my_new_old_ptr my_new_ptr ty t in
	      let init = Affect(my_iterator, Zero) in
	      let cond = Cmp(Rlt, my_iterator, Gmp_get_si h') in
	      let step = Affect(my_iterator, (Binop(PlusA, my_iterator,One))) in
	      let insert_3 = For(Some init,Some cond,Some step,inserts_block) in
	      let insert_4 = Instru(Gmp_clear h') in
	      inserts_0 @ [insert_1; insert_2; insert_3; insert_4]
	    | Lreal -> assert false (* TODO: reals *)
	    | _ ->
	      let h' = self#ctype_fragment h' in
	      let insert_2 =
		Instru(Affect(my_old_ptr, Malloc(Binop(Mult,h', Sizeof ty)))) in
	      let my_new_old_ptr = Index(my_old_ptr, my_iterator) in
	      let my_new_ptr = Index(my_ptr, my_iterator) in
	      let inserts_block = alloc_aux my_new_old_ptr my_new_ptr ty t in
	      let init = Affect(my_iterator, Zero) in
	      let cond = Cmp(Rlt, my_iterator, h') in
	      let step = Affect(my_iterator, (Binop(PlusA, my_iterator,One))) in
	      let insert_3 = For(Some init,Some cond,Some step,inserts_block) in
	      inserts_0 @ [insert_1; insert_2; insert_3]
	  end
	| [] -> [Instru(Affect(my_old_ptr, my_ptr))]
      in
      if Cil.isPointerType v.vtype || Cil.isArrayType v.vtype then
	begin
	  let my_old_ptr = My_ctype_var(v.vtype, "old_ptr_"^v.vname) in
	  self#insert (Decl_ctype_var my_old_ptr);
	  let inserts = alloc_aux my_old_ptr my_v v.vtype terms in
	  List.iter self#insert inserts;
	end
    in
    List.iter do_varinfo visited_globals;
    List.iter do_varinfo (Kernel_function.get_formals kf);

    current_label <- Some (EndFunc f.svar.vname);

    (* dealloc variables for \at terms *)
    begin
      let lengths = Sd_utils.lengths_from_requires kf in
      let do_varinfo v =
	let terms =
	  try Cil_datatype.Varinfo.Hashtbl.find lengths v
	  with Not_found -> []
	in
	let rec dealloc_aux my_old_ptr = function
	  | [] -> []
	  | _ :: [] -> [Instru(Free my_old_ptr)]
	  | h :: t ->
	    let my_iterator = self#fresh_ctype_var Cil.intType in
	    let insert_0 = Decl_ctype_var my_iterator in
	    let inserts_1, h' = self#term h in
	    let inserts' =
	      match h.term_type with
	      | Linteger ->
		let h' = self#gmp_fragment h' in
		let inserts_block=dealloc_aux(Index(my_old_ptr,my_iterator))t in
		let init = Affect(my_iterator, Zero) in
		let cond = Cmp(Rlt, my_iterator, Gmp_get_si h') in
		let step = Affect(my_iterator,(Binop(PlusA,my_iterator,One))) in
		let insert_2=For(Some init,Some cond,Some step,inserts_block) in
		let insert_3 = Instru(Gmp_clear h') in
		[insert_2; insert_3]
	      | Lreal -> assert false (* TODO: reals *)
	      | _ ->
		let h' = self#ctype_fragment h' in
		let inserts_block=dealloc_aux(Index(my_old_ptr,my_iterator))t in
		let init = Affect(my_iterator, Zero) in
		let cond = Cmp(Rlt, my_iterator, h') in
		let step = Affect(my_iterator,(Binop(PlusA,my_iterator,One))) in
		let insert_2=For(Some init,Some cond,Some step,inserts_block) in
		[insert_2]
	    in
	    [insert_0] @ inserts_1 @ inserts' @ [Instru(Free(my_old_ptr))]
	in
	let my_old_ptr = My_ctype_var(Cil.voidPtrType, "old_ptr_"^v.vname) in
	let insertions = dealloc_aux my_old_ptr terms in
	List.iter self#insert insertions
      in
      List.iter do_varinfo visited_globals;
      List.iter do_varinfo (Kernel_function.get_formals kf)
    end;

    current_label <- None;

    Cil.DoChildren
  (* end vfunc *)

  method private subst_pred p = (new Sd_subst.subst)#subst_pred p [] [] [] []

  method private cond_of_assumes pred_list =
    let rec aux insertions ret = function
      | [] -> insertions, ret
      | h :: t ->
	let ins, v = self#predicate (self#subst_pred h.ip_content) in
	aux (insertions @ ins) (Land(ret, v)) t
    in
    aux [] True pred_list

  method private cond_of_behaviors pred_lists =
    let rec aux insertions ret = function
      | [] -> insertions, ret
      | h :: t ->
	let ins, v = self#cond_of_assumes h in
	aux (insertions @ ins) (Lor(ret, v)) t
      in
    aux [] False pred_lists

  method private pc_assert_exception pred msg id prop =
    let inserts_0, var = self#predicate (self#subst_pred pred) in
    let insert_1 = If(Lnot var, [Instru(Pc_exn(msg, id))], []) in
    translated_properties <- prop :: translated_properties;
    inserts_0 @ [insert_1]

  method! vcode_annot ca =
    let stmt = Extlib.the self#current_stmt in
    let kf = Kernel_function.find_englobing_kf stmt in
    let bhv_names =
      match ca.annot_content with
      | AAssert (b,_) | AStmtSpec (b,_) | AInvariant (b,_,_) -> b
      | _ -> []
    in
    let on_behavior s _ b ret = if b.b_name = s then b.b_assumes else ret in
    let on_behavior_name s = Annotations.fold_behaviors (on_behavior s) kf [] in
    let for_behaviors = List.map on_behavior_name bhv_names in
    begin
      match ca.annot_content with
      | AStmtSpec (_,bhvs) ->

	if (self#at_least_one_prop kf bhvs.spec_behavior (Kstmt stmt))
	  || (Sd_options.Behavior_Reachability.get()) then
	  begin
	    let stmt_behaviors = bhvs.spec_behavior in

	    current_label <- Some (BegStmt stmt.sid);

	    let inserts' = self#requires kf stmt_behaviors (Kstmt stmt) in
	    if for_behaviors <> [] then
	      let inserts_0, cond = self#cond_of_behaviors for_behaviors in
	      let insert_1 = If(cond, inserts', []) in
	      let inserts = inserts_0 @ [insert_1] in
	      List.iter self#insert inserts
	    else
	      List.iter self#insert inserts';

	    current_label <- Some (EndStmt stmt.sid);

	    let inserts' = self#ensures kf stmt_behaviors (Kstmt stmt) in
	    if for_behaviors <> [] then
	      let inserts_0, cond = self#cond_of_behaviors for_behaviors in
	      let insert_1 = If(cond, inserts', []) in
	      let inserts = inserts_0 @ [insert_1] in
	      List.iter self#insert inserts
	    else
	      self#insert (Block inserts');

	    current_label <- None
	  end

      | AAssert (_,pred) ->

	current_label <- Some (BegStmt stmt.sid);

	let prop = Property.ip_of_code_annot_single kf stmt ca in
	if List.mem prop props then
	  begin
	    let id = Sd_utils.to_id prop in
	    if for_behaviors <> [] then
	      let inserts_0, cond = self#cond_of_behaviors for_behaviors in
	      let inserts_then =
		self#pc_assert_exception pred.content "Assert!" id prop in
	      let insert_1 = If(cond, inserts_then, []) in
	      let inserts = inserts_0 @ [insert_1] in
	      List.iter self#insert inserts
	    else
	      let ins =
		self#pc_assert_exception pred.content "Assert!" id prop in
	      List.iter self#insert ins
	  end;

	current_label <- None

      | AInvariant (_,true,pred) ->

	let prop = Property.ip_of_code_annot_single kf stmt ca in
	if List.mem prop props then
	  let id = Sd_utils.to_id prop in
	  let f msg =
	    if for_behaviors <> [] then
	      let inserts_0, cond = self#cond_of_behaviors for_behaviors in
	      let inserts_then =
		self#pc_assert_exception pred.content msg id prop in
	      let insert_1 = If(cond, inserts_then, []) in
	      let inserts = inserts_0 @ [insert_1] in
	      List.iter self#insert inserts
	    else
	      let ins = self#pc_assert_exception pred.content msg id prop in
	      List.iter self#insert ins
	  in
	  current_label <- Some (BegStmt stmt.sid);
	  f "Loop invariant not established!";
	  current_label <- Some (EndIter stmt.sid);
	  f "Loop invariant not preserved!";
	  current_label <- None

      | AVariant (term,_) ->

	let prop = Property.ip_of_code_annot_single kf stmt ca in
	if List.mem prop props then
	  let id = Sd_utils.to_id prop in
	  begin
	    match term.term_type with
	    | Linteger ->
	      current_label <- Some (BegStmt stmt.sid);
	      let inserts_0, term' = self#term term in
	      List.iter self#insert inserts_0;
	      let term' = self#gmp_fragment term' in
	      let cond = Gmp_cmp_ui(Lt, term', Zero) in
	      let instr = Instru(Pc_exn("Variant non positive", id)) in
	      self#insert (If (cond, [instr], []));
	      current_label <- Some (EndStmt stmt.sid);
	      self#insert (Instru(Gmp_clear term'));
	      current_label <- Some (BegIter stmt.sid);
	      let inserts_1, term' = self#term term in
	      List.iter self#insert inserts_1;
	      let term' = self#gmp_fragment term' in
	      let fresh_variant = self#fresh_gmp_var() in
	      let insert_2, decl_variant = self#decl_gmp_var fresh_variant in
	      self#insert insert_2;
	      let insert_3, init_variant =
		self#init_set_gmp_var decl_variant term' in
	      self#insert insert_3;
	      current_label <- Some (EndIter stmt.sid);
	      let inserts_4, term' = self#term term in
	      List.iter self#insert inserts_4;
	      let term' = self#gmp_fragment term' in
	      let cond = Gmp_cmp_ui(Lt, init_variant, Zero) in
	      let instr = Instru(Pc_exn("Variant non positive", id)) in
	      self#insert (If(cond, [instr], []));
	      let cond = Gmp_cmp(Ge, term', init_variant) in
	      let instr = Instru(Pc_exn("Variant non decreasing", id)) in
	      self#insert (If(cond, [instr] ,[]));
	      self#insert (Instru(Gmp_clear init_variant));
	      current_label <- None
	    | Lreal -> assert false (* TODO: reals *)
	    | _ ->
	      current_label <- Some (BegStmt stmt.sid);
	      let inserts_0, term' = self#term term in
	      List.iter self#insert inserts_0;
	      let term' = self#ctype_fragment term' in
	      let cond = Cmp(Rlt, term', Zero) in
	      let instr = Instru(Pc_exn("Variant non positive", id)) in
	      self#insert (If(cond, [instr], []));
	      current_label <- Some (EndStmt stmt.sid);
	      current_label <- Some (BegIter stmt.sid);
	      let inserts_1, term' = self#term term in
	      List.iter self#insert inserts_1;
	      let term' = self#ctype_fragment term' in
	      let variant = self#fresh_ctype_var Cil.intType in
	      self#insert (Decl_ctype_var variant);
	      self#insert (Instru(Affect(variant, term')));
	      current_label <- Some (EndIter stmt.sid);
	      let inserts_2, term' = self#term term in
	      List.iter self#insert inserts_2;
	      let term' = self#ctype_fragment term' in
	      let cond = Cmp(Rlt, variant, Zero) in
	      let instr = Instru(Pc_exn("Variant non positive", id)) in
	      self#insert (If(cond, [instr], []));
	      let cond = Cmp(Rge, term', variant) in
	      let instr = Instru(Pc_exn("Variant non decreasing", id)) in
	      self#insert (If(cond, [instr], []));
	      current_label <- None
	  end;
	  translated_properties <- prop :: translated_properties
      | _ -> ()
    end;
    Cil.DoChildren
  (* end vcode_annot *)

  method! vstmt_aux stmt =
    if List.mem stmt.sid stmts_to_reach then
      begin
	current_label <- Some (BegStmt stmt.sid);
	let str = Format.sprintf "@@FC:REACHABLE_STMT:%i" stmt.sid in
	self#insert (Instru(Pc_to_framac str));
	current_label <- None
      end;
    let kf = Kernel_function.find_englobing_kf stmt in
    begin
      match stmt.skind with
      | Cil_types.If(_exp,b1,b2,_loc) ->
	let add_block_reachability b =
	  match b.bstmts with
	  | first_stmt :: _ ->
      	    Sd_options.Self.debug ~dkey:Sd_options.dkey_reach
	      "stmt %i to reach" first_stmt.sid;
	    Sd_states.Unreachable_Stmts.replace first_stmt.sid (first_stmt, kf);
      	    stmts_to_reach <- first_stmt.sid :: stmts_to_reach
      	  | _ -> ()
	in
	add_block_reachability b1;
        add_block_reachability b2
      | _ -> ()
    end;
    Cil.DoChildren

  method! vglob_aux g =
    begin
      match g with
      | GFun (fundec, _l) ->
	self#in_current_function fundec.svar;
	let after globs = self#out_current_function; globs in
	Cil.ChangeDoChildrenPost ([g], after)
      | GVar(vi,_,_) -> visited_globals <- vi::visited_globals; Cil.DoChildren
      | _ -> Cil.DoChildren
    end

  method private predicate_named pnamed : insertion list * pred_expr =
    self#predicate pnamed.content

  method private quantif_predicate ~forall logic_vars hyps goal =
    if (List.length logic_vars) > 1 then
      failwith "quantification on many variables unsupported!";
    let var = self#fresh_pred_var() in
    let guards, vars = Sd_utils.compute_guards [] logic_vars hyps in
    if vars <> [] then
      failwith "Unguarded variables in quantification!";
    let t1,r1,lv,r2,t2 = List.hd guards in
    let iter_name = lv.lv_name in
    let insert_0 = Decl_pred_var var in
    let insert_1 = Instru(Affect_pred(var, (if forall then True else False))) in
    let inserts_3 =
      match t1.term_type with
      | Linteger ->
	begin
	  match t2.term_type with
	  | Linteger ->
	    let fresh_iter = My_gmp_var iter_name in
	    let insert_0, decl_iter = self#decl_gmp_var fresh_iter in
	    let inserts_1, t1' = self#term t1 in
	    let t1' = self#gmp_fragment t1' in
	    let inserts_2, t2' = self#term t2 in
	    let t2' = self#gmp_fragment t2' in
	    let insert_3, init_iter = self#init_set_gmp_var decl_iter t1' in
	    let inserts_4 =
	      if r1 = Rlt then
		[Instru(Gmp_binop_ui(PlusA,init_iter,init_iter,One))]
	      else []
	    in
	    let exp1 = Gmp_cmpr(r2, init_iter, t2') in
	    let exp2 = if forall then var else Lnot var in
	    let inserts_block =
	      let ins_b_0, goal_var = self#predicate_named goal in
	      let ins_b_1 = Instru(Affect_pred(var, goal_var)) in
	      let ins_b_2 =
		Instru(Gmp_binop_ui(PlusA, init_iter, init_iter,One)) in
	      ins_b_0 @ [ins_b_1; ins_b_2]
	    in
	    let insert_5 =
	      For(None, Some(Land(exp1, exp2)), None, inserts_block) in
	    let insert_6 = Instru(Gmp_clear init_iter) in
	    let insert_7 = Instru(Gmp_clear t1') in
	    let insert_8 = Instru(Gmp_clear t2') in
	    [insert_0] @ inserts_1 @ inserts_2 @ [insert_3] @ inserts_4
	    @ [insert_5; insert_6; insert_7; insert_8]
	  | Lreal -> assert false (* TODO: reals *)
	  | _ ->
	    let fresh_iter = My_gmp_var iter_name in
	    let insert_0, decl_iter = self#decl_gmp_var fresh_iter in
	    let inserts_1, t1' = self#term t1 in
	    let t1' = self#gmp_fragment t1' in
	    let inserts_2, t2' = self#term t2 in
	    let t2' = self#ctype_fragment t2' in
	    let insert_3, init_iter = self#init_set_gmp_var decl_iter t1' in
	    let inserts_4 =
	      if r1 = Rlt then
		[Instru(Gmp_binop_ui(PlusA,init_iter,init_iter,One))]
	      else []
	    in
	    let exp1 = Gmp_cmpr_si(r2, init_iter, t2') in
	    let exp2 = if forall then var else Lnot var in
	    let inserts_block =
	      let ins_b_0, goal_var = self#predicate_named goal in 
	      let ins_b_1 = Instru(Affect_pred(var, goal_var)) in
	      let ins_b_2 =
		Instru(Gmp_binop_ui(PlusA, init_iter, init_iter,One)) in
	      ins_b_0 @ [ins_b_1; ins_b_2]
	    in
	    let insert_5 = For(None,Some(Land(exp1,exp2)),None,inserts_block) in
	    let insert_6 = Instru(Gmp_clear init_iter) in
	    let insert_7 = Instru(Gmp_clear t1') in
	    [insert_0] @ inserts_1 @ inserts_2 @ [insert_3] @ inserts_4
	    @ [insert_5; insert_6; insert_7]
	end
      | Lreal -> assert false (* TODO: reals *)
      | _ ->
	let iter = My_ctype_var (Cil.intType, iter_name) in
	let insert_0 = Decl_ctype_var iter in
	let inserts_1, t1' = self#term t1 in
	let t1' = self#ctype_fragment t1' in
	let inserts_2, t2' = self#term t2 in
	let t2' = self#ctype_fragment t2' in
	let exp1 = Affect(iter, (match r1 with
	  | Rlt -> Binop(PlusA,t1',One)
	  | Rle -> t1'
	  | _ -> assert false))
	in
	let exp2 =Land((Cmp(r2,iter,t2')),(if forall then var else Lnot var)) in
	let exp3 = Affect(iter,Binop(PlusA,iter,One)) in
	let inserts_block =
	  let ins_b_0, goal_var = self#predicate_named goal in
	  let ins_b_1 = Instru(Affect_pred(var, goal_var)) in
	  ins_b_0 @ [ins_b_1]
	in
	let insert_3 = For(Some exp1, Some exp2, Some exp3, inserts_block) in
	[insert_0] @ inserts_1 @ inserts_2 @ [insert_3]
    in
    let insert_4 = Block inserts_3 in
    [insert_0; insert_1; insert_4], var
  (* end of quantif_predicate *)

  method private predicate pred : insertion list * pred_expr =
    match pred with
    | Ptrue -> [], True
    | Pfalse -> [], False
    | Pvalid(_,term) | Pvalid_read(_,term) ->
      let loc = term.term_loc in
      let pointer, offset =
	match term.term_node with
	| TLval _ -> term, Cil.lzero ~loc ()
	| TBinOp ((PlusPI|IndexPI),x,{term_node = Trange(_,Some y)}) -> x,y
	| TBinOp ((PlusPI|IndexPI),x,y) -> x,y
	| TBinOp (MinusPI,x,y) ->
	  let einfo = {exp_type=y.term_type; exp_name=[]} in
	  x, Cil.term_of_exp_info loc (TUnOp(Neg,y)) einfo
	| _ -> Sd_utils.error_term term
      in
      let inserts_0, x' = self#term pointer in
      let x' = self#ctype_fragment x' in
      let inserts_1, y' = self#term offset in
      let inserts, ret =
	match offset.term_type with
	| Linteger ->
	  let y' = self#gmp_fragment y' in
	  let var = self#fresh_pred_var() in
	  let insert_2 = Decl_pred_var var in
	  let exp1 = Gmp_cmp_ui(Ge, y', Zero) in
	  let exp2 = Gmp_cmp_ui(Lt, y', Pc_dim(x')) in
	  let insert_3 = Instru(Affect_pred(var, Land(exp1, exp2))) in
	  let insert_4 = Instru(Gmp_clear y') in
	  [insert_2; insert_3; insert_4], var
	| Ctype (TInt _) ->
	  let y' = self#ctype_fragment y' in
	  [], Land(Cmp(Rge, y', Zero), Cmp(Rgt, Pc_dim(x'), y'))
	| _ -> assert false (* unreachable *)
      in
      inserts_0 @ inserts_1 @ inserts, ret
    | Pforall(logic_vars,{content=Pimplies(hyps,goal)}) ->
      self#quantif_predicate ~forall:true logic_vars hyps goal
    | Pexists(logic_vars,{content=Pand(hyps,goal)}) ->
      self#quantif_predicate ~forall:false logic_vars hyps goal
    | Pforall _ -> failwith "\\forall not of the form \\forall ...; a ==> b;"
    | Pexists _ -> failwith "\\exists not of the form \\exists ...; a && b;"
    | Pnot(pred1) ->
      let ins, pred1_var = self#predicate_named pred1 in
      ins, Lnot pred1_var
    | Pand(pred1,pred2) ->
      let var = self#fresh_pred_var() in
      let inserts_0, pred1_var = self#predicate_named pred1 in
      let insert_1 = Decl_pred_var var in
      let insert_2 = Instru(Affect_pred(var, pred1_var)) in
      let inserts_b_0, pred2_var = self#predicate_named pred2 in
      let insert_b_1 = Instru(Affect_pred(var, pred2_var)) in
      let insert_3 = If(var, inserts_b_0 @ [insert_b_1], []) in
      inserts_0 @ [insert_1; insert_2; insert_3], var
    | Por(pred1,pred2) ->
      let var = self#fresh_pred_var()  in
      let inserts_0, pred1_var = self#predicate_named pred1 in
      let insert_1 = Decl_pred_var var in
      let insert_2 = Instru(Affect_pred(var, pred1_var)) in
      let inserts_b_0, pred2_var = self#predicate_named pred2 in
      let insert_b_1 = Instru(Affect_pred(var, pred2_var)) in
      let insert_3 = If(var, [], inserts_b_0 @ [insert_b_1]) in
      inserts_0 @ [insert_1; insert_2; insert_3], var
    | Pimplies(pred1,pred2) ->
      let var = self#fresh_pred_var() in
      let insert_0 = Decl_pred_var var in
      let insert_1 = Instru(Affect_pred(var, True)) in
      let inserts_2, pred1_var = self#predicate_named pred1 in
      let inserts_b_0, pred2_var = self#predicate_named pred2 in
      let insert_b_1 = Instru(Affect_pred(var, pred2_var)) in
      let insert_3 = If(pred1_var, inserts_b_0 @ [insert_b_1], []) in
      [insert_0; insert_1] @ inserts_2 @ [insert_3], var
    | Piff(pred1,pred2) ->
      let inserts_0, pred1_var = self#predicate_named pred1 in
      let inserts_1, pred2_var = self#predicate_named pred2 in
      let exp1 = Lor(Lnot pred1_var, pred2_var) in
      let exp2 = Lor(Lnot pred2_var, pred1_var) in
      inserts_0 @ inserts_1, Land(exp1, exp2)
    | Pif (t,pred1,pred2) -> (* untested *)
      begin
	let inserts_0, term_var = self#term t in
	let res_var = self#fresh_pred_var() in
	let insert_1 = Decl_pred_var res_var in
	let cond, insert_3 =
	  match t.term_type with
	  | Linteger ->
	    let x = self#gmp_fragment term_var in
	    Gmp_cmp_si(Ne, x, Zero), [Instru(Gmp_clear x)]
	  | Lreal -> assert false (* unreachable *)
	  | Ctype (TInt _) -> 
	    Cmp(Rneq, self#ctype_fragment term_var, Zero), []
	  | Ltype (lt,_) when lt.lt_name = Utf8_logic.boolean ->
	    Cmp(Rneq, self#ctype_fragment term_var, Zero), []
	  | _ -> assert false (* unreachable *)
	in
	let inserts_then_0, pred1_var = self#predicate_named pred1 in
	let insert_then_1 = Instru(Affect_pred(res_var, pred1_var)) in
	let inserts_then = inserts_then_0 @ [insert_then_1] in
	let inserts_else_0, pred2_var = self#predicate_named pred2 in
	let insert_else_1 = Instru(Affect_pred(res_var, pred2_var)) in
	let inserts_else = inserts_else_0 @ [insert_else_1] in
	let insert_2 = If(cond, inserts_then, inserts_else) in
	inserts_0 @ [insert_1; insert_2] @ insert_3, res_var
      end

    | Prel(rel,t1,t2) ->
      let inserts_0, t1' = self#term t1 in
      let inserts_1, t2' = self#term t2 in
      let clear_t1 = match t1.term_type with
	Linteger -> [Instru(Gmp_clear (self#gmp_fragment t1'))] | _ -> []
      in
      let clear_t2 = match t2.term_type with
	Linteger -> [Instru(Gmp_clear (self#gmp_fragment t2'))] | _ -> []
      in
      let inserts, ret =
	match t1.term_type, t2.term_type with
	| Linteger, Linteger ->
	  let var = self#fresh_pred_var() in
	  let t1' = self#gmp_fragment t1' in
	  let t2' = self#gmp_fragment t2' in
	  let insert_2 = Decl_pred_var var in
	  let insert_3 = Instru(Affect_pred(var, Gmp_cmpr(rel, t1', t2'))) in
	  [insert_2; insert_3], var
	| Linteger, Ctype x ->
	  let var = self#fresh_pred_var() in
	  let t1' = self#gmp_fragment t1' in
	  let t2' = self#ctype_fragment t2' in
	  let insert_2 = Decl_pred_var var in
	  let value =
	    if Cil.isUnsignedInteger x then Gmp_cmpr_ui(rel, t1', t2')
	    else if Cil.isSignedInteger x then Gmp_cmpr_si(rel, t1', t2')
	    else assert false
	  in
	  let insert_3 = Instru(Affect_pred(var, value)) in
	  [insert_2; insert_3], var
	| Lreal, Lreal -> assert false (* TODO: reals *)
	| Ctype x, Linteger ->
	  let var = self#fresh_pred_var() in
	  let t1' = self#ctype_fragment t1' in
	  let t2' = self#gmp_fragment t2' in
	  let fresh_var' = self#fresh_gmp_var() in
	  let insert_2, decl_var' = self#decl_gmp_var fresh_var' in
	  let init_set =
	    if Cil.isUnsignedInteger x then self#init_set_ui_gmp_var
	    else if Cil.isSignedInteger x then self#init_set_si_gmp_var
	    else assert false
	  in
	  let insert_3, init_var' = init_set decl_var' t1' in
	  let insert_4 = Decl_pred_var var in
	  let insert_5 = Instru(Affect_pred(var,Gmp_cmpr(rel,init_var',t2'))) in
	  let insert_7 = Instru(Gmp_clear init_var') in
	  [insert_2; insert_3; insert_4; insert_5; insert_7], var
	| _ -> [], Cmp(rel, self#ctype_fragment t1', self#ctype_fragment t2')
      in
      inserts_0 @ inserts_1 @ inserts @ clear_t1 @ clear_t2, ret
      
    | Pat(p, LogicLabel(_,l)) when l = "Here" -> self#predicate_named p
    | Pat (p,_) ->
      Sd_options.Self.warning "%a unsupported!" Printer.pp_predicate pred;
      self#predicate_named p
    | _ ->
      Sd_options.Self.warning "%a unsupported" Printer.pp_predicate pred;
      [], True
(* end predicate *)
end
