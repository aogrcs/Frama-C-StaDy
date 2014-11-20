
open Cil_types


let pp_label fmt = function
  | Sd_insertions.BegStmt s -> Format.fprintf fmt "BegStmt %i" s
  | Sd_insertions.EndStmt s -> Format.fprintf fmt "EndStmt %i" s
  | Sd_insertions.BegFunc s -> Format.fprintf fmt "BegFunc %s" s
  | Sd_insertions.EndFunc s -> Format.fprintf fmt "EndFunc %s" s
  | Sd_insertions.BegIter s -> Format.fprintf fmt "BegIter %i" s
  | Sd_insertions.EndIter s -> Format.fprintf fmt "EndIter %i" s
  | Sd_insertions.Glob -> Format.fprintf fmt "Global"

let pp_var = Printer.pp_varinfo
let pp_lval = Printer.pp_lval
let pp_exp = Printer.pp_exp

let pp_garith fmt = function
  | PlusA -> Format.fprintf fmt "add"
  | MinusA -> Format.fprintf fmt "sub"
  | Mult -> Format.fprintf fmt "mul"
  | Div -> Format.fprintf fmt "tdiv_q"
  | Mod -> Format.fprintf fmt "tdiv_r"
  | _ -> assert false (* not used by the translation *)

let pp_instruction fmt = function
  | Sd_insertions.Skip -> ()
  | Sd_insertions.Pc_to_framac s ->
    Format.fprintf fmt "pathcrawler_to_framac(\"%s\")" s
  | Sd_insertions.Pc_exn(s,i)->
    Format.fprintf fmt"pathcrawler_assert_exception(\"%s\",%i)" s i
  | Sd_insertions.IAffect(v,e)-> Format.fprintf fmt "%a = %a" pp_lval v pp_exp e
  | Sd_insertions.IFree e -> Format.fprintf fmt "free(%a)" pp_exp e
  | Sd_insertions.IRet e -> Format.fprintf fmt "return %a" pp_exp e
  | Sd_insertions.IPc_dim (v,e) ->
    Format.fprintf fmt "%a = pathcrawler_dimension(%a)" pp_lval v pp_exp e
  | Sd_insertions.IPc_assume e ->
    Format.fprintf fmt "pathcrawler_assume(%a)" pp_exp e
  | Sd_insertions.IMalloc (v,e) ->
    Format.fprintf fmt "%a = malloc(%a)" pp_lval v pp_exp e
  | Sd_insertions.IZ_clear e -> Format.fprintf fmt "__gmpz_clear(%a)" pp_exp e
  | Sd_insertions.IZ_init v -> Format.fprintf fmt "__gmpz_init(%a)" pp_var v
  | Sd_insertions.IZ_init_set (v,e) ->
    Format.fprintf fmt "__gmpz_init_set(%a, %a)" pp_var v pp_exp e
  | Sd_insertions.IZ_init_set_ui (v,e) ->
    Format.fprintf fmt "__gmpz_init_set_ui(%a, %a)" pp_var v pp_exp e
  | Sd_insertions.IZ_init_set_si (v,e) ->
    Format.fprintf fmt "__gmpz_init_set_si(%a, %a)" pp_var v pp_exp e
  | Sd_insertions.IZ_init_set_str (v,e) ->
    Format.fprintf fmt "__gmpz_init_set_str(%a, %a, 10)" pp_var v pp_exp e
  | Sd_insertions.IZ_set (v,e) ->
    Format.fprintf fmt "__gmpz_set(%a, %a)" pp_var v pp_exp e
  | Sd_insertions.IZ_abs (v,e) ->
    Format.fprintf fmt "%a = __gmpz_set(%a)" pp_var v pp_exp e
  | Sd_insertions.IZ_ui_sub (v,e,e') ->
    Format.fprintf fmt "__gmpz_ui_sub(%a, %a, %a)" pp_var v pp_exp e pp_exp e'
  | Sd_insertions.IZ_binop (o,v,e,e') ->
    Format.fprintf fmt "__gmpz_%a(%a, %a, %a)"
      pp_garith o pp_var v pp_exp e pp_exp e'
  | Sd_insertions.IZ_binop_ui (o,v,e,e') ->
    Format.fprintf fmt "__gmpz_%a_ui(%a, %a, %a)"
      pp_garith o pp_var v pp_exp e pp_exp e'
  | Sd_insertions.IZ_binop_si (o,v,e,e') ->
    Format.fprintf fmt "__gmpz_%a_si(%a, %a, %a)"
      pp_garith o pp_var v pp_exp e pp_exp e'
  | Sd_insertions.IZ_get_ui (v,e) ->
    Format.fprintf fmt "%a = __gmpz_get_ui(%a)" pp_var v pp_exp e
  | Sd_insertions.IZ_get_si (v,e) ->
    Format.fprintf fmt "%a = __gmpz_get_si(%a)" pp_var v pp_exp e
  | Sd_insertions.IZ_cmp (v,e,e') ->
    Format.fprintf fmt "%a = __gmpz_cmp(%a, %a)" pp_var v pp_exp e pp_exp e'
  | Sd_insertions.IZ_cmp_ui (v,e,e') ->
    Format.fprintf fmt "%a = __gmpz_cmp_ui(%a, %a)" pp_var v pp_exp e pp_exp e'
  | Sd_insertions.IZ_cmp_si (v,e,e') ->
    Format.fprintf fmt "%a = __gmpz_cmp_si(%a, %a)" pp_var v pp_exp e pp_exp e'

let rec pp_insertion ?(line_break = true) fmt ins =
  let rec aux fmt = function
    | [] -> ()
    | h :: [] -> pp_insertion ~line_break:false fmt h
    | h :: t -> pp_insertion ~line_break:true fmt h; aux fmt t
  in
  begin
    match ins with
    | Sd_insertions.Instru i -> Format.fprintf fmt "@[%a;@]" pp_instruction i
    | Sd_insertions.Decl v ->
      Format.fprintf fmt "@[%a;@]" (new Printer.extensible_printer())#vdecl v
    | Sd_insertions.Block b ->
      if b <> [] then Format.fprintf fmt "@[<hov 2>{@\n%a@]@\n}" aux b
    | Sd_insertions.IIf (e,b1,b2) ->
      Format.fprintf fmt "@[<hov 2>if(%a) {@\n%a@]@\n}" pp_exp e aux b1;
      if b2 <> [] then Format.fprintf fmt "@\n@[<hov 2>else {@\n%a@]@\n}" aux b2
    | Sd_insertions.IFor (i1,e,i2,b) ->
      Format.fprintf fmt "@[<hov 2>for(%a; %a; %a) {@\n%a@]@\n}"
	pp_instruction i1 pp_exp e pp_instruction i2 aux b
  end;
  if line_break then Format.fprintf fmt "@\n"

let pp_insertion_lb = pp_insertion ~line_break:true


let debug_builtins = Kernel.register_category "printer:builtins"

let print_var v =
  not (Cil.is_unused_builtin v) || Kernel.is_debug_key_enabled debug_builtins


class print_insertions insertions () = object(self)
  inherit Printer.extensible_printer () as super

  method private insertions_at fmt label =
    try
      let q = Hashtbl.find insertions label in
      Queue.iter (pp_insertion_lb fmt) q
    with _ -> ()

  method private fundecl fmt f =
    let entry_point_name=Kernel_function.get_name(fst(Globals.entry_point())) in
    let old_is_ghost = is_ghost in
    is_ghost <- true;
    (* BEGIN precond (entry-point) *)
    if f.svar.vname = entry_point_name then
      begin
	let precond = f.svar.vname ^ "_precond" in
	let x,y,z =
	  match f.svar.vtype with TFun(_,x,y,z) -> x,y,z | _ -> assert false
	in
	Format.fprintf fmt "%a@ @[<hov 2>{@\n"
	  (self#typ (Some (fun fmt -> Format.fprintf fmt "%s" precond)))
	  (TFun(Cil.intType,x,y,z));
        self#insertions_at fmt (Sd_insertions.BegFunc precond);
	Format.fprintf fmt "@[return 1;@]";
	Format.fprintf fmt "@]@\n}@\n@\n"
      end;
    (* END precond (entry-point) *)
    Format.fprintf fmt "@[%t%a@\n@[<v 2>" ignore self#vdecl f.svar;
    (* body. *)
    Format.fprintf fmt "@[<hov 2>{@\n";
    self#insertions_at fmt (Sd_insertions.BegFunc f.svar.vname);
    self#block ~braces:true fmt f.sbody;
    Format.fprintf fmt "@.}";
    Format.fprintf fmt "@]%t@]@." ignore;
    is_ghost <- old_is_ghost
  (* end of fundecl *)

  (* do not print calls to function that do not have a body *)
  method! instr fmt i = match i with
  | Call (_ret, fct_exp, _args, _loc) ->
    begin
      let fct_varinfo = match fct_exp.enode  with
	| Lval(Var v,NoOffset) -> v
	| _ -> assert false
      in
      let kf = Globals.Functions.get fct_varinfo in
      let is_def = Kernel_function.is_definition kf in
      if is_def then
	super#instr fmt i
      else
	begin
	  Sd_options.Self.warning ~current:true ~once:true
	    "function %s does not have a body"
	    fct_varinfo.vname;
	  Sd_options.Self.warning ~current:true "%a has been discarded"
	    Printer.pp_instr i
	end
    end
  | _ -> super#instr fmt i

  method! private annotated_stmt next fmt stmt =
    Format.pp_open_hvbox fmt 2;
    self#stmt_labels fmt stmt;
    Format.pp_open_hvbox fmt 0;
    let kf = Kernel_function.find_englobing_kf stmt in
    let insert_something =
      (try not (Queue.is_empty
		  (Hashtbl.find insertions (Sd_insertions.BegStmt stmt.sid)))
       with _ -> false)
      || (try not (Queue.is_empty
		     (Hashtbl.find insertions (Sd_insertions.EndStmt stmt.sid)))
	with _ -> false)
    in
    if insert_something then Format.fprintf fmt "@[<hov 2>{@\n";
    self#insertions_at fmt (Sd_insertions.BegStmt stmt.sid);
    begin
      match stmt.skind with
      | Loop(_,b,l,_,_) ->
	Format.fprintf fmt "%a@[<v 2>while (1) {@\n"
	  (fun fmt -> self#line_directive fmt) l;
	self#insertions_at fmt (Sd_insertions.BegIter stmt.sid);
	Format.fprintf fmt "%a" (fun fmt -> self#block fmt) b;
	self#insertions_at fmt (Sd_insertions.EndIter stmt.sid);
	Format.fprintf fmt "}@\n @]"
      | Return _ ->
	let f = Kernel_function.get_name kf in
	self#insertions_at fmt (Sd_insertions.EndFunc f);
	self#stmtkind next fmt stmt.skind
      | _ -> self#stmtkind next fmt stmt.skind
    end;
    self#insertions_at fmt (Sd_insertions.EndStmt stmt.sid);
    if insert_something then Format.fprintf fmt "@]@\n}";
    Format.pp_close_box fmt ();
    Format.pp_close_box fmt ()
  (* end of annotated_stmt *)

  method! file fmt f =
    Format.fprintf fmt "@[/* Generated by Frama-C */@\n";
    self#headers fmt;
    self#insertions_at fmt (Sd_insertions.Glob);
    Cil.iterGlobals f (fun g -> self#global fmt g);
    Format.fprintf fmt "@]@."

  val mutable gmp = false
  val mutable gmpz_get_ui = false
  val mutable gmpz_get_si = false
  val mutable gmpz_cmp = false
  val mutable gmpz_cmp_ui = false
  val mutable gmpz_cmp_si = false
  val mutable gmpz_clear = false
  val mutable gmpz_init = false
  val mutable gmpz_init_set = false
  val mutable gmpz_init_set_ui = false
  val mutable gmpz_init_set_si = false
  val mutable gmpz_init_set_str = false
  val mutable gmpz_set = false
  val mutable gmpz_abs = false
  val mutable gmpz_add = false
  val mutable gmpz_add_ui = false
  val mutable gmpz_sub = false
  val mutable gmpz_sub_ui = false
  val mutable gmpz_ui_sub = false
  val mutable gmpz_mul = false
  val mutable gmpz_mul_si = false
  val mutable gmpz_mul_ui = false
  val mutable gmpz_tdiv_q = false
  val mutable gmpz_tdiv_q_ui = false
  val mutable gmpz_tdiv_r = false
  val mutable gmpz_tdiv_r_ui = false
  val mutable pc_assert_exc = false
  val mutable pc_dim = false
  val mutable pc_to_fc = false
  val mutable pc_assume = false
  val mutable malloc = false
  val mutable free = false

  method private instru = function
  | Sd_insertions.Skip -> ()
  | Sd_insertions.IAffect _ -> ()
  | Sd_insertions.IFree _ -> free <- true
  | Sd_insertions.Pc_to_framac _ -> pc_to_fc <- true
  | Sd_insertions.Pc_exn _ -> pc_assert_exc <- true
  | Sd_insertions.IRet _ -> ()
  | Sd_insertions.IZ_clear _ -> gmpz_clear <- true; gmp <- true
  | Sd_insertions.IZ_init _ -> gmpz_init <- true
  | Sd_insertions.IZ_init_set _ -> gmpz_init_set <- true
  | Sd_insertions.IZ_init_set_ui _ -> gmpz_init_set_ui <- true
  | Sd_insertions.IZ_init_set_si _ -> gmpz_init_set_si <- true
  | Sd_insertions.IZ_init_set_str _ -> gmpz_init_set_str <- true
  | Sd_insertions.IZ_set _ -> gmpz_set <- true
  | Sd_insertions.IZ_abs _ -> gmpz_abs <- true
  | Sd_insertions.IZ_ui_sub _ -> gmpz_ui_sub <- true
  | Sd_insertions.IZ_binop (binop,_,_,_) ->
    begin
      match binop with
      | PlusA -> gmpz_add <- true
      | MinusA -> gmpz_sub <- true
      | Mult -> gmpz_mul <- true
      | Div -> gmpz_tdiv_q <- true
      | Mod -> gmpz_tdiv_r <- true
      | _ -> ()
    end
  | Sd_insertions.IZ_binop_ui (binop,_,_,_) ->
    begin
      match binop with
      | PlusA -> gmpz_add_ui <- true
      | MinusA -> gmpz_sub_ui <- true
      | Mult -> gmpz_mul_ui <- true
      | Div -> gmpz_tdiv_q_ui <- true
      | Mod -> gmpz_tdiv_r_ui <- true
      | _ -> ()
    end
  | Sd_insertions.IZ_binop_si (Mult,_,_,_) -> gmpz_mul_si <- true
  | Sd_insertions.IZ_binop_si _ -> ()
  | Sd_insertions.IZ_get_ui _ -> gmpz_get_ui <- true
  | Sd_insertions.IZ_get_si _ -> gmpz_get_si <- true
  | Sd_insertions.IPc_dim _ -> pc_dim <- true
  | Sd_insertions.IPc_assume _ -> pc_assume <- true
  | Sd_insertions.IMalloc _ -> malloc <- true
  | Sd_insertions.IZ_cmp _ -> gmpz_cmp <- true
  | Sd_insertions.IZ_cmp_ui _ -> gmpz_cmp_ui <- true
  | Sd_insertions.IZ_cmp_si _ -> gmpz_cmp_si <- true

  method private insertion = function
  | Sd_insertions.Instru i -> self#instru i
  | Sd_insertions.Decl _ -> ()
  | Sd_insertions.Block i -> List.iter self#insertion i
  | Sd_insertions.IIf(_,i1,i2) ->
    List.iter self#insertion i1; List.iter self#insertion i2
  | Sd_insertions.IFor(i1,_,i2,i3) ->
    self#instru i1; self#instru i2; List.iter self#insertion i3

  method private headers fmt =
    Hashtbl.iter (fun _ q -> Queue.iter self#insertion q) insertions;
    let headers = [
      gmp, "struct __anonstruct___mpz_struct_1 {\
   int _mp_alloc ;\
   int _mp_size ;\
   unsigned long *_mp_d ;\
};\
typedef struct __anonstruct___mpz_struct_1 __mpz_struct;\
typedef __mpz_struct mpz_t[1];";
      gmpz_get_ui, "extern unsigned long int __gmpz_get_ui(mpz_t);";
      gmpz_get_si, "extern signed long int __gmpz_get_si(mpz_t);";
      gmpz_cmp_ui, "extern int __gmpz_cmp_ui(mpz_t, unsigned long int);";
      gmpz_cmp_si, "extern int __gmpz_cmp_si(mpz_t, signed long int);";
      gmpz_cmp, "extern int __gmpz_cmp(mpz_t, mpz_t);";
      gmpz_clear, "extern void __gmpz_clear(mpz_t);";
      gmpz_init, "extern void __gmpz_init(mpz_t);";
      gmpz_init_set, "extern void __gmpz_init_set(mpz_t, mpz_t);";
      gmpz_init_set_ui,
      "extern void __gmpz_init_set_ui(mpz_t, unsigned long int);";
      gmpz_init_set_si,
      "extern void __gmpz_init_set_si(mpz_t, signed long int);";
      gmpz_init_set_str,
      "extern void __gmpz_init_set_str(mpz_t, const char*, int);";
      gmpz_set, "extern void __gmpz_set(mpz_t, mpz_t);";
      gmpz_abs, "extern void __gmpz_abs(mpz_t, mpz_t);";
      gmpz_add, "extern void __gmpz_add(mpz_t, const mpz_t, const mpz_t);";
      gmpz_add_ui,
      "extern void __gmpz_add_ui(mpz_t, const mpz_t, unsigned long int);";
      gmpz_sub, "extern void __gmpz_sub(mpz_t, const mpz_t, const mpz_t);";
      gmpz_sub_ui,
      "extern void __gmpz_sub_ui(mpz_t, const mpz_t, unsigned long int);";
      gmpz_ui_sub,
      "extern void __gmpz_ui_sub(mpz_t, unsigned long int, const mpz_t);";
      gmpz_mul, "extern void __gmpz_mul(mpz_t, const mpz_t, const mpz_t);";
      gmpz_mul_si, "extern void __gmpz_mul_si(mpz_t, const mpz_t, long int);";
      gmpz_mul_ui,
      "extern void __gmpz_mul_ui(mpz_t, const mpz_t, unsigned long int);";
      gmpz_tdiv_q,
      "extern void __gmpz_tdiv_q(mpz_t, const mpz_t, const mpz_t);";
      gmpz_tdiv_q_ui,
      "extern void __gmpz_tdiv_q_ui(mpz_t, const mpz_t, unsigned long int);";
      gmpz_tdiv_r,
      "extern void __gmpz_tdiv_r(mpz_t, const mpz_t, const mpz_t);";
      gmpz_tdiv_r_ui,
      "extern void __gmpz_tdiv_r_ui(mpz_t, const mpz_t, unsigned long int);";
      pc_assert_exc, "extern int pathcrawler_assert_exception(char*,int);";
      pc_dim, "extern int pathcrawler_dimension(void*);";
      pc_to_fc, "extern void pathcrawler_to_framac(char*);";
      pc_assume, "extern void pathcrawler_assume(int);";
      malloc, "extern void* malloc(unsigned long);";
      free, "extern void free(void*);";
    ] in
    List.iter (fun (must_print, str) ->
      if must_print then Format.fprintf fmt "%s@\n" str
    ) headers

  method! global fmt g =
    match g with
    | GFun (fundec, l) ->
      if print_var fundec.svar then
  	begin
  	  let oldattr = fundec.svar.vattr in
  	  fundec.svar.vattr <- [];
  	  self#line_directive ~forcefile:true fmt l;
  	  self#fundecl fmt fundec;
  	  fundec.svar.vattr <- oldattr;
  	  Format.fprintf fmt "@\n"
  	end
    | GVarDecl (_, vi, _) -> if print_var vi then super#global fmt g
    | GVar (vi,_,_) ->
      let old_vghost = vi.vghost in
      vi.vghost <- false;
      super#global fmt g;
      vi.vghost <- old_vghost
    | _ -> super#global fmt g
end
