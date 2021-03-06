open Lwt

module type S = sig
  type identity
  type key
  type server_notif
  type client_notif
  val init : unit -> unit Lwt.t
  val deinit : unit -> unit Lwt.t
  val listen : key -> unit
  val unlisten : key -> unit
  module Ext : sig
    val unlisten :
      ?sitedata:Eliom_common.sitedata ->
      ([< `Client_process ], [< `Data | `Pers ]) Eliom_state.Ext.state
      -> key -> unit
  end
  val notify : ?notfor:[`Me | `Id of identity] -> key -> server_notif -> unit
  val client_ev : unit -> (key * client_notif) Eliom_react.Down.t Lwt.t
  val clean : unit -> unit Lwt.t
end

module type ARG = sig
  type identity
  type key
  type server_notif
  type client_notif
  val prepare : identity -> server_notif -> client_notif option Lwt.t
  val equal_key                  : key -> key -> bool
  val equal_identity             : identity -> identity -> bool
  val get_identity               : unit -> identity Lwt.t
  val max_resource               : int
  val max_identity_per_resource  : int
end

module Make (A : ARG) : S
  with type identity = A.identity
   and type key = A.key
   and type server_notif = A.server_notif
   and type client_notif = A.client_notif
= struct

  type key = A.key
  type identity = A.identity
  type server_notif = A.server_notif
  type client_notif = A.client_notif

  type notification_data = A.key * A.client_notif

  type notification_react =
    notification_data Eliom_react.Down.t
    * (?step: React.step -> notification_data -> unit)

  module Notif_hashtbl = Hashtbl.Make(struct
    type t    = A.key
    let equal = A.equal_key
    let hash  = Hashtbl.hash
  end)

  module Weak_tbl = Weak.Make (struct
    type t = (A.identity * notification_react) option
    let equal a b = match a, b with
      | None, None ->
        true
      | Some (a, b), Some (c, d) ->
        A.equal_identity a c && b == d
      | _ -> false
    let hash = Hashtbl.hash
  end)

  module I = struct

    let tbl = Notif_hashtbl.create A.max_resource

    let lock = Lwt_mutex.create ()

    let async_locked f = Lwt.async (fun () ->
      Lwt_mutex.lock lock >>= fun () ->
      f ();
      Lwt.return (Lwt_mutex.unlock lock)
    )

    let remove_if_empty wt key = async_locked (fun () ->
      if Weak_tbl.count wt = 0
      then Notif_hashtbl.remove tbl key
    )

    let remove v key = async_locked (fun () ->
      let () =
        try
          let wt = Notif_hashtbl.find tbl key in
          Weak_tbl.remove wt v;
          remove_if_empty wt key
        with Not_found -> ()
      in
      Lwt.return ()
    )

    let add v key = async_locked (fun () ->
      let wt =
        try
          Notif_hashtbl.find tbl key
        with Not_found ->
          let wt = Weak_tbl.create A.max_identity_per_resource in
          Notif_hashtbl.add tbl key wt;
          wt
      in
      if not (Weak_tbl.mem wt v)
      then Weak_tbl.add wt v;
      Lwt.return ()
    )

    let iter =
      let iter (f : Weak_tbl.data -> unit Lwt.t) wt : unit =
        Weak_tbl.iter
          (fun data -> Lwt.async (fun () -> f data))
          wt
      in
      fun f key -> async_locked (fun () ->
        let () =
          try
            let wt = Notif_hashtbl.find tbl key in
            let g data = match data with
              | None ->
                Weak_tbl.remove wt data;
                remove_if_empty wt key;
                Lwt.return ()
              | Some v ->
                f v;
                Lwt.return ()
            in
            iter g wt;
          with Not_found -> ()
        in
        Lwt.return ()
      )
  end

  let identity_r : (A.identity * notification_react) option Eliom_reference.eref =
    Eliom_reference.eref
      ~scope:Eliom_common.default_process_scope
      None

  (* notif_e consists in a server side react event,
     its client side counterpart,
     and the server side function to trigger it. *)
  let notif_e : notification_react Eliom_reference.eref =
    let notif =
      let e, send_e = React.E.create () in
      let client_ev = Eliom_react.Down.of_react
      (*VVV If we add throttling, some events may be lost
            even if buffer size is not 1 :O *)
        ~size: 100 (*VVV ? *)
        ~scope:Eliom_common.default_process_scope
        e
      in
      (client_ev, send_e)
    in
    Eliom_reference.eref
      ~scope:Eliom_common.default_process_scope
      notif

  let of_option = function
    | Some x -> x
    | None -> assert false

  let set_identity identity =
    (* For each tab connected to the app,
       we keep a pointer to (identity, notif_ev) option in process state,
       because the table resourceid -> (identity, notif_ev) option
       is weak.
    *)
    Eliom_reference.get notif_e >>= fun notif_e ->
    Eliom_reference.set identity_r (Some (identity, notif_e))

  let set_current_identity () =
    A.get_identity () >>= fun identity ->
    set_identity identity

  let init : unit -> unit Lwt.t = fun () ->
    set_current_identity ()

  let deinit : unit -> unit Lwt.t = fun () ->
    Eliom_reference.set identity_r None


  let listen (key : A.key) = Lwt.async (fun () ->
    Eliom_reference.get identity_r >>= fun identity ->
    I.add identity key;
    Lwt.return ()
  )

  let unlisten (id : A.key) = Lwt.async (fun () ->
    Eliom_reference.get identity_r >>= fun identity ->
    I.remove identity id;
    Lwt.return ()
  )

  module type Ext = sig
    val unlisten :
      ?sitedata:Eliom_common.sitedata ->
      ([< `Session | `Session_group ], [< `Data | `Pers ]) Eliom_state.Ext.state
      -> key -> unit
  end

  module Ext = struct
    let unlisten ?sitedata state (key : A.key) = Lwt.async @@ fun () ->
      let%lwt uc = Eliom_reference.Ext.get state identity_r in
      Lwt.return @@ I.remove uc key
  end

  let notify ?notfor key content =
    let f = fun (identity, ((_, send_e) as notif)) ->
      let%lwt blocked = match notfor with
        | Some `Me ->
            (*TODO: fails outside of a request*)
            Eliom_reference.get notif_e >>= fun notif_e ->
            Lwt.return (notif == notif_e)
        | Some (`Id id) -> Lwt.return (identity = id)
        | None -> Lwt.return false
      in
      if blocked
      then Lwt.return ()
      else
        A.prepare identity content >>= fun content -> match content with
        | Some content -> send_e (key, content); Lwt.return ()
        | None -> Lwt.return ()
    in
    (* on all tabs registered on this data *)
    I.iter f key

  let client_ev () =
    Eliom_reference.get notif_e >>= fun notif_e ->
    Lwt.return notif_e >>= fun (ev, _) ->
    Lwt.return ev

  let clean () =
    let f key weak_tbl = I.async_locked (fun () ->
      if Weak_tbl.count weak_tbl = 0
      then Notif_hashtbl.remove I.tbl key
    ) in
    Lwt.return @@ Notif_hashtbl.iter f I.tbl

end

module type ARG_SIMPLE = sig
  type identity
  type key
  type notification
  val get_identity               : unit -> identity Lwt.t
end

module Make_Simple(A : ARG_SIMPLE) = Make
  (struct
    type identity      = A.identity
    type key           = A.key
    type server_notif  = A.notification
    type client_notif  = A.notification
    let prepare _ n    = Lwt.return (Some n)
    let equal_key      = (=)
    let equal_identity = (=)
    let get_identity   = A.get_identity
    let max_resource   = 1000
    let max_identity_per_resource = 10
  end)
