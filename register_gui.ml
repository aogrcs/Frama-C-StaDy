

let compute_props : (Property.t list -> unit) ref = ref (fun _ -> ())


let pc_panel (main_ui:Design.main_window_extension_points) =
  let vbox = GPack.vbox () in
  let packing = vbox#pack ~expand:true ~fill:true in
  let w = GPack.table ~packing ~columns:2 () in
  let box_4 = GPack.hbox ~packing:(w#attach ~left:1 ~top:4) () in
  let tooltip = "Entry point" in
  let validator s = List.mem s (Kernel.MainFunction.get_possible_values ()) in
  let get = Kernel.MainFunction.get in
  let set = Kernel.MainFunction.set in
  let refresh = Gtk_helper.on_string ~tooltip ~validator box_4 "main" get set in
  let run_button = GButton.button ~label:"Run" ~packing:(vbox#pack) () in
  let callback() = Register.run(); main_ui#redisplay() in
  let on_press() = main_ui#protect ~cancelable:true callback in
  let _ = run_button#connect#pressed on_press in
  "pcva", vbox#coerce, Some refresh
  


let to_do_on_select
    (popup_factory:GMenu.menu GMenu.factory)
    (main_ui:Design.main_window_extension_points) button_nb selected =
  match selected with
  | Pretty_source.PIP prop ->
    begin
      try
	let tbl = States.TestFailures.find prop in
	if button_nb = 1 then
	  let nb = Datatype.String.Hashtbl.length tbl in
	  if nb > 0 then main_ui#pretty_information "%i counter-examples@." nb;
	  Datatype.String.Hashtbl.iter_sorted (fun tc (input,conc,symb) ->
	    main_ui#pretty_information "Counter-example (by PathCrawler-VA):@.";
	    if tc <> "" then main_ui#pretty_information "%s@.@\n" tc;
	    let pretty (s, v) = main_ui #pretty_information "%s = %s@." s v in
	    main_ui#pretty_information "input:@.";
	    List.iter pretty input;
	    main_ui#pretty_information "------------------------@.";
	    main_ui#pretty_information "concrete output:@.";
	    List.iter pretty conc;
	    main_ui#pretty_information "------------------------@.";
	    main_ui#pretty_information "symbolic output:@.";
	    List.iter pretty symb;
	    main_ui#pretty_information "------------------------@."
	  ) tbl
	else if button_nb = 3 then
	  Datatype.String.Hashtbl.iter_sorted (fun tc_c _ ->
	    let callback() =
	      let prj = Project.create tc_c in
	      let sel = State_selection.of_list[Kernel.PreprocessAnnot.self] in
	      Project.copy ~selection:sel prj;
	      Project.on prj File.init_from_c_files [File.from_filename tc_c]
	    in
	    let item_str = Printf.sprintf "_Open %s in new project" tc_c in
	    ignore (popup_factory#add_item item_str ~callback)
	  ) tbl
      with
      | _ -> ()
    end;
    if button_nb = 3 then
      let callback() = !compute_props [prop]; main_ui#redisplay() in
      ignore (popup_factory#add_item "Validate property with pcva" ~callback)
  | _ -> ()


let pc_selector menu (main_ui:Design.main_window_extension_points) ~button loc =
  to_do_on_select menu main_ui button loc


let main main_ui =
  Register.setup_props_bijection();
  let lengths = Register.lengths_from_requires() in
  let terms_at_Pre = Register.at_from_formals lengths in
  compute_props := (fun props -> Register.compute_props props terms_at_Pre); 
  main_ui#register_panel pc_panel;
  main_ui#register_source_selector pc_selector

let () = Design.register_extension main
