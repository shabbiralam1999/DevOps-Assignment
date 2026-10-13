import { app } from "./app.js";
import { initSchema } from "./db.js";

const PORT = process.env.PORT || 4000;

initSchema()
  .then(() => {
    app.listen(PORT, "0.0.0.0", () => console.log(JSON.stringify({ level: "info", msg: "listening", port: PORT })));
  })
  .catch((err) => {
    console.error("failed to initialize schema:", err);
    process.exit(1);
  });
