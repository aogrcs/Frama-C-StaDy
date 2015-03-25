
open Cil_types

exception Unreachable
exception Unsupported

type label =
| BegStmt of int
| EndStmt of int
| BegFunc of string
| EndFunc of string
| BegIter of int
| EndIter of int

(* alternate type 'stmt' *)
type insertion =
| Instru of instr
| IRet of exp
| Decl of varinfo
| Block of insertion list
| IIf of exp * insertion list * insertion list
| ILoop of exp * insertion list

(* alternate type 'fundec' using insertions instead of stmts *)
type func = {
  mutable func_var: varinfo;
  mutable func_formals: varinfo list;
  mutable func_locals: varinfo list;
  mutable func_stmts: insertion list;
}

let mk_func v f l s = {func_var=v; func_formals=f; func_locals=l; func_stmts=s;}

let binop_to_relation = function
  | Lt -> Rlt
  | Gt -> Rgt
  | Le -> Rle
  | Ge -> Rge
  | Eq -> Req
  | Ne -> Rneq
  | _ -> raise Unreachable

let relation_to_binop = function
  | Rlt -> Lt
  | Rgt -> Gt
  | Rle -> Le
  | Rge -> Ge
  | Req -> Eq
  | Rneq -> Ne

let loc = Cil_datatype.Location.unknown

(* varinfos *)
let my_varinfo ty varname = Cil.makeVarinfo false false varname ty
let my_Z_varinfo s = my_varinfo (Utils.mpz_t()) s
let my_pred_varinfo s = my_varinfo Cil.intType s

(* expressions *)
let zero = Cil.zero ~loc
let one = Cil.one ~loc
let cmp rel e1 e2 = Cil.mkBinOp ~loc (relation_to_binop rel) e1 e2

(* instructions *)
let instru_affect a b = Set(a,b,loc)
let instru_skip = Skip loc

let binop_to_fname = function
  | PlusA -> "add"
  | MinusA -> "sub"
  | Mult -> "mul"
  | Div -> "tdiv_q"
  | Mod -> "tdiv_r"
  | _ -> raise Unreachable

let rec typename = function
  | TInt (ikind, _) ->
     begin
       match ikind with
       | IBool -> "bool"
       | IChar -> "char"
       | ISChar -> "schar"
       | IUChar -> "uchar"
       | IInt -> "sint"
       | IUInt -> "uint"
       | IShort -> "sshort"
       | IUShort -> "ushort"
       | ILong -> "slong"
       | IULong -> "ulong"
       | ILongLong -> "slonglong"
       | IULongLong -> "ulonglong"
     end
  | TFloat (fkind, _) ->
     begin
       match fkind with
       | FFloat -> "float"
       | FDouble -> "double"
       | FLongDouble -> raise Unsupported
     end
  | TNamed (ty, _) -> typename ty.ttype
  | _ -> raise Unreachable

(* insertions *)
let decl_varinfo v = Decl v
let ins_ret a = IRet a
let ins_if  a b c = IIf(a,b,c)
let ins_loop a b = ILoop(a,b)

class gather_insertions props cwd = object(self)
  inherit Visitor.frama_c_inplace

  val insertions : (label, insertion Queue.t) Hashtbl.t = Hashtbl.create 64
  val mutable functions = ([] : func list)
  val mutable result_varinfo = None
  val mutable in_old_term = false
  val mutable in_old_ptr = false
  val mutable bhv_to_reach_cpt = 0
  val mutable visited_globals = []
  val mutable last_Z_var_id = -1
  val mutable last_ctype_var_id = -1
  val mutable last_pred_var_id = -1
  val mutable last_fct_id = -1

  (* list of stmt ids (sids) used for testing reachibility of some stmts *)
  val mutable stmts_to_reach = []

  (* we can only modify the property_status of the properties that have really
     been translated into pathcrawler_assert_exception *)
  val mutable translated_properties = []

  method get_insertions () = insertions
  method get_functions () = functions
  method get = States.Externals.find
  method call fct ret args =
    let vi = self#get fct in
    self#add_function_call vi;
    Call(ret, Cil.evar vi, args, loc)
  method cmalloc x y = self#call "malloc" (Some x) [y]
  method cfree x = self#call "free" None [x]
  method cpc_dim x y = self#call "pathcrawler_dimension" (Some x) [y]
  method cpc_exc x y = self#call "pathcrawler_assert_exception" None [x;y]
  method cpc_assume x y = self#call "pathcrawler_assume_exception" None [x;y]
  method cpc_to_fc x = self#call "pathcrawler_to_framac" None [x]
  method cclear x = self#call "__gmpz_clear" None [x]
  method cinit x = self#call "__gmpz_init" None [x]
  method cinit_set x y = self#call "__gmpz_init_set" None [x;y]
  method cinit_set_ui x y = self#call "__gmpz_init_set_ui" None [x;y]
  method cinit_set_si x y = self#call "__gmpz_init_set_si" None [x;y]
  method cinit_set_str x y z = self#call "__gmpz_init_set_str" None [x;y;z]
  method cset x y = self#call "__gmpz_set" None [x;y]
  method cabs x y = self#call "__gmpz_abs" None [x;y]
  method cadd x y z = self#call "__gmpz_add" None [x;y;z]
  method cadd_ui x y z = self#call "__gmpz_add_ui" None [x;y;z]
  method csub x y z = self#call "__gmpz_sub" None [x;y;z]
  method csub_ui x y z = self#call "__gmpz_sub_ui" None [x;y;z]
  method cui_sub x y z = self#call "__gmpz_ui_sub" None [x;y;z]
  method cmul x y z = self#call "__gmpz_mul" None [x;y;z]
  method cmul_ui x y z = self#call "__gmpz_mul_ui" None [x;y;z]
  method cmul_si x y z = self#call "__gmpz_mul_si" None [x;y;z]
  method ctdiv_q x y z = self#call "__gmpz_tdiv_q" None [x;y;z]
  method ctdiv_q_ui x y z = self#call "__gmpz_tdiv_q_ui" None [x;y;z]
  method ctdiv_r x y z = self#call "__gmpz_tdiv_r" None [x;y;z]
  method ctdiv_r_ui x y z = self#call "__gmpz_tdiv_r_ui" None [x;y;z]
  method cbinop op x y z = self#call("__gmpz_"^(binop_to_fname op)) None [x;y;z]
  method cbinop_ui op x y z =
    self#call("__gmpz_"^(binop_to_fname op)^"_ui") None [x;y;z]
  method cget_ui x y = self#call "__gmpz_get_ui" (Some x) [y]
  method cget_si x y = self#call "__gmpz_get_si" (Some x) [y]
  method ccmp x y z = self#call "__gmpz_cmp" (Some x) [y;z]
  method ccmp_ui x y z = self#call "__gmpz_cmp_ui" (Some x) [y;z]
  method ccmp_si x y z = self#call "__gmpz_cmp_si" (Some x) [y;z]
  method cmul_2exp x y z = self#call "__gmpz_mul_2exp" None [x;y;z]
  method cfdiv_q_2exp x y z = self#call "__gmpz_fdiv_q_2exp" None [x;y;z]
  method cnondet ty x = self#call ("nondet_"^(typename ty)) (Some x) []

  val mutable fcts_called = ([] : varinfo list)

  method add_function_call vi =
    if List.mem vi fcts_called then () else fcts_called <- vi :: fcts_called

  method get_new_globals() =
    let on_varinfo ret v =
      try
	if (String.sub v.vname 0 7) = "nondet_" then
	  let vname1 = v.vname ^ "_val" in
	  let ty1 = TPtr(Cil.getReturnType v.vtype,[]) in
	  let vi1 = Cil.makeVarinfo false false vname1 ty1 in
	  vi1 :: ret
	else ret
      with _ -> ret
    in
    List.fold_left on_varinfo [] fcts_called

  (* those globals are initialized to zero *)
  method get_new_init_globals() =
    let on_varinfo ret v =
      try
	if (String.sub v.vname 0 7) = "nondet_" then
	  let vname2 = v.vname ^ "_cpt" in
	  let ty2 = Cil.uintType in
	  let vi2 = Cil.makeVarinfo false false vname2 ty2 in
	  vi2 :: ret
	else ret
      with _ -> ret
    in
    List.fold_left on_varinfo [] fcts_called

  method private insert label str =
    try Queue.add str (Hashtbl.find insertions label)
    with Not_found ->
      let q = Queue.create() in
      Queue.add str q;
      Hashtbl.add insertions label q

  method private fresh_Z_varinfo() =
    last_Z_var_id <- last_Z_var_id + 1;
    let varname = "__stady_gmp_" ^ (string_of_int last_Z_var_id) in
    my_Z_varinfo varname

  method private fresh_ctype_varinfo ty =
    last_ctype_var_id <- last_ctype_var_id + 1;
    let varname = "__stady_term_" ^ (string_of_int last_ctype_var_id) in
    my_varinfo ty varname

  method private fresh_pred_varinfo() =
    last_pred_var_id <- last_pred_var_id + 1;
    let varname = "__stady_pred_" ^ (string_of_int last_pred_var_id) in
    my_pred_varinfo varname

  method private fresh_fct_varinfo ty =
    last_fct_id <- last_fct_id + 1;
    let varname = "__stady_fct_" ^ (string_of_int last_fct_id) in
    my_varinfo ty varname

  method translated_properties() = Utils.no_repeat translated_properties

  method private translate_constant ty = function
    | Integer (i, str_opt) ->
       begin
	 match ty with
	 | Linteger ->
	    let fresh_var = self#fresh_Z_varinfo() in
	    let insert_0 = decl_varinfo fresh_var in
	    let str = try Extlib.the str_opt with _ -> Integer.to_string i in
	    let str = Cil.mkString ~loc str in
	    let e_fresh_var = Cil.evar fresh_var in
	    let ten = CInt64(Integer.of_int 10, Cil_types.IInt, Some "10") in
	    let e_ten = Cil.new_exp ~loc (Const ten) in
	    let insert_1 = Instru(self#cinit_set_str e_fresh_var str e_ten) in
	    [insert_0; insert_1], Cil.evar fresh_var
	 | Ctype(TInt(ik,_)) ->[],Cil.new_exp ~loc (Const(CInt64(i,ik,str_opt)))
	 | _ -> raise Unreachable
       end
    | LStr str -> [], Cil.new_exp ~loc (Const(CStr str))
    | LWStr i64_l -> [], Cil.new_exp ~loc (Const(CWStr i64_l))
    | LChr c -> [], Cil.new_exp ~loc (Const(CChr c))
    | LReal {r_literal=s; r_nearest=f; r_lower=l; r_upper=u} ->
      if l <> u then
	Options.Self.warning ~current:true ~once:true
	  "approximating a real number by a float";
      [], Cil.new_exp ~loc (Const(CReal(f, FLongDouble, Some s)))
    | LEnum e -> [], Cil.new_exp ~loc (Const(CEnum e))

  method private translate_var lv =
    let varname = match self#current_func with
      | Some _ when in_old_term ->
	 let prefix = match lv.lv_type with
	   | Ctype ty when (Cil.isPointerType ty || Cil.isArrayType ty)
			   && in_old_ptr -> "old_ptr"
	   | _ -> "old"
	 in
	 begin
	   match lv.lv_origin with
	   | Some _ -> prefix ^ "_" ^ lv.lv_name
	   | None -> lv.lv_name
	 end
      | _ -> lv.lv_name
    in
    match lv.lv_type with
    | Linteger -> my_Z_varinfo varname
    | Lreal -> raise Unsupported
    | Ctype ty -> my_varinfo ty varname
    | _ -> raise Unreachable

  method private translate_unop op t = match t.term_type with
    | Linteger ->
       assert(op = Neg);
       let i_0, e = self#translate_term t in
       let ret = self#fresh_Z_varinfo() in
       let i_1 = decl_varinfo ret in
       let e_ret = Cil.evar ret in
       let i_2 = Instru(self#cinit e_ret) in
       let i_3 = Instru(self#cui_sub e_ret zero e) in
       let i_4 = Instru(self#cclear e) in
       i_0 @ [i_1; i_2; i_3; i_4], Lval(Cil.var ret)
    | Lreal -> raise Unsupported
    | _ -> let ins, e = self#translate_term t in ins, UnOp(op,e,(Cil.typeOf e))

  method private translate_shift ty shift a b = match ty with
    | Linteger ->
       let ret = self#fresh_Z_varinfo() in
       let e_ret = Cil.evar ret in
       let i_2 = decl_varinfo ret in
       let i_3 = Instru(self#cinit e_ret) in
       let i_0, x = self#translate_term a in
       let i_1, y = self#translate_term b in
       let b0, a0, e0 = match a.term_type with
	 | Linteger -> [], [Instru(self#cclear x)], x
	 | Ctype ty ->
	    let init_set = match Cil.isUnsignedInteger ty with
	      | true -> self#cinit_set_ui
	      | false -> self#cinit_set_si
	    in
	    let v_1 = self#fresh_Z_varinfo() in
	    let i_4 = decl_varinfo v_1 in
	    let e_v_1 = Cil.evar v_1 in
	    let i_6 = Instru(init_set e_v_1 x) in
	    [i_4; i_6], [Instru(self#cclear e_v_1)], e_v_1
	 | _ -> raise Unreachable
       in
       let b1, e1 = match b.term_type with
	 | Linteger ->
	    let v = self#fresh_ctype_varinfo Cil.ulongLongType in
	    let i_1 = decl_varinfo v in
	    let i_2 = Instru(self#cget_ui (Cil.var v) y) in
	    let i_3 = Instru(self#cclear y) in
	    [i_1; i_2; i_3], (Cil.evar v)
	 | Ctype _ -> [], y
	 | _ -> raise Unreachable
       in
       i_2 :: i_3 :: i_0 @ i_1 @ b0 @ b1 @ Instru(shift e_ret e0 e1) :: a0,
       e_ret.enode
    | _ -> raise Unreachable

  method private translate_binop ty op a b = match op with
    | IndexPI
    | PlusPI
    | MinusPI ->
       let i_0, a' = self#translate_term a in
       let i_1, b' = self#translate_term b in
       let i_2, e = match b.term_type with
	 | Linteger ->
	    let v = self#fresh_ctype_varinfo Cil.intType in
	    let ii_0 = decl_varinfo v in
	    let ii_1 = Instru(self#cget_si (Cil.var v) b') in
	    let ii_2 = Instru(self#cclear b') in
	    [ii_0; ii_1; ii_2], Cil.evar v
	 | _ -> [], b'
       in
       let e' = Cil.new_exp ~loc (BinOp(op,a',e,(Cil.typeOf a'))) in
       i_0 @ i_1 @ i_2, e'.enode
    | Shiftlt -> self#translate_shift ty self#cmul_2exp a b
    | Shiftrt -> self#translate_shift ty self#cfdiv_q_2exp a b
    | _ ->
       let i_0, x = self#translate_term a in
       let i_1, y = self#translate_term b in
       match ty with
       | Linteger ->
	  let ret = self#fresh_Z_varinfo() in
	  let i_2 = decl_varinfo ret in
	  let e_ret = Cil.evar ret in
	  let i_3 = Instru(self#cinit e_ret) in
	  let clear_t1 = Instru(self#cclear x) in
	  let clear_t2 = Instru(self#cclear y) in
	  let inserts = match a.term_type, b.term_type with
	    | Linteger, Linteger ->
	       [Instru(self#cbinop op e_ret x y); clear_t1; clear_t2]
	    | Ctype(TInt _ as ty1), Ctype(TInt _ as ty2) ->
	       let init_set_1 = match Cil.isUnsignedInteger ty1 with
		 | true -> self#cinit_set_ui
		 | false -> self#cinit_set_si
	       in
	       let init_set_2 = match Cil.isUnsignedInteger ty2 with
		 | true -> self#cinit_set_ui
		 | false -> self#cinit_set_si
	       in
	       let v_1 = self#fresh_Z_varinfo() in
	       let i_4 = decl_varinfo v_1 in
	       let v_2 = self#fresh_Z_varinfo() in
	       let i_5 = decl_varinfo v_2 in
	       let e_v_1 = Cil.evar v_1 in
	       let e_v_2 = Cil.evar v_2 in
	       let i_6 = Instru(init_set_1 e_v_1 x) in
	       let i_7 = Instru(init_set_2 e_v_2 y) in
	       let i_8 = Instru(self#cbinop op e_ret e_v_1 e_v_2) in
	       let i_9 = Instru(self#cclear e_v_1) in
	       let i_10 = Instru(self#cclear e_v_2) in
	       [i_4; i_5; i_6; i_7; i_8; i_9; i_10]
	    | _ -> raise Unreachable
	  in
	  i_0 @ i_1 @ i_2 :: i_3 :: inserts, e_ret.enode
       | Lreal -> raise Unsupported
       | Ltype _ as lt when Logic_const.is_boolean_type lt ->
	  begin
	    match a.term_type, b.term_type with
	    | Linteger, Linteger ->
	       let var = self#fresh_ctype_varinfo Cil.intType in
	       let i_2 = decl_varinfo var in
	       let tmp = self#fresh_ctype_varinfo Cil.intType in
	       let e_tmp = Cil.evar tmp in
	       let i_3 = decl_varinfo tmp in
	       let i_4 = Instru(self#ccmp (Cil.var tmp) x y) in
	       let op = binop_to_relation op in
	       let lvar = Cil.var var in
	       let i_5 = Instru(instru_affect lvar (cmp op e_tmp zero)) in
	       let i_6 = Instru(self#cclear x) in
	       let i_7 = Instru(self#cclear y) in
	       i_0 @ i_1 @ [i_2; i_3; i_4; i_5; i_6; i_7], (Cil.evar var).enode
	    | _ -> i_0 @ i_1, (Cil.mkBinOp ~loc op x y).enode
	  end
       | _ -> raise Unreachable

  method private translate_tif cond then_b else_b = match then_b.term_type with
    | Linteger ->
       let ret = self#fresh_Z_varinfo() in
       let i_0 = decl_varinfo ret in
       let e_ret = Cil.evar ret in
       let i_1 = Instru(self#cinit e_ret) in
       let i_2, cond' = self#translate_term cond in
       let tmp = self#fresh_ctype_varinfo Cil.intType in
       let e_tmp = Cil.evar tmp in
       let i_3 = decl_varinfo tmp in
       let i_4 = Instru(self#ccmp_si (Cil.var tmp) cond' zero) in
       let inserts_then_0, then_b' = self#translate_term then_b in
       let set_1 = Instru(self#cset e_ret then_b') in
       let clear_1 = Instru(self#cclear then_b') in
       let inserts_then = inserts_then_0 @ [set_1 ; clear_1] in
       let inserts_else_0, else_b' = self#translate_term else_b in
       let set_2 = Instru(self#cset e_ret else_b') in
       let clear_2 = Instru(self#cclear else_b') in
       let inserts_else = inserts_else_0 @ [ set_2 ; clear_2] in
       let i_5 = ins_if (cmp Rneq e_tmp zero) inserts_then inserts_else in
       let i_6 = Instru(self#cclear cond') in
       i_0 :: i_1 :: i_2 @ [i_3; i_4; i_5; i_6], e_ret.enode
    | Lreal -> raise Unsupported
    | _ -> raise Unreachable

  method private translate_at t = function
    | LogicLabel(_,stringlabel) ->
       if stringlabel = "Old" || stringlabel = "Pre" then
	 let is_ptr =
	   match t.term_node with TLval(TMem _,_) -> true | _-> false in
	 if is_ptr then in_old_ptr <- true;
	 in_old_term <- true;
	 let ins, v = self#translate_term t in
	 if is_ptr then in_old_ptr <- false;
	 in_old_term <- false;
	 ins, v.enode
	 else
	   (* label Post is only encoutered in post-conditions, and \at(t,Post)
	    * in a post-condition is t *)
	   if stringlabel = "Post" || stringlabel = "Here" then
	     let ins, v = self#translate_term t in
	     ins, v.enode
	   else
	     Options.Self.not_yet_implemented
	       "Sd_insertions.gather_insertions#term_node \\at(%a,%s)"
	       Debug.pp_term t stringlabel
    | _ -> raise Unsupported

  (* C type -> logic type *)
  method private translate_logic_coerce lt t = match lt with
    | Linteger ->
       let ty = match t.term_type with
	 | Ctype x -> Ctype (Cil.unrollType x)
	 | x -> x
       in
       let i_0, v = self#translate_term t in
       let ret = self#fresh_Z_varinfo() in
       let i_1 = decl_varinfo ret in
       let init_set = match ty with
	 | Ctype x when Cil.isUnsignedInteger x -> self#cinit_set_ui
	 | Ctype x when Cil.isSignedInteger x -> self#cinit_set_si
	 | _ -> raise Unsupported
       in
       let e_ret = Cil.evar ret in
       let i_2 = Instru(init_set e_ret v) in
       i_0 @ [i_1; i_2], e_ret.enode
    | Lreal -> raise Unsupported
    | _ -> raise Unreachable

  (* logic type -> C type *)
  method private translate_coerce t ty = match t.term_type with
    | Linteger ->
       let i_0, v = self#translate_term t in
       let ret = self#fresh_ctype_varinfo ty in
       let i_1 = decl_varinfo ret in
       let get = match ty with
	 | x when Cil.isUnsignedInteger x -> self#cget_ui
	 | x when Cil.isSignedInteger x -> self#cget_si
	 | _ -> raise Unsupported
       in
       let i_2 = Instru(get (Cil.var ret) v) in
       let i_3 = Instru(self#cclear v) in
       i_0 @ [i_1; i_2; i_3], (Cil.evar ret).enode
    | Lreal -> raise Unsupported
    | _ -> raise Unreachable

  method private translate_lambda li lower upper q t =
    assert(lower.term_type = Linteger && upper.term_type = Linteger);
    let name = li.l_var_info.lv_name in
    let init_val = if name = "\\sum" || name = "\\numof" then zero else one in
    let ret = self#fresh_Z_varinfo() in
    let i_0 = decl_varinfo ret in
    let e_ret = Cil.evar ret in
    let i_1 = Instru(self#cinit_set_si e_ret init_val) in
    let i_3, low = self#translate_term lower in
    let i_4, up = self#translate_term upper in
    let fresh_iter = my_Z_varinfo q.lv_name in
    let i_5 = decl_varinfo fresh_iter in
    let e_iter = Cil.evar fresh_iter in
    let i_6 = Instru(self#cinit_set e_iter low) in
    let ins_b_0, lambda_t = self#translate_term t in
    let ins_b_1, clear_lambda = match name with
      | s when s = "\\sum" ->
	 Instru(self#cbinop PlusA e_ret e_ret lambda_t),
	 [Instru(self#cclear lambda_t)]
      | s when s = "\\product" ->
	 Instru(self#cbinop Mult e_ret e_ret lambda_t),
	 [Instru(self#cclear lambda_t)]
      | s when s = "\\numof" ->
	 let cond = cmp Rneq lambda_t zero in
	 let instr = Instru(self#cbinop_ui PlusA e_ret e_ret one) in
	 ins_if cond [instr] [], []
      | _ -> raise Unsupported
    in
    let ins_b_2 = Instru(self#cbinop_ui PlusA e_iter e_iter one) in
    let tmp = self#fresh_ctype_varinfo Cil.intType in
    let e_tmp = Cil.evar tmp in
    let ii_1 = decl_varinfo tmp in
    let ii_2 = Instru(self#ccmp (Cil.var tmp) e_iter up) in
    let ii_3 = Instru(self#ccmp (Cil.var tmp) e_iter up) in
    let ins_b = ins_b_0 @ ins_b_1 :: ins_b_2 :: ii_3 :: clear_lambda in
    let i_7 = ins_loop (cmp Rle e_tmp zero) ins_b in
    let i_8 = Instru(self#cclear e_iter) in
    let i_9 = Instru(self#cclear low) in
    let i_10 = Instru(self#cclear up) in
    let ins_block = i_3 @ i_4 @ [i_5; i_6; ii_1; ii_2; i_7; i_8; i_9; i_10] in
    [i_0; i_1; Block ins_block], e_ret.enode

  method private translate_app li _ params =
    let s = li.l_var_info.lv_name in
    let ty = Extlib.the li.l_type in
    match ty, params with
    | Linteger, [param] when s = "\\abs" ->
       let i_0, x = self#translate_term param in
       let ret = self#fresh_Z_varinfo() in
       let i_1 = decl_varinfo ret in
       let e_ret = Cil.evar ret in
       let i_2 = Instru(self#cinit e_ret) in
       let i_3 = Instru(self#cabs e_ret x) in
       let i_4 = Instru(self#cclear x) in
       i_0 @ [i_1; i_2; i_3; i_4], e_ret.enode
    | Linteger, [l;u;{term_node=Tlambda([q],t)}]
	 when s = "\\sum" || s = "\\product" || s = "\\numof" ->
       self#translate_lambda li l u q t
    | Linteger, _ -> raise Unsupported
    | Lreal, _ -> raise Unsupported
    | _ -> raise Unreachable

  method private translate_cast ty t = match t.term_type with (* source type *)
    | Linteger ->
       let i_0, e = self#translate_term t in
       let ret = self#fresh_ctype_varinfo ty in
       let i_1 = decl_varinfo ret in
       let get = match ty with (* dest type *)
	 | x when Cil.isUnsignedInteger x -> self#cget_ui
	 | x when Cil.isSignedInteger x -> self#cget_si
	 | _ -> raise Unsupported
       in
       let i_2 = Instru(get (Cil.var ret) e) in
       let i_3 = Instru(self#cclear e) in
       i_0 @ [i_1; i_2; i_3], (Cil.evar ret).enode
    | Lreal -> raise Unsupported
    | Ctype _ -> let ins, e = self#translate_term t in ins, CastE (ty, e)
    | _ -> raise Unreachable

  method private translate_term_node t = match t.term_node with
    | TConst c -> let i, e = self#translate_constant t.term_type c in i, e.enode
    | TLval tl -> let ins, lv = self#translate_lval tl in ins, Lval lv
    | TSizeOf ty -> [], SizeOf ty
    | TSizeOfE t -> let ins, e = self#translate_term t in ins, SizeOfE e
    | TSizeOfStr str -> [], SizeOfStr str
    | TAlignOf ty -> [], AlignOf ty
    | TAlignOfE t -> let ins, e = self#translate_term t in ins, AlignOfE e
    | TUnOp (op,t) -> self#translate_unop op t
    | TBinOp (op,a,b) -> self#translate_binop t.term_type op a b
    | TCastE (ty,t) -> self#translate_cast ty t
    | TAddrOf tl -> let ins, lv = self#translate_lval tl in ins, AddrOf lv
    | TStartOf tl -> let ins, lv = self#translate_lval tl in ins, StartOf lv
    | Tapp (li,ll,params) -> self#translate_app li ll params
    | Tif (x,y,z) -> self#translate_tif x y z
    | Tat (t,l) -> self#translate_at t l
    | Tnull -> [], zero.enode
    | TLogic_coerce (lt,t) -> self#translate_logic_coerce lt t
    | TCoerce (t,ty) -> self#translate_coerce t ty
    | TCoerceE (t, {term_type=Ctype ty}) -> self#translate_coerce t ty
    | TCoerceE (t, {term_type=lt}) -> self#translate_logic_coerce lt t
    | Tlambda _
    | TDataCons _
    | Tbase_addr _
    | Toffset _
    | Tblock_length _
    | TUpdate _
    | Ttypeof _
    | Ttype _
    | Tempty_set
    | Tunion _
    | Tinter _
    | Tcomprehension _
    | Trange _
    | Tlet _ -> raise Unsupported

  method private translate_term t =
    let ins, enode = self#translate_term_node t in
    ins, Cil.new_exp ~loc enode

  method private translate_lhost = function
    | TVar lv -> [], Var(self#translate_var lv)
    | TResult _ -> [], Var (Extlib.the result_varinfo)
    | TMem t -> let ins, t = self#translate_term t in ins, Mem t

  method private translate_offset = function
    | TNoOffset -> [], NoOffset
    | TField(fi,o) -> let ins, o' = self#translate_offset o in ins, Field(fi,o')
    | TModel _ -> raise Unsupported
    | TIndex(t,o) ->
       let ins, e = self#translate_term t in
       let ins, e = match t.term_type with
	 | Linteger ->
  	    let tmp = self#fresh_ctype_varinfo Cil.intType in
  	    let i_1 = decl_varinfo tmp in
	    let i_2 = Instru(self#cget_si (Cil.var tmp) e) in
	    let i_3 = Instru(self#cclear e) in
	    ins @ [i_1; i_2; i_3], Cil.evar tmp
	 | Lreal -> raise Unreachable
	 | _ -> ins, e
       in
       let ins', o' = self#translate_offset o in
       ins @ ins', Index(e,o')

  method private translate_lval (a,b) =
    let aux() =
      let ins, a' = self#translate_lhost a in
      let ins', b' = self#translate_offset b in
      ins @ ins', (a',b')
    in
    match Cil.typeOfTermLval (a,b) with
    | Linteger ->
      let fresh_var = self#fresh_Z_varinfo() in
      let ins_0, t' = aux() in
      let ins_1 = decl_varinfo fresh_var in
      let e_t' = Cil.new_exp ~loc (Lval t') in
      let e_fresh_var = Cil.evar fresh_var in
      let ins_2 = Instru(self#cinit_set e_fresh_var e_t') in
      ins_0 @ [ins_1; ins_2], Cil.var fresh_var
    | Lreal -> raise Unsupported
    | _ -> aux()

  method private translate_pnamed p = self#translate_predicate p.content

  method private translate_rel rel t1 t2 =
    let inserts_0, t1' = self#translate_term t1 in
    let inserts_1, t2' = self#translate_term t2 in
    let clear_t1 = Instru(self#cclear t1') in
    let clear_t2 = Instru(self#cclear t2') in
    let inserts, ret = match t1.term_type, t2.term_type with
      | Linteger, Linteger ->
	let var = self#fresh_ctype_varinfo Cil.intType in
	let i_2 = decl_varinfo var in
	let i_3 = Instru(self#ccmp (Cil.var var) t1' t2') in
	[i_2; i_3; clear_t1; clear_t2], cmp rel (Cil.evar var) zero
      | Linteger, Ctype x ->
	let var = self#fresh_ctype_varinfo Cil.intType in
	let i_2 = decl_varinfo var in
	let zcmp =
	  if Cil.isUnsignedInteger x then self#ccmp_ui
	  else if Cil.isSignedInteger x then self#ccmp_si
	  else raise Unsupported
	in
	let i_3 = Instru(zcmp (Cil.var var) t1' t2') in
	[i_2; i_3; clear_t1], cmp rel (Cil.evar var) zero
      | Lreal, Lreal -> raise Unsupported
      | Ctype x, Linteger ->
	let var = self#fresh_ctype_varinfo Cil.intType in
	let fresh_var' = self#fresh_Z_varinfo() in
	let i_2 = decl_varinfo fresh_var' in
	let init_set =
	  if Cil.isUnsignedInteger x then self#cinit_set_ui
	  else if Cil.isSignedInteger x then self#cinit_set_si
	  else raise Unsupported
	in
	let e_fresh_var = Cil.evar fresh_var' in
	let i_3 = Instru(init_set e_fresh_var t1') in
	let i_4 = decl_varinfo var in
	let i_5 = Instru(self#ccmp (Cil.var var) e_fresh_var t2') in
	let i_6 = Instru(self#cclear e_fresh_var) in
	[i_2; i_3; i_4; i_5; i_6; clear_t2], cmp rel (Cil.evar var) zero
      | _ -> [], cmp rel t1' t2'
    in
    inserts_0 @ inserts_1 @ inserts, ret

  method private translate_and p q =
    let var = self#fresh_pred_varinfo() in
    let inserts_0, pred1_var = self#translate_pnamed p in
    let insert_1 = decl_varinfo var in
    let lvar = Cil.var var in
    let insert_2 = Instru(instru_affect lvar pred1_var) in
    let inserts_b_0, pred2_var = self#translate_pnamed q in
    let insert_b_1 = Instru(instru_affect lvar pred2_var) in
    let e_var = Cil.evar var in
    let insert_3 = ins_if e_var (inserts_b_0 @ [insert_b_1]) [] in
    inserts_0 @ [insert_1; insert_2; insert_3], e_var

  method private translate_or p q =
    let var = self#fresh_pred_varinfo()  in
    let inserts_0, pred1_var = self#translate_pnamed p in
    let insert_1 = decl_varinfo var in
    let lvar = Cil.var var in
    let insert_2 = Instru(instru_affect lvar pred1_var) in
    let inserts_b_0, pred2_var = self#translate_pnamed q in
    let insert_b_1 = Instru(instru_affect lvar pred2_var) in
    let e_var = Cil.evar var in
    let insert_3 = ins_if e_var [] (inserts_b_0 @ [insert_b_1]) in
    inserts_0 @ [insert_1; insert_2; insert_3], e_var

  method private translate_implies p q =
    let var = self#fresh_pred_varinfo() in
    let insert_0 = decl_varinfo var in
    let lvar = Cil.var var in
    let insert_1 = Instru(instru_affect lvar one) in
    let inserts_2, pred1_var = self#translate_pnamed p in
    let inserts_b_0, pred2_var = self#translate_pnamed q in
    let insert_b_1 = Instru(instru_affect lvar pred2_var) in
    let insert_3 = ins_if pred1_var (inserts_b_0 @ [insert_b_1]) [] in
    insert_0 :: insert_1 :: inserts_2 @ [insert_3], Cil.evar var

  method private translate_equiv p q =
    let inserts_0, pred1_var = self#translate_pnamed p in
    let inserts_1, pred2_var = self#translate_pnamed q in
    let not_pred1_var = Cil.new_exp ~loc (UnOp(LNot, pred1_var, Cil.intType)) in
    let not_pred2_var = Cil.new_exp ~loc (UnOp(LNot, pred2_var, Cil.intType)) in
    let exp1 = Cil.mkBinOp ~loc LOr not_pred1_var pred2_var in
    let exp2 = Cil.mkBinOp ~loc LOr not_pred2_var pred1_var in
    inserts_0 @ inserts_1, Cil.mkBinOp ~loc LAnd exp1 exp2

  method private translate_not p =
    let ins, p' = self#translate_pnamed p in
    ins, Cil.new_exp ~loc (UnOp(LNot, p', Cil.intType))

  method private translate_pif t p q =
    let inserts_0, term_var = self#translate_term t in
    let res_var = self#fresh_pred_varinfo() in
    let insert_1 = decl_varinfo res_var in
    let cond, ii, insert_3 = match t.term_type with
      | Linteger ->
	 let tmp = self#fresh_ctype_varinfo Cil.intType in
	 let i_1 = decl_varinfo tmp in
	 let i_2 = Instru(self#ccmp_si (Cil.var tmp) term_var zero) in
	 cmp Rneq (Cil.evar tmp) zero, [i_1; i_2],[Instru(self#cclear term_var)]
      | Lreal -> raise Unsupported
      | Ctype (TInt _) -> cmp Rneq term_var zero, [], []
      | Ltype _ as lt when Logic_const.is_boolean_type lt ->
	 cmp Rneq term_var zero, [], []
      | _ -> raise Unreachable
    in
    let inserts_then_0, pred1_var = self#translate_pnamed p in
    let lres_var = Cil.var res_var in
    let insert_then_1 = Instru(instru_affect lres_var pred1_var) in
    let inserts_then = inserts_then_0 @ [insert_then_1] in
    let inserts_else_0, pred2_var = self#translate_pnamed q in
    let insert_else_1 = Instru(instru_affect lres_var pred2_var) in
    let inserts_else = inserts_else_0 @ [insert_else_1] in
    let insert_2 = ins_if cond inserts_then inserts_else in
    inserts_0 @ ii @ insert_1 :: insert_2 :: insert_3, Cil.evar res_var

  method private unsupported_predicate p =
    Options.Self.warning ~current:true "%a unsupported" Printer.pp_predicate p;
    [], one

  method private translate_valid term = match term.term_node with
    | Tempty_set -> [], one
    | TBinOp ((PlusPI|IndexPI),p,{term_node = Trange(Some x,Some y)}) ->
       self#translate_valid_ptr_range p x y
    | TBinOp ((PlusPI|IndexPI),p,x) -> self#translate_valid_ptr_offset p x
    | TBinOp (MinusPI,p,x) ->
       let einfo = {exp_type=x.term_type; exp_name=[]} in
       let x = Cil.term_of_exp_info loc (TUnOp(Neg,x)) einfo in
       self#translate_valid_ptr_offset p x
    | TLval _ -> self#translate_valid_ptr term
    | _ -> Utils.error_term term

  method private translate_valid_ptr_range pointer min_off max_off =
    let inserts_0, x' = self#translate_term pointer in
    let inserts_1, low_o = self#translate_term min_off in
    let inserts_2, up_o = self#translate_term max_off in
    let ret = self#fresh_pred_varinfo () in
    let l_ret = Cil.var ret in
    let e_ret = Cil.evar ret in
    let i_0 = decl_varinfo ret in
    let dim = self#fresh_ctype_varinfo Cil.intType in
    let l_dim = Cil.var dim in
    let e_dim = Cil.evar dim in
    let i_before, i_then, cond, i_after =
      match min_off.term_type, max_off.term_type with
      | Linteger, Linteger ->
  	 let nonempty_set = self#fresh_pred_varinfo () in
  	 let i_0' = decl_varinfo nonempty_set in
  	 let l_nonempty_set = Cil.var nonempty_set in
  	 let e_nonempty_set = Cil.evar nonempty_set in
  	 let i_cond = Instru(self#ccmp l_nonempty_set low_o up_o) in
  	 let cond = cmp Rle e_nonempty_set zero in
  	 let i_1 = decl_varinfo dim in
  	 let i_2 = Instru(self#cpc_dim l_dim x') in
  	 let cmp_dim_off = self#fresh_ctype_varinfo Cil.intType in
  	 let l_cmp_dim_off = Cil.var cmp_dim_off in
  	 let e_cmp_dim_off = Cil.evar cmp_dim_off in
  	 let i_3 = decl_varinfo cmp_dim_off in
  	 let i_4 = Instru(self#ccmp_ui l_cmp_dim_off up_o e_dim) in
  	 let cmp_off_zero = self#fresh_ctype_varinfo Cil.intType in
  	 let l_cmp_off_zero = Cil.var cmp_off_zero in
  	 let e_cmp_off_zero = Cil.evar cmp_off_zero in
  	 let i_5 = decl_varinfo cmp_off_zero in
  	 let i_6 = Instru(self#ccmp_ui l_cmp_off_zero up_o zero) in
  	 let e1 = cmp Rge e_cmp_off_zero zero in
  	 let e2 = cmp Rlt e_cmp_dim_off zero in
  	 let i_7 = Instru(instru_affect l_ret (Cil.mkBinOp ~loc LAnd e1 e2)) in
  	 let i_clear = Instru(self#cclear low_o) in
	 let i_clear2 = Instru(self#cclear up_o) in
  	 [i_0'; i_cond], [i_1; i_2; i_3; i_4; i_5; i_6; i_7], cond,
	 [i_clear; i_clear2]
      | Linteger, Ctype (TInt _) ->
  	 let nonempty_set = self#fresh_pred_varinfo () in
  	 let i_0' = decl_varinfo nonempty_set in
  	 let l_nonempty_set = Cil.var nonempty_set in
  	 let e_nonempty_set = Cil.evar nonempty_set in
  	 let i_cond = Instru(self#ccmp_si l_nonempty_set low_o up_o) in
  	 let cond = cmp Rle e_nonempty_set zero in
  	 let i_1 = decl_varinfo dim in
  	 let i_2 = Instru(self#cpc_dim l_dim x') in
  	 let e1 = cmp Rge up_o zero in
  	 let e2 = cmp Rgt e_dim up_o in
  	 let i_7 = Instru(instru_affect l_ret (Cil.mkBinOp ~loc LAnd e1 e2)) in
  	 let i_clear = Instru(self#cclear low_o) in
  	 [i_0'; i_cond], [i_1; i_2; i_7], cond, [i_clear]
      | Ctype (TInt _), Linteger ->
	 let nonempty_set = self#fresh_pred_varinfo () in
  	 let i_0' = decl_varinfo nonempty_set in
  	 let l_nonempty_set = Cil.var nonempty_set in
  	 let e_nonempty_set = Cil.evar nonempty_set in
  	 let i_cond = Instru(self#ccmp_ui l_nonempty_set up_o low_o) in
  	 let cond = cmp Rge e_nonempty_set zero in
  	 let i_1 = decl_varinfo dim in
  	 let i_2 = Instru(self#cpc_dim l_dim x') in
  	 let cmp_dim_off = self#fresh_ctype_varinfo Cil.intType in
  	 let l_cmp_dim_off = Cil.var cmp_dim_off in
  	 let e_cmp_dim_off = Cil.evar cmp_dim_off in
  	 let i_3 = decl_varinfo cmp_dim_off in
  	 let i_4 = Instru(self#ccmp_ui l_cmp_dim_off up_o e_dim) in
  	 let cmp_off_zero = self#fresh_ctype_varinfo Cil.intType in
  	 let l_cmp_off_zero = Cil.var cmp_off_zero in
  	 let e_cmp_off_zero = Cil.evar cmp_off_zero in
  	 let i_5 = decl_varinfo cmp_off_zero in
  	 let i_6 = Instru(self#ccmp_ui l_cmp_off_zero up_o zero) in
  	 let e1 = cmp Rge e_cmp_off_zero zero in
  	 let e2 = cmp Rlt e_cmp_dim_off zero in
  	 let i_7 = Instru(instru_affect l_ret (Cil.mkBinOp ~loc LAnd e1 e2)) in
	 let i_clear = Instru(self#cclear up_o) in
  	 [i_0'; i_cond], [i_1; i_2; i_3; i_4; i_5; i_6; i_7], cond, [i_clear]
      | Ctype (TInt _), Ctype (TInt _) ->
  	 let i_1 = decl_varinfo dim in
  	 let i_2 = Instru(self#cpc_dim l_dim x') in
  	 let e1 = cmp Rge up_o zero in
  	 let e2 = cmp Rgt e_dim up_o in
  	 let i_3 = Instru(instru_affect l_ret (Cil.mkBinOp ~loc LAnd e1 e2)) in
	 [], [i_1; i_2; i_3], cmp Rle low_o up_o, []
      | _ -> raise Unreachable
    in
    let i_if = ins_if cond i_then [Instru(instru_affect l_ret one)] in
    inserts_0 @ inserts_1 @ inserts_2 @ [i_0] @ i_before @ i_if::i_after, e_ret

  method private translate_valid_ptr_offset pointer offset =
    let loc = pointer.term_loc in
    let inserts_0, x' = self#translate_term pointer in
    let inserts_1, y' = self#translate_term offset in
    let ret = self#fresh_pred_varinfo () in
    let l_ret = Cil.var ret in
    let e_ret = Cil.evar ret in
    let i_0 = decl_varinfo ret in
    let dim = self#fresh_ctype_varinfo Cil.intType in
    let l_dim = Cil.var dim in
    let e_dim = Cil.evar dim in
    let i_1 = decl_varinfo dim in
    let i_2 = Instru(self#cpc_dim l_dim x') in
    let inserts = match offset.term_type with
      | Linteger ->
  	 let cmp_dim_off = self#fresh_ctype_varinfo Cil.intType in
  	 let l_cmp_dim_off = Cil.var cmp_dim_off in
  	 let e_cmp_dim_off = Cil.evar cmp_dim_off in
  	 let i_3 = decl_varinfo cmp_dim_off in
  	 let i_4 = Instru(self#ccmp_ui l_cmp_dim_off y' e_dim) in
  	 let cmp_off_zero = self#fresh_ctype_varinfo Cil.intType in
  	 let l_cmp_off_zero = Cil.var cmp_off_zero in
  	 let e_cmp_off_zero = Cil.evar cmp_off_zero in
  	 let i_5 = decl_varinfo cmp_off_zero in
  	 let i_6 = Instru(self#ccmp_ui l_cmp_off_zero y' zero) in
  	 let e1 = cmp Rge e_cmp_off_zero zero in
  	 let e2 = cmp Rlt e_cmp_dim_off zero in
  	 let i_7 = Instru(instru_affect l_ret (Cil.mkBinOp ~loc LAnd e1 e2)) in
  	 let i_clear = Instru(self#cclear y') in
  	 [i_3; i_4; i_5; i_6; i_7; i_clear]
      | Ctype (TInt _) ->
  	 let e1 = cmp Rge y' zero in
  	 let e2 = cmp Rgt e_dim y' in
  	 [ Instru(instru_affect l_ret (Cil.mkBinOp ~loc LAnd e1 e2)) ]
      | _ -> raise Unreachable
    in
    inserts_0 @ inserts_1 @ [i_0; i_1; i_2] @ inserts, e_ret

  method private translate_valid_ptr pointer =
    let inserts_0, x' = self#translate_term pointer in
    let ret = self#fresh_pred_varinfo () in
    let i_0 = decl_varinfo ret in
    let dim = self#fresh_ctype_varinfo Cil.intType in
    let i_1 = decl_varinfo dim in
    let i_2 = Instru(self#cpc_dim (Cil.var dim) x') in
    let e2 = cmp Rgt (Cil.evar dim) zero in
    let i_3 = Instru(instru_affect (Cil.var ret) e2) in
    inserts_0 @ [i_0; i_1; i_2; i_3], (Cil.evar ret)

  method private translate_forall = self#translate_quantif ~forall:true
  method private translate_exists = self#translate_quantif ~forall:false
  method private translate_quantif ~forall logic_vars hyps goal =
    let var = self#fresh_pred_varinfo() in
    let i_0 = decl_varinfo var in
    let init_val = if forall then one else zero in
    let lvar = Cil.var var in
    let e_var = Cil.evar var in
    let i_1 = Instru(instru_affect lvar init_val) in
    let cond =
      if forall then e_var else Cil.new_exp ~loc (UnOp(LNot,e_var,Cil.intType))
    in
    let on_lvar (i_b,e_c,i_i,i_a) lvar =
      let t1,r1,r2,t2 = Utils.extract_guards lvar hyps in
      let iter_name = lvar.lv_name in
      let i_before, e_cond, i_inside, i_after = match t1.term_type with
	| Linteger ->
	  let fresh_iter = my_Z_varinfo iter_name in
	  let i_0 = decl_varinfo fresh_iter in
	  let i_1, t1' = self#translate_term t1 in
	  let i_2, t2' = self#translate_term t2 in
	  let e_iter = Cil.evar fresh_iter in
	  let i_3 = Instru(self#cinit_set e_iter t1') in
	  let i_4 =
	    if r1 = Rlt then [Instru(self#cbinop_ui PlusA e_iter e_iter one)]
	    else []
	  in
	  let tmp = self#fresh_ctype_varinfo Cil.intType in
	  let i_5 = decl_varinfo tmp in
	  let ltmp = Cil.var tmp in
	  let ins_b_2 = Instru(self#cbinop_ui PlusA e_iter e_iter one) in
	  let e1 = cmp r2 (Cil.evar tmp) zero in
	  let i_8 = Instru(self#cclear e_iter) in
	  let i_9 = Instru(self#cclear t1') in
	  let cmp, i_10 = match t2.term_type with
	    | Linteger -> self#ccmp, [Instru(self#cclear t2')]
	    | Lreal -> raise Unsupported
	    | _ -> self#ccmp_si, []
	  in
	  let i_6 = Instru(cmp ltmp e_iter t2') in
	  let ins_b_3 = Instru(cmp ltmp e_iter t2') in
	  let i_before = i_0 :: i_1 @ i_2 @ i_3 :: i_4 @ [i_5; i_6] in
	  let i_inside = [ins_b_2; ins_b_3] in
	  let i_after = i_8 :: i_9 :: i_10 in
	  i_before, e1, i_inside, i_after
	| Lreal -> raise Unsupported
	| _ ->
	  let iter = my_varinfo Cil.intType iter_name in
	  let insert_0 = decl_varinfo iter in
	  let inserts_1, t1' = self#translate_term t1 in
	  let inserts_2, t2' = self#translate_term t2 in
	  let liter = Cil.var iter in
	  let init = instru_affect liter (match r1 with
	    | Rlt -> Cil.mkBinOp ~loc PlusA t1' one
	    | Rle -> t1'
	    | _ -> raise Unsupported)
	  in
	  let e_iter = Cil.evar iter in
	  let e1 = cmp r2 e_iter t2' in
	  let next = instru_affect liter (Cil.mkBinOp ~loc PlusA e_iter one) in
	  let i_before = insert_0 :: inserts_1 @ inserts_2 @ [Instru init] in
	  let i_inside = [Instru next] in
	  i_before, e1, i_inside, []
      in
      i_b @ i_before, Cil.mkBinOp ~loc LAnd e_cond e_c,
      i_i @ i_inside, i_a @ i_after
    in
    let i_before, e_cond, i_inside, i_after =
      List.fold_left on_lvar ([],cond,[],[]) logic_vars
    in
    let ins_b_0, goal_var = self#translate_pnamed goal in
    let ins_b_1 = Instru(instru_affect lvar goal_var) in
    let i_inside = ins_b_0 @ ins_b_1 :: i_inside in
    let i_loop = ins_loop e_cond i_inside in
    [i_0; i_1; Block (i_before @ i_loop :: i_after)], e_var

  method private translate_predicate p =
    try
      match p with
      | Pfalse -> [], zero
      | Ptrue -> [], one
      | Prel (r,t1,t2) -> self#translate_rel r t1 t2
      | Pand (p,q) -> self#translate_and p q
      | Por (p,q) -> self#translate_or p q
      | Pimplies (p,q) -> self#translate_implies p q
      | Piff(p,q) -> self#translate_equiv p q
      | Pnot p -> self#translate_not p
      | Pif(t,p,q) -> self#translate_pif t p q
      | Pforall(vars,{content=Pimplies(h,g)}) -> self#translate_forall vars h g
      | Pexists(vars,{content=Pand(h,g)}) -> self#translate_exists vars h g
      | Pat (p, LogicLabel(_,l)) when l = "Here" -> self#translate_pnamed p
      | Pvalid (_,t) -> self#translate_valid t
      | Pvalid_read (_,t) ->
	 Options.Self.warning ~current:true
			      "\\valid_read(%a) is interpreted as \\valid(%a)"
			      Printer.pp_term t Printer.pp_term t;
	 self#translate_valid t
      | Pforall _ ->
	 Options.Self.warning ~current:true
			      "%a not of the form \\forall ...; a ==> b"
			      Printer.pp_predicate p;
	 self#unsupported_predicate p
      | Pexists _ ->
	 Options.Self.warning ~current:true
			      "%a not of the form \\exists ...; a && b"
			      Printer.pp_predicate p;
	 self#unsupported_predicate p
      | Papp _
      | Pseparated _
      | Pxor _
      | Plet _
      | Pat _
      | Pinitialized _
      | Pfresh _
      | Pdangling _
      | Pallocable _
      | Pfreeable _
      | Psubtype _ -> self#unsupported_predicate p
    with Unsupported -> self#unsupported_predicate p

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

  method private pre ~pre_entry_point kf behaviors kloc =
    let not_translated p =
      if pre_entry_point then
	let filter ret id = ret || id = p.ip_id in
	States.Not_Translated_Predicates.fold_left filter false
      else true
    in
    let translate_as_return pred =
      let ins, v = self#translate_predicate(self#subst_pred pred.ip_content) in
      (* untreated predicates are translated as True *)
      if not (Cil_datatype.Exp.equal v one) then
	let e = Cil.new_exp ~loc (UnOp (LNot, v, Cil.intType)) in
	ins @ [ins_if e [ins_ret zero] []]
      else ins
    in
    let do_behavior ins b =
      let requires = List.filter not_translated b.b_requires in
      let typically = List.filter not_translated (Utils.typically_preds b) in
      let to_prop = Property.ip_of_requires kf kloc b in
      let in_props p = List.mem (to_prop p) props in
      let requires, typically =
	if pre_entry_point then requires, typically
	else List.filter in_props requires, List.filter in_props typically
      in
      let do_requires ins pred =
	if pre_entry_point then ins @ (translate_as_return pred)
	else
	  let prop = to_prop pred in
	  ins @ (self#pc_assert_exception pred.ip_content "Pre-condition!" prop)
      in
      let do_typically ins pred =
	if pre_entry_point then ins @ (translate_as_return pred) else ins
      in
      if requires <> [] || typically <> [] then
	let inserts' = List.fold_left do_typically [] typically in
	let inserts = List.fold_left do_requires inserts' requires in
	if b.b_assumes <> [] then
	  let inserts_0, exp = self#cond_of_assumes b.b_assumes in
	  let insert_1 = ins_if exp inserts [] in
	  ins @ inserts_0 @ [insert_1]
	else ins @ inserts
      else ins
    in
    List.fold_left do_behavior [] behaviors

  method private post kf behaviors kloc =
    let do_behavior ins b =
      let post = b.b_post_cond in
      let to_prop = Property.ip_of_ensures kf kloc b in
      let post = List.filter (fun x -> List.mem (to_prop x) props) post in
      let do_postcond ins (tk,pred) =
	let prop = to_prop (tk,pred) in
	ins @ (self#pc_assert_exception pred.ip_content "Post-condition!" prop)
      in
      let str = Format.sprintf "@@FC:REACHABLE_BHV:%i" bhv_to_reach_cpt in
      let to_reach =
	not (Cil.is_default_behavior b)
	&& (Options.Behavior_Reachability.get())
      in
      States.Behavior_Reachability.replace bhv_to_reach_cpt (kf,b,false);
      bhv_to_reach_cpt <- bhv_to_reach_cpt+1;
      if post <> [] || (Options.Behavior_Reachability.get()) then
	if b.b_assumes <> [] then
	  let i_0, exp = self#cond_of_assumes b.b_assumes in
	  let ii_0 = if to_reach then [Instru(self#pc_to_fc str)] else [] in
	  let ii_1 = List.fold_left do_postcond [] post in
	  let i_1 = ins_if exp (ii_0 @ ii_1) [] in
	  ins @ i_0 @ [i_1]
	else
	  let i_0 = if to_reach then [Instru(self#pc_to_fc str)] else [] in
	  let i_1 = List.fold_left do_postcond [] post in
	  ins @ i_0 @ i_1
      else ins
    in
    List.fold_left do_behavior [] behaviors

  (* alloc and dealloc variables for \at terms *)
  method private save_varinfo kf vi =
    let rec dig_type = function
      | TPtr (ty, _) -> Cil.stripConstLocalType ty
      | TArray (ty, _, _, _) -> Cil.stripConstLocalType ty
      | TNamed (ty, _) -> dig_type ty.ttype
      | ty -> Options.Self.abort ~current:true "dig_type %a" Printer.pp_typ ty
    in
    let rec strip_const = function
      | TPtr (t, att) -> Cil.stripConstLocalType (TPtr(strip_const t, att))
      | TArray (t,a,b,c) -> Cil.stripConstLocalType(TArray(strip_const t,a,b,c))
      | ty -> Cil.stripConstLocalType ty
    in
    let addoffset lval exp =
      let ty = Cil.typeOfLval lval in
      if Cil.isPointerType ty then
	let base = Cil.new_exp ~loc (Lval lval) in
	Mem(Cil.new_exp ~loc (BinOp(IndexPI, base, exp, ty))), NoOffset
      else if Cil.isArrayType ty then
	Cil.addOffsetLval (Index(exp, NoOffset)) lval
      else raise Unreachable
    in
    let lengths = Utils.lengths_from_requires kf in
    let terms = try Cil_datatype.Varinfo.Hashtbl.find lengths vi with _ -> [] in
    let do_varinfo v =
      let my_old_v = my_varinfo (strip_const v.vtype) ("old_" ^ v.vname) in
      let insert_decl = decl_varinfo my_old_v in
      let lmy_old_v = Cil.var my_old_v in
      let insert_before = Instru(instru_affect lmy_old_v (Cil.evar v)) in
      let rec alloc_aux my_old_ptr my_ptr ty = function
	| h :: t ->
	  let ty = dig_type ty in
	  let inserts_0, h' = self#translate_term h in
	  let my_iterator = self#fresh_ctype_varinfo Cil.ulongType in
	  let e_iterator = Cil.evar my_iterator in
	  let lmy_iterator = Cil.var my_iterator in
	  let insert_1 = decl_varinfo my_iterator in
	  let inserts = match h.term_type with
	    | Linteger ->
	       let tmp = self#fresh_ctype_varinfo Cil.ulongType in
	       let i_1 = decl_varinfo tmp in
	       let i_2 = Instru(self#cget_ui (Cil.var tmp) h') in
	       let e_tmp = Cil.evar tmp in
	       let e1 = Cil.new_exp ~loc (SizeOf ty) in
	       let e2 = Cil.mkBinOp ~loc Mult e_tmp e1 in
	       let insert_2 = Instru(self#cmalloc my_old_ptr e2) in
	       let my_new_old_ptr = addoffset my_old_ptr e_iterator in
	       let my_new_ptr = addoffset my_ptr e_iterator in
	       let inserts_block = alloc_aux my_new_old_ptr my_new_ptr ty t in
	       let init = instru_affect lmy_iterator zero in
	       let i_3 = Instru(self#cget_ui (Cil.var tmp) h') in
	       let cond = cmp Rlt e_iterator e_tmp in
	       let e3 = Cil.mkBinOp ~loc PlusA e_iterator one in
	       let step = instru_affect lmy_iterator e3 in
	       let insert_3 = ins_loop cond (inserts_block @ [Instru step]) in
	       let insert_4 = Instru(self#cclear h') in
	       [i_1; i_2; insert_2; i_3; Instru init; insert_3; insert_4]
	    | Lreal -> raise Unsupported
	    | _ ->
	       let e1 = Cil.new_exp ~loc (SizeOf ty) in
	       let e2 = Cil.mkBinOp ~loc Mult h' e1 in
	       let insert_2 = Instru(self#cmalloc my_old_ptr e2) in
	       let my_new_old_ptr = addoffset my_old_ptr e_iterator in
	       let my_new_ptr = addoffset my_ptr e_iterator in
	       let inserts_block = alloc_aux my_new_old_ptr my_new_ptr ty t in
	       let init = instru_affect lmy_iterator zero in
	       let cond = cmp Rlt e_iterator h' in
	       let e3 = Cil.mkBinOp ~loc PlusA e_iterator one in
	       let step = instru_affect lmy_iterator e3 in
	       let insert_3 = ins_loop cond (inserts_block @ [Instru step]) in
	       [insert_2; Instru init; insert_3]
	  in
	  inserts_0 @ (insert_1 :: inserts)
	| [] ->
	  let e = Cil.new_exp ~loc (Lval my_ptr) in
	  [Instru(instru_affect my_old_ptr e)]
      in
      if Cil.isPointerType v.vtype || Cil.isArrayType v.vtype then
	let my_old_ptr = my_varinfo (strip_const v.vtype) ("old_ptr_"^v.vname)in
	let insert_0 = decl_varinfo my_old_ptr in
	let inserts_decl = [insert_decl; insert_0] in
	let ins = alloc_aux (Cil.var my_old_ptr) (Cil.var v) v.vtype terms in
	let inserts_before = insert_before :: ins in
	inserts_decl, inserts_before
      else [insert_decl], [insert_before]
    in
    let inserts_decl, inserts_before = do_varinfo vi in
    let do_varinfo v =
      let rec dealloc_aux my_old_ptr = function
	| [] -> []
	| _ :: [] -> [ Instru(self#cfree (Cil.new_exp ~loc (Lval my_old_ptr))) ]
	| h :: t ->
	  let my_iterator = self#fresh_ctype_varinfo Cil.ulongType in
	  let e_iterator = Cil.evar my_iterator in
	  let lmy_iterator = Cil.var my_iterator in
	  let insert_0 = decl_varinfo my_iterator in
	  let inserts_1, h' = self#translate_term h in
	  let inserts' = match h.term_type with
	    | Linteger ->
	      let aux = addoffset my_old_ptr e_iterator in
	      let inserts_block = dealloc_aux aux t in
	      let init = instru_affect lmy_iterator zero in
	      let tmp = self#fresh_ctype_varinfo Cil.ulongType in
	      let i_1 = decl_varinfo tmp in
	      let i_2 = Instru(self#cget_ui (Cil.var tmp) h') in
	      let e_tmp = Cil.evar tmp in
	      let cond = cmp Rlt e_iterator e_tmp in
	      let e1 = Cil.mkBinOp ~loc PlusA e_iterator one in
	      let step = instru_affect lmy_iterator e1 in
	      let insert_2 = ins_loop cond (inserts_block @ [Instru step]) in
	      [i_1; i_2; Instru init; insert_2; Instru(self#cclear h')]
	    | Lreal -> raise Unsupported
	    | _ ->
	      let aux = addoffset my_old_ptr (Cil.evar my_iterator) in
	      let inserts_block = dealloc_aux aux t in
	      let init = instru_affect lmy_iterator zero in
	      let cond = cmp Rlt e_iterator h' in
	      let e1 = Cil.mkBinOp ~loc PlusA e_iterator one in
	      let step = instru_affect lmy_iterator e1 in
	      [Instru init; ins_loop cond (inserts_block @ [Instru step])]
	  in
	  let e = Cil.new_exp ~loc (Lval my_old_ptr) in
	  insert_0 :: inserts_1 @ inserts' @ [Instru(self#cfree e)]
      in
      if Cil.isPointerType v.vtype || Cil.isArrayType v.vtype then
	let my_old_ptr = my_varinfo v.vtype ("old_ptr_" ^ v.vname) in
	dealloc_aux (Cil.var my_old_ptr) terms
      else []
    in
    let inserts_after = do_varinfo vi in
    inserts_decl, inserts_before, inserts_after

  method! vfunc f =
    let entry_point = Kernel_function.get_name (fst(Globals.entry_point())) in
    let kf = Globals.Functions.find_by_name f.svar.vname in
    let behaviors = Annotations.behaviors kf in
    self#compute_result_varinfo f;
    let pre_entry_point = f.svar.vname = entry_point in
    let fprename = f.svar.vname ^ "_precond" in
    let fname = if pre_entry_point then fprename else f.svar.vname in
    let label_pre = BegFunc fname in
    let inserts_pre = self#pre ~pre_entry_point kf behaviors Kglobal in
    List.iter (self#insert label_pre) inserts_pre;
    if (self#at_least_one_prop kf behaviors Kglobal)
      || (Options.Behavior_Reachability.get()) then
      begin
	let inserts = self#post kf behaviors Kglobal in
	self#insert (EndFunc f.svar.vname) (Block inserts)
      end;
    let do_varinfo v =
      let inserts_decl,inserts_before,inserts_after = self#save_varinfo kf v in
      List.iter (self#insert (BegFunc f.svar.vname)) inserts_decl;
      List.iter (self#insert (BegFunc f.svar.vname)) inserts_before;
      List.iter (self#insert (EndFunc f.svar.vname)) inserts_after
    in
    List.iter do_varinfo visited_globals;
    List.iter do_varinfo (Kernel_function.get_formals kf);
    Cil.DoChildren

  method private subst_pred p = (new Subst.subst ())#pred p [] [] [] []

  method private cond_of_assumes ?(subst_pred=self#subst_pred) pred_list =
    let rec aux insertions ret = function
      | [] -> insertions, ret
      | h :: t ->
	let ins, v = self#translate_predicate (subst_pred h.ip_content) in
	let e = Cil.mkBinOp ~loc LAnd ret v in
	aux (insertions @ ins) e t
    in
    aux [] one pred_list

  method private cond_of_behaviors pred_lists =
    let rec aux insertions ret = function
      | [] -> insertions, ret
      | h :: t ->
	let ins, v = self#cond_of_assumes h in
	let e = Cil.mkBinOp ~loc LOr ret v in
	aux (insertions @ ins) e t
    in
    aux [] zero pred_lists

  method private pc_exc str i =
    let str = Cil.mkString ~loc str in
    let const = CInt64(Integer.of_int i, IInt, Some(string_of_int i)) in
    self#cpc_exc str (Cil.new_exp ~loc (Const const))

  method private pc_ass str i =
    let str = Cil.mkString ~loc str in
    let const = CInt64(Integer.of_int i, IInt, Some(string_of_int i)) in
    self#cpc_assume str (Cil.new_exp ~loc (Const const))

  method private pc_to_fc str = self#cpc_to_fc (Cil.mkString ~loc str)

  method private pc_assert_exception pred msg prop =
    let inserts_0, var = self#translate_predicate (self#subst_pred pred) in
    let e = Cil.new_exp ~loc (UnOp(LNot, var, Cil.intType)) in
    let id = Utils.to_id prop in
    let insert_1 = ins_if e [Instru(self#pc_exc msg id)] [] in
    translated_properties <- prop :: translated_properties;
    inserts_0 @ [insert_1]

  method private pc_assume pred =
    let inserts_0, var = self#translate_predicate (self#subst_pred pred) in
    let e = Cil.new_exp ~loc (UnOp(LNot, var, Cil.intType)) in
    let insert_1 = ins_if e [Instru(self#pc_ass "" 0)] [] in
    inserts_0 @ [insert_1]

  method private for_behaviors bhvs ins = match bhvs with
  | [] -> ins
  | bhvs ->
    let inserts_0, cond = self#cond_of_behaviors bhvs in
    let insert_1 = ins_if cond ins [] in
    inserts_0 @ [insert_1]

  method private translate_stmt_spec kf stmt for_behaviors bhvs =
    if self#at_least_one_prop kf bhvs.spec_behavior (Kstmt stmt)
       || Options.Behavior_Reachability.get() then
      begin
	let stmt_bhvs = bhvs.spec_behavior in
	let ins = self#pre ~pre_entry_point:false kf stmt_bhvs (Kstmt stmt) in
	let ins = self#for_behaviors for_behaviors ins in
	List.iter (self#insert (BegStmt stmt.sid)) ins;
	let ins = self#post kf stmt_bhvs (Kstmt stmt) in
	let ins =
	  if for_behaviors = [] then ins
	  else self#for_behaviors for_behaviors ins
	in
	List.iter (self#insert (EndStmt stmt.sid)) ins;
      end

  method private translate_assert kf stmt ca for_behaviors pred =
    let prop = Property.ip_of_code_annot_single kf stmt ca in
    if List.mem prop props then
      let ins = self#pc_assert_exception pred.content "Assert!" prop in
      let inserts = self#for_behaviors for_behaviors ins in
      List.iter (self#insert (BegStmt stmt.sid)) inserts

  method private translate_invariant kf stmt ca for_behaviors pred =
    let prop = Property.ip_of_code_annot_single kf stmt ca in
    if List.mem prop props then
      let f label msg =
	let ins = self#pc_assert_exception pred.content msg prop in
	let inserts = self#for_behaviors for_behaviors ins in
	List.iter (self#insert label) inserts
      in
      f (BegStmt stmt.sid) "Loop invariant not established!";
      f (EndIter stmt.sid) "Loop invariant not preserved!"

  method private translate_variant kf stmt ca term =
    let prop = Property.ip_of_code_annot_single kf stmt ca in
    translated_properties <- prop :: translated_properties;
    if List.mem prop props then
      let id = Utils.to_id prop in
      let beg_label = BegIter stmt.sid and end_label = EndIter stmt.sid in
      match term.term_type with
      | Linteger ->
	 (* at BegIter *)
	 let inserts_1, beg_variant = self#translate_term term in
	 List.iter (self#insert beg_label) inserts_1;
	 let cmp_variant_zero = self#fresh_ctype_varinfo Cil.intType in
	 let e_cmp_variant_zero = Cil.evar cmp_variant_zero in
	 let l_cmp_variant_zero = Cil.var cmp_variant_zero in
	 let instr = Instru(self#pc_exc "Variant non positive" id) in
	 self#insert beg_label (decl_varinfo cmp_variant_zero);
	 let i_2 = Instru(self#ccmp_ui l_cmp_variant_zero beg_variant zero) in
	 self#insert beg_label i_2;
	 let cond = cmp Rlt e_cmp_variant_zero zero in
	 self#insert beg_label (ins_if cond [instr] []);
	 let save_variant = self#fresh_Z_varinfo() in
	 let insert_2 = decl_varinfo save_variant in
	 self#insert beg_label insert_2;
	 let e_save_variant  = Cil.evar save_variant in
	 let insert_3 = Instru(self#cinit_set e_save_variant beg_variant) in
	 self#insert beg_label insert_3;
	 (* at EndIter *)
	 let inserts_4, end_variant = self#translate_term term in
	 List.iter (self#insert end_label) inserts_4;
	 let cmp_variants = self#fresh_ctype_varinfo Cil.intType in
	 let e_cmp_variants = Cil.evar cmp_variants in
	 let l_cmp_variants = Cil.var cmp_variants in
	 let instr = Instru(self#pc_exc "Variant non decreasing" id) in
	 self#insert end_label (decl_varinfo cmp_variants);
	 let i_4 = Instru(self#ccmp l_cmp_variants end_variant e_save_variant)in
	 self#insert end_label i_4;
	 let cond = cmp Rge e_cmp_variants zero in
	 self#insert end_label (ins_if cond [instr] []);
	 self#insert end_label (Instru(self#cclear e_save_variant))
      | Lreal -> raise Unsupported
      | _ ->
	 (* at BegIter *)
	 let inserts_1, beg_variant = self#translate_term term in
	 List.iter (self#insert beg_label) inserts_1;
	 let cond = cmp Rlt beg_variant zero in
	 let instr = Instru(self#pc_exc "Variant non positive" id) in
	 self#insert beg_label (ins_if cond [instr] []);
	 let save_variant = self#fresh_ctype_varinfo Cil.intType in
	 let l_save_variant = Cil.var save_variant in
	 let e_save_variant = Cil.evar save_variant in
	 self#insert beg_label (decl_varinfo save_variant);
	 let insert = Instru(instru_affect l_save_variant beg_variant) in
	 self#insert beg_label insert;
	 (* at EndIter *)
	 let inserts_2, end_variant = self#translate_term term in
	 List.iter (self#insert end_label) inserts_2;
	 let cond = cmp Rge end_variant e_save_variant in
	 let instr = Instru(self#pc_exc "Variant non decreasing" id) in
	 self#insert end_label (ins_if cond [instr] [])

  method! vcode_annot ca =
    let stmt = Extlib.the self#current_stmt in
    let kf = Kernel_function.find_englobing_kf stmt in
    let bhv_names = match ca.annot_content with
      | AAssert (b,_) | AStmtSpec (b,_) | AInvariant (b,_,_) -> b
      | _ -> []
    in
    let on_behavior s _ b ret = if b.b_name = s then b.b_assumes else ret in
    let on_behavior_name s = Annotations.fold_behaviors (on_behavior s) kf [] in
    let for_behaviors = List.map on_behavior_name bhv_names in
    begin match ca.annot_content with
    | AStmtSpec (_,bhvs) -> self#translate_stmt_spec kf stmt for_behaviors bhvs
    | AAssert (_,pred) -> self#translate_assert kf stmt ca for_behaviors pred
    | AInvariant (_,true,pred) ->
       self#translate_invariant kf stmt ca for_behaviors pred
    | AVariant (term,_) -> self#translate_variant kf stmt ca term
    | _ -> ()
    end;
    Cil.DoChildren

  method private assigns_cwd assigns =
    let merge_assigns ret = function
      | WritesAny ->
	 Options.Self.warning ~current:true "assigns clause not precise enough";
	 ret
      | Writes froms -> (List.map fst froms) @ ret
    in
    let assigns = List.fold_left merge_assigns [] assigns in
    (* for each term of the assigns clause,
     * - we translate the term in C
     * - we declare a fresh global variable (new input)
     * - we affect the value of this new input to the term *)
    let on_term ret term =
      let t = term.it_content in
      match t.term_node with
      | TLval(TMem{term_node=TBinOp(op, op1,
				    {term_node=Trange (Some t1, Some t2)})},
	      TNoOffset) ->
	 assert(t1.term_type = Linteger);
	 assert(t2.term_type = Linteger);
	 let ty =
	   match op1.term_type with Ctype t -> t | _ -> raise Unreachable in
	 let it = self#fresh_Z_varinfo () in
	 let e_it = Cil.evar it in
	 let i_0 = decl_varinfo it in
	 let i_1, e_t1 = self#translate_term t1 in
	 let i_2 = Instru(self#cinit_set e_it e_t1) in
	 let i_3, e_t2 = self#translate_term t2 in
	 let i_it = self#fresh_ctype_varinfo Cil.intType in
	 let e_i_it = Cil.evar i_it in
	 let i_4 = decl_varinfo i_it in
	 let tmp = self#fresh_ctype_varinfo Cil.intType in
	 let e_tmp = Cil.evar tmp in
	 let i_5 = decl_varinfo tmp in
	 let i_6 = Instru(self#ccmp (Cil.var tmp) e_it e_t2) in
	 let cond = cmp Rle e_tmp zero in
	 let i_f_0 = Instru(self#cget_si (Cil.var i_it) e_it) in
	 let ll, e_op1 = self#translate_term op1 in
	 assert (ll = []);
	 let e = Cil.new_exp ~loc (BinOp(op, e_op1, e_i_it, ty)) in
	 let y = Mem e, NoOffset in
	 let i_f_1 = Instru(self#cnondet (Cil.typeOfLval y) y) in
	 let i_f_2 = Instru(self#cbinop_ui PlusA e_it e_it one) in
	 let i_f_3 = Instru(self#ccmp (Cil.var tmp) e_it e_t2) in
	 let i_7 = ins_loop cond [i_f_0; i_f_1; i_f_2; i_f_3] in
	 let i_8 = Instru(self#cclear e_it) in
	 let i_9 = Instru(self#cclear e_t1) in
	 let i_10 = Instru(self#cclear e_t2) in
	 i_0::i_1 @ i_2::i_3 @ i_4::i_5::i_6::i_7::i_8::i_9::i_10::ret
      | TLval lv ->
	 let ty = match t.term_type with Ctype x -> x | _-> raise Unreachable in
	 let ins, e = self#translate_lval lv in
	 let aff = Instru(self#cnondet ty e) in
	 ins @ aff :: ret
      | _ ->
	 Options.Self.warning
	   ~current:true "term %a in assigns clause unsupported"
	   Printer.pp_term t;
	 ret
    in
    List.fold_left on_term [] assigns

  method! vstmt_aux stmt =
    if List.mem stmt.sid stmts_to_reach then
      begin
	let str = Format.sprintf "@@FC:REACHABLE_STMT:%i" stmt.sid in
	self#insert (BegStmt stmt.sid) (Instru(self#pc_to_fc str))
      end;
    let kf = Kernel_function.find_englobing_kf stmt in
    let sim_funcs = Options.Simulate_Functions.get() in
    match stmt.skind with
    | If(_exp,b1,b2,_loc) ->
       let add_block_reachability b = match b.bstmts with
	 | first_stmt :: _ ->
	    let dkey = Options.dkey_reach in
      	    Options.Self.debug ~dkey "stmt %i to reach" first_stmt.sid;
	    States.Unreachable_Stmts.replace first_stmt.sid (first_stmt, kf);
      	    stmts_to_reach <- first_stmt.sid :: stmts_to_reach
      	 | _ -> ()
       in
       add_block_reachability b1;
       add_block_reachability b2;
       Cil.DoChildren
    | Loop _ when cwd <> None && (Extlib.the cwd).sid = stmt.sid->
       let kf = Kernel_function.find_englobing_kf stmt in
       let ca_l = Annotations.code_annot stmt in
       let ca_l = List.map (fun x -> x.annot_content) ca_l in
       let on_bhv _ bhv ins =
	 let bhv_in l =
	   List.mem bhv.b_name l || (Cil.is_default_behavior bhv && l = []) in
	 let f_assigns ret = function
	   | AAssigns (l, a) when bhv_in l -> a :: ret
	   | _ -> ret
	 in
	 let f_linvs ret = function
	   | AInvariant(l, _, p) when bhv_in l -> p :: ret
	   | _ -> ret
	 in
	 let assigns = List.fold_left f_assigns [] ca_l in
	 let linvs = List.fold_left f_linvs [] ca_l in
	 let ins_assumes, e_assumes = self#cond_of_assumes bhv.b_assumes in
	 let affects = self#assigns_cwd assigns in
	 let on_inv ret p = ret @ (self#pc_assume p.content) in
	 let ins_block = List.fold_left on_inv affects linvs in
	 let ins_bhv = ins_if e_assumes ins_block [] in
	 ins @ ins_assumes @ [ins_bhv]
       in
       let ins_h = Annotations.fold_behaviors on_bhv kf [] in
       List.iter (self#insert (BegStmt stmt.sid)) ins_h;
       Cil.DoChildren
    | Instr (Call(ret,{enode=Lval(Var fct_varinfo,NoOffset)},args,_))
	 when (cwd <> None && (Extlib.the cwd).sid = stmt.sid)
	      || (List.mem fct_varinfo.vname sim_funcs) ->
       let kf = Globals.Functions.get fct_varinfo in
       let formals = Kernel_function.get_formals kf in
       let locals = [] in
       let new_f_vi = self#fresh_fct_varinfo fct_varinfo.vtype in
       let on_bhv _ bhv ins =
	 let ins_assumes, e_assumes = self#cond_of_assumes bhv.b_assumes in
	 (* we create variables old_* to save the values of globals and
	  * formal parameters before function call *)
	 let save v (a,b,c) =let d,e,f=self#save_varinfo kf v in d@a,e@b,f@c in
	 let save_global v _ l = save v l in
	 let save_formal l v = save v l in
	 let i1,i2,i3 = Globals.Vars.fold save_global ([],[],[]) in
	 let i1,i2,i3 = List.fold_left save_formal (i1,i2,i3) formals in
	 let begin_save = i1 @ i2 and end_save = i3 in
	 let affects = self#assigns_cwd [bhv.b_assigns] in
	 let ensures = bhv.b_post_cond in
	 let on_post ins (_,{ip_content=p}) =
	   let p = match ret with
	     | Some r ->
		let ty = Cil.typeOfLval r in
		let subst_result = Cil.var (my_varinfo ty "__retres") in
		(new Subst.subst ~subst_result ())#pred p[][][][]
	     | None -> p
	   in
	   ins @ (self#pc_assume p)
	 in
	 let posts = List.fold_left on_post [] ensures in
	 let ins_bhv =
	   ins_if e_assumes (begin_save @ affects @ posts @ end_save) [] in
	 ins @ ins_assumes @ [ins_bhv]
       in
       let ins_body = Annotations.fold_behaviors on_bhv kf [] in
       (* if the function called returns a value (into a variable r),
	* we declare a fresh global variable (new input)
	* we affect the value of this new input to the variable __retres *)
       let decl_retres, aff_retres, ret_retres = match ret with
	 | Some r ->
	    let ty = Cil.typeOfLval r in
	    let retres = my_varinfo ty "__retres" in
	    let e_retres = Cil.evar retres in
	    let aff = Instru(self#cnondet ty (Cil.var retres)) in
	    [decl_varinfo retres], [aff], [ins_ret e_retres]
	 | None -> [], [], []
       in
       let ins_full_body = decl_retres @ aff_retres @ ins_body @ ret_retres in
       let new_f = mk_func new_f_vi formals locals ins_full_body in
       functions <- new_f :: functions;
       let i_call = Instru(Call(ret,Cil.evar new_f_vi,args,loc)) in
       self#insert (EndStmt stmt.sid) i_call;
       Cil.SkipChildren
    | _ -> Cil.DoChildren

  method! vglob_aux = function
    | GVar(vi,_,_) -> visited_globals <- vi::visited_globals; Cil.DoChildren
    | _ -> Cil.DoChildren
end