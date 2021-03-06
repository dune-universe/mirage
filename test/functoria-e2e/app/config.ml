open F0

let main = Functoria.(main "App" job)

let key =
  let doc = Key.Arg.info ~doc:"How to say hello." [ "hello" ] in
  Key.(create "hello" Arg.(opt string "Hello World!" doc))

let () = register ~keys:[ Key.abstract key ] "noop" [ main ]
