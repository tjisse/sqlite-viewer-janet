# Read at executable build time. These bytes are embedded in the Janet image.
(def files
  {"/assets/app.css" (slurp "assets/app.css")
   "/assets/app.js" (slurp "assets/app.js")
   "/assets/datastar.js" (slurp "assets/datastar.js")
   "/assets/icon.svg" (slurp "assets/icon.svg")})
