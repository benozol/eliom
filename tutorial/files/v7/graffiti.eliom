{shared{
  open XHTML5.M
  let width = 700
  let height = 400
}}

module My_appl =
  Eliom_output.Eliom_appl (
    struct
      let application_name = "graffiti"
      let params =
        {Eliom_output.default_appl_params with
           Eliom_output.ap_title = "graffiti";
           Eliom_output.ap_headers_before =
            [
              XHTML5.M.link ~rel:[ `Stylesheet ]
                ~href:(XHTML5.M.uri_of_string"./css/graffiti.css")
                ();
              XHTML5.M.link ~rel:[ `Stylesheet ]
                ~href:(XHTML5.M.uri_of_string"./css/common.css")
                ();
              XHTML5.M.link ~rel:[ `Stylesheet ]
                ~href:(XHTML5.M.uri_of_string"./css/hsvpalette.css")
                ();
              XHTML5.M.link ~rel:[ `Stylesheet ]
                ~href:(XHTML5.M.uri_of_string"./css/slider.css")
                ();
              XHTML5.M.script
                ~a:[XHTML5.M.a_src (XHTML5.M.uri_of_string "http://closure-library.googlecode.com/svn/trunk/closure/goog/base.js")
                   ] (XHTML5.M.pcdata "");
              XHTML5.M.script
                ~a:[XHTML5.M.a_src (XHTML5.M.uri_of_string "./graffiti_req.js")
                   ] (XHTML5.M.pcdata "");
            ];
        }
    end)

{client{
  open Event_arrows
  let draw ctx (color, size, (x1, y1), (x2, y2)) =
    ctx##strokeStyle <- (Js.string color);
    ctx##lineWidth <- float size;
    ctx##beginPath();
    ctx##moveTo(float x1, float y1);
    ctx##lineTo(float x2, float y2);
    ctx##stroke()
}}

{shared{
  type messages = (string * int * (int * int) * (int * int)) deriving (Json)
}}

let bus = Eliom_bus.create ~name:"graff" Json.t<messages>

let main_service =
  My_appl.register_service ~path:[""] ~get_params:Eliom_parameters.unit
    (fun () () ->
       Eliom_services.onload
         {{
           let canvas = Dom_html.createCanvas Dom_html.document in
           let ctx = canvas##getContext (Dom_html._2d_) in
           canvas##width <- width; canvas##height <- height;
           ctx##lineCap <- Js.string "round";

           Dom.appendChild Dom_html.document##body canvas;

           (* Size of the brush *)
           let slider = jsnew Goog.Ui.slider(Js.null) in
           slider##setMinimum(1.);
           slider##setMaximum(80.);
           slider##setValue(10.);
           slider##setMoveToPointEnabled(Js._true);
           slider##render(Js.some Dom_html.document##body);
          
           (* The color palette: *)
           let pSmall = 
             jsnew Goog.Ui.hsvPalette(Js.null, Js.null,
                                      Js.some (Js.string "goog-hsv-palette-sm"))
           in
           pSmall##render(Js.some Dom_html.document##body);

           let x0, y0 = Dom_html.elementClientPosition canvas in
           let x = ref 0 and y = ref 0 in
           let set_coord ev = x := ev##clientX - x0; y := ev##clientY - y0 in
           let compute_line ev = 
             let oldx = !x and oldy = !y in
             set_coord ev;
             let color = Js.to_string (pSmall##getColor()) in
             let size = int_of_float (Js.to_float (slider##getValue())) in
             (color, size, (oldx, oldy), (!x, !y))
           in
           let (bus:messages Eliom_client_bus.t) = %bus in
           let line ev =
             let v = compute_line ev in
             let _ = Eliom_client_bus.write bus v in
             draw ctx v
           in
           let _ = Lwt_stream.iter (draw ctx) (Eliom_client_bus.stream bus) in
           ignore (run (mousedowns canvas
                          (arr (fun ev -> set_coord ev; line ev)
                           >>> first [mousemoves Dom_html.document (arr line);
                                      mouseup Dom_html.document >>> (arr line)])) ());
         }};
      Lwt.return [h1 [pcdata "Graffiti"]])