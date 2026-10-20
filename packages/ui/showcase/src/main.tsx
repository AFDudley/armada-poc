// ABOUTME: Mount point for the @armada/ui-showcase Vite app.
// ABOUTME: Loads tokens + global reset before rendering the App tree.

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@armada/ui/styles/tokens.css";
import "@armada/ui/styles/global.css";
import { App } from "./App";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
