(* Ocsigen
 * http://www.ocsigen.org
 * Module revproxy.ml
 * Copyright (C) 2007 Vincent Balat
 * Laboratoire PPS - CNRS Université Paris Diderot
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception; 
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(** Reverse proxy for Ocsigen *)

(* 
   The reverse proxy is still experimental because it relies on the 
   experimental Http_client module.

   TODO
   - add the ability to rewrite some headers from the config file
   (for ex after a redirection, the new URL is wrong)
   probably in another (filter) extension
   - enhance pipelining
   - ...
*)


(* To compile it:
ocamlfind ocamlc  -thread -package netstring,ocsigen -c revproxy.ml

Then load it dynamically from Ocsigen's config file:
   <extension module=".../revproxy.cmo"/>

*)

open Lwt
open Extensions
open Simplexmlparser

exception Not_concerned



(*****************************************************************************)
(* The table of redirections for each virtual server                         *)
type redir =
    { regexp: Netstring_pcre.regexp;
      https: bool;
      server:string;
      port: string;
      uri: string;
      pipeline: bool}



(*****************************************************************************)
let rec parse_global_config = function
  | [] -> ()
  | _ -> raise (Error_in_config_file 
                  ("Unexpected content inside revproxy config"))

let _ = parse_global_config (Extensions.get_config ())




(*****************************************************************************)
(* Finding redirections *)

let find_redirection r path =
  match Netstring_pcre.string_match r.regexp path 0 with
  | None -> raise Not_concerned
  | Some _ -> (* Matching regexp found! *)
      (r.https,
       Netstring_pcre.replace_first r.regexp r.server path,
       int_of_string 
         (Netstring_pcre.global_replace r.regexp r.port path),
       Netstring_pcre.global_replace r.regexp r.uri path)




(*****************************************************************************)
(** Function to be called at the beginning of the initialisation phase 
    of the server (actually each time the config file is reloaded) *)
let start_init () =
  ()

(** Function to be called at the end of the initialisation phase *)
let end_init () =
  ()



(*****************************************************************************)
(** The function that will generate the pages from the request. *)
exception Bad_answer_from_http_server

let gen dir charset = function
| Extensions.Req_found (_, r) -> Lwt.return (Extensions.Ext_found r)
| Extensions.Req_not_found (err, ri) ->
  catch
    (* Is it a redirection? *)
    (fun () ->
       Messages.debug2 "--Revproxy: Is it a redirection?";
       let (https, host, port, uri) = 
         find_redirection dir (Lazy.force ri.ri_sub_path_string)
       in
       let uri = "/"^uri in
       Messages.debug (fun () ->
                         "--Revproxy: YES! Redirection to "^
                           (if https then "https://" else "http://")^host^":"^
                                (string_of_int port)^uri);

       Ocsimisc.get_inet_addr host >>= fun inet_addr ->

       (* It is now safe to start next request.
          We are sure that the request won't be taken in disorder.
          => We return.
       *)

       let do_request = 
         if dir.pipeline then
           Http_client.raw_request 
             ~headers:ri.ri_http_frame.Http_frame.header.Http_frame.Http_header.headers
             ~https
             ~port 
             ~client:ri.ri_client
             ~keep_alive:true
             ~content:ri.ri_http_frame.Http_frame.content
             ~http_method:ri.ri_method
             ~host
             ~inet_addr
             ~uri ()
           else
             fun () ->
               Http_client.basic_raw_request 
                 ~headers:ri.ri_http_frame.Http_frame.header.Http_frame.Http_header.headers
                 ~https
                 ~port 
                 ~content:ri.ri_http_frame.Http_frame.content
                 ~http_method:ri.ri_method
                 ~host
                 ~inet_addr
                 ~uri ()
       in
       Lwt.return
         (Ext_found
            (fun () -> 
               do_request ()

               >>= fun http_frame ->
               let headers = 
                 http_frame.Http_frame.header.Http_frame.Http_header.headers 
               in
               let code = 
                 match http_frame.Http_frame.header.Http_frame.Http_header.mode with
                   | Http_frame.Http_header.Answer code -> code
                   | _ -> raise Bad_answer_from_http_server
               in
               match http_frame.Http_frame.content with
                 | None ->
                     let empty_result = Http_frame.empty_result () in
                     Lwt.return
                       {empty_result with
                          Http_frame.res_content_length = None;
	                  Http_frame.res_headers= headers;
	                  Http_frame.res_code= code;
                       }
                 | Some stream ->
                     let default_result = Http_frame.default_result () in
                     Lwt.return
                       {default_result with
                          Http_frame.res_content_length = None;
                          Http_frame.res_stream = stream;
	                  Http_frame.res_headers= headers;
	                  Http_frame.res_code= code;
                       }
            )
         )
    )
    (function 
       | Not_concerned -> return (Ext_next err)
       | e -> fail e)
         



(*****************************************************************************)
(** Configuration for each site.
    These tags are inside <site ...>...</site> in the config file.
        
   For example:
   <site dir="">
     <revproxy regexp="" ... />
   </extension>

 *)

let parse_config path charset parse_site = function
  | Element ("revproxy", atts, []) -> 
      let rec parse_attrs ((r, s, prot, port, u, pipeline) as res) = function
        | [] -> res
        | ("regexp", regexp)::l when r = None ->
            parse_attrs
              (Some (Netstring_pcre.regexp ("^"^regexp^"$")), s, prot, port, u, pipeline)
              l
        | ("protocol", protocol)::l 
          when prot = None && String.lowercase protocol = "http" -> 
            parse_attrs
              (r, s, Some false, port, u, pipeline)
              l
        | ("protocol", protocol)::l 
          when prot = None && String.lowercase protocol = "https" -> 
            parse_attrs
              (r, s, Some true, port, u, pipeline)
              l
        | ("server", server)::l when s = None ->
            parse_attrs
              (r, Some server, prot, port, u, pipeline)
              l
        | ("uri", uri)::l when u = None ->
            parse_attrs
              (r, s, prot, port, Some uri, pipeline)
              l
        | ("port", p)::l when port = None ->
            parse_attrs
              (r, s, prot, Some p, u, pipeline)
              l
        | ("nopipeline", "nopipeline")::l ->
            parse_attrs
              (r, s, prot, port, u, false)
              l
        | _ -> raise (Error_in_config_file "Wrong attribute for <revproxy>")
        in
        let dir =
          match parse_attrs (None, None, None, None, None, true) atts with
          | (None, _, _, _, _, _) -> raise (Error_in_config_file "Missing attribute regexp for <revproxy>")
          | (_, None, _, _, _, _) -> raise (Error_in_config_file "Missing attribute server for <revproxy>")
          | (_, _, _, _, None, _) -> raise (Error_in_config_file "Missing attribute uri for <revproxy>")
          | (Some r, Some s, None, port, Some u, pipeline) -> 
              {
               regexp=r;
               server=s;
               https=false;
               port=(match port with
               | Some p -> p
               | None -> "80");
               uri=u;
               pipeline=pipeline;
             }
          | (Some r, Some s, Some prot, port, Some u, pipeline) -> 
              {
               regexp=r;
               server=s;
               https=prot;
               port=(match port with
               | Some p -> p
               | None -> if prot then "443" else "80");
               uri=u;
               pipeline=pipeline;
             }
        in
        gen dir charset
  | Element (t, _, _) -> raise (Bad_config_tag_for_extension t)
  | _ -> raise (Error_in_config_file "(revproxy extension) Bad data")





(*****************************************************************************)
(** Registration of the extension *)
let _ = register_extension
    ~respect_pipeline:true (* We ask ocsigen to respect pipeline order
                              when sending to extensions! *)
    (fun hostpattern -> parse_config)
    start_init
    end_init
    raise

