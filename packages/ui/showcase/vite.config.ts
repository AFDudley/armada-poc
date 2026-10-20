// ABOUTME: Vite config for @armada/ui-showcase — the design-system pixel-compare app.
// ABOUTME: Runs on port 5180 to avoid collisions with the mockup (5173) and crowdfund apps (5173-5175).

import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5180,
    strictPort: true,
  },
});
